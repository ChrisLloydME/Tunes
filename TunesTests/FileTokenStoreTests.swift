import Foundation
import Testing
@testable import Tunes

@MainActor
struct FileTokenStoreTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TunesTokenTests-" + UUID().uuidString)
    }

    @Test func restoresOnlyAfterMatchingAccountResolves() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = FileTokenStore(directory: directory)
        try first.restore(for: "fixture-account")
        try first.save("fixture-token")
        let restored = FileTokenStore(directory: directory)
        #expect(try restored.read() == nil)
        try restored.restore(for: "fixture-account")
        #expect(try restored.read() == "fixture-token")
    }

    @Test func createsPrivateFilesExcludedFromBackupAndReplacesAtomically() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileTokenStore(directory: directory)
        try store.restore(for: "fixture-account")
        try store.save("fixture-first")
        try store.save("fixture-replacement")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let file = try #require(files.first)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let restored = FileTokenStore(directory: directory)
        try restored.restore(for: "fixture-account")
        #expect(try restored.read() == "fixture-replacement")
    }

    @Test func removesCredentialsForAnotherAccountOrConfirmedSignOut() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileTokenStore(directory: directory)
        try store.restore(for: "fixture-a")
        try store.save("fixture-token-a")
        let restored = FileTokenStore(directory: directory)
        try restored.restore(for: "fixture-b")
        #expect(try restored.read() == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("upload-token.json").path))
        try restored.save("fixture-token-b")
        try restored.restore(for: nil)
        #expect(try restored.read() == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("upload-token.json").path))
    }

    @Test func explicitRemovalSurvivesRestartAndIsIdempotent() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileTokenStore(directory: directory)
        try store.restore(for: "fixture-account")
        try store.save("fixture-token")
        try store.remove()
        try store.remove()
        #expect(try store.read() == nil)
        let restored = FileTokenStore(directory: directory)
        try restored.restore(for: "fixture-account")
        #expect(try restored.read() == nil)
    }

    @Test func betaAndReleaseUseSeparateDirectories() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let betaDirectory = FileTokenStore.directory(applicationSupport: root, bundleIdentifier: "com.lloydME.Tunes.beta")
        let releaseDirectory = FileTokenStore.directory(applicationSupport: root, bundleIdentifier: "com.lloydME.Tunes")
        let beta = FileTokenStore(directory: betaDirectory)
        let release = FileTokenStore(directory: releaseDirectory)
        try beta.restore(for: "fixture-account")
        try beta.save("fixture-beta")
        try release.restore(for: "fixture-account")
        #expect(try release.read() == nil)
        try release.save("fixture-release")
        try beta.remove()
        let restored = FileTokenStore(directory: releaseDirectory)
        try restored.restore(for: "fixture-account")
        #expect(try restored.read() == "fixture-release")
    }

    @Test func requiresAccountBeforeWritingAndRejectsMalformedFilesWithoutLeakingContents() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileTokenStore(directory: directory)
        #expect(throws: (any Error).self) { try store.save("fixture-token") }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        try store.restore(for: "fixture-account")
        try store.save("fixture-token")
        let file = directory.appendingPathComponent("upload-token.json")
        try Data("fixture-private-malformed-data".utf8).write(to: file)
        do {
            try store.restore(for: "fixture-account")
            Issue.record("Malformed credentials must not restore.")
        } catch {
            #expect(!error.localizedDescription.contains("fixture-private-malformed-data"))
        }
        #expect(try store.read() == nil)
        try store.save("fixture-repaired")
        let restored = FileTokenStore(directory: directory)
        try restored.restore(for: "fixture-account")
        #expect(try restored.read() == "fixture-repaired")
    }

    @Test func refusesSymlinkedCredentialFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileTokenStore(directory: directory)
        try store.restore(for: "fixture-account")
        try store.save("fixture-token")
        let file = directory.appendingPathComponent("upload-token.json")
        let target = directory.appendingPathComponent("other.json")
        try FileManager.default.moveItem(at: file, to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(throws: (any Error).self) { try store.restore(for: "fixture-account") }
        #expect(try store.read() == nil)
        try store.remove()
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func failedSaveKeepsPreviousTokenAndFailedRemovalDeactivatesIt() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Credentials")
        let movedDirectory = root.appendingPathComponent("MovedCredentials")
        let store = FileTokenStore(directory: directory)
        try store.restore(for: "fixture-a")
        try store.save("fixture-original")
        try FileManager.default.moveItem(at: directory, to: movedDirectory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: movedDirectory)
        #expect(throws: (any Error).self) { try store.save("fixture-rejected") }
        #expect(try store.read() == "fixture-original")
        #expect(throws: (any Error).self) { try store.remove() }
        #expect(try store.read() == nil)
        let untouched = FileTokenStore(directory: movedDirectory)
        try untouched.restore(for: "fixture-a")
        #expect(try untouched.read() == "fixture-original")
        #expect(throws: (any Error).self) { try store.restore(for: "fixture-b") }
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: movedDirectory, to: directory)
        try store.save("fixture-b-token")
        let restored = FileTokenStore(directory: directory)
        try restored.restore(for: "fixture-b")
        #expect(try restored.read() == "fixture-b-token")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["upload-token.json"])
    }
}
