import Darwin
import Foundation

/// Credentials never enter Keychain, preferences, logs, or JavaScript.
@MainActor
protocol TokenStore {
    func read() throws -> String?
    func save(_ token: String) throws
    func remove() throws
    func restore(for accountID: String?) throws
}

@MainActor
final class MemoryTokenStore: TokenStore {
    private var token: String?
    private var accountID: String?
    func read() throws -> String? { token }
    func save(_ token: String) throws { self.token = token }
    func remove() throws { token = nil }
    func restore(for accountID: String?) throws {
        if accountID == nil || (self.accountID != nil && self.accountID != accountID) { token = nil }
        self.accountID = accountID
    }
}

/// Plaintext storage explicitly selected by the user. Only a matching web account activates it.
@MainActor
final class FileTokenStore: TokenStore {
    private struct Credential: Codable {
        let version: Int
        let accountID: String
        let token: String
    }

    private let directory: URL
    private let fileManager = FileManager.default
    private var accountID: String?
    private var token: String?
    private var fileURL: URL { directory.appendingPathComponent("upload-token.json") }

    init(directory: URL) {
        self.directory = directory
    }

    static func directory(applicationSupport: URL, bundleIdentifier: String) -> URL {
        applicationSupport.appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Credentials", isDirectory: true)
    }

    static func applicationStore() -> FileTokenStore {
        // Sandboxed builds resolve Application Support inside their own app container.
        FileTokenStore(directory: directory(
            applicationSupport: URL.applicationSupportDirectory,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.lloydME.Tunes"
        ))
    }

    func read() throws -> String? { token }

    func restore(for accountID: String?) throws {
        token = nil
        self.accountID = accountID
        guard let accountID else { try remove(); return }
        do {
            guard fileManager.fileExists(atPath: fileURL.path) else { return }
            guard hasFileType(mode_t(S_IFREG), at: fileURL) else { throw StorageError.read }
            try prepareDirectory()
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            let data = try Data(contentsOf: fileURL)
            let credential = try JSONDecoder().decode(Credential.self, from: data)
            guard credential.version == 1, !credential.token.isEmpty else { throw StorageError.read }
            guard credential.accountID == accountID else { try remove(); return }
            token = credential.token
        } catch { throw StorageError.read }
    }

    func save(_ token: String) throws {
        guard let accountID, !token.isEmpty else { throw StorageError.accountRequired }
        let temporaryURL = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        do {
            try prepareDirectory()
            let data = try JSONEncoder().encode(Credential(version: 1, accountID: accountID, token: token))
            // Create the temporary file with restrictive permissions before writing any credential bytes.
            let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw StorageError.save }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            var excludedURL = temporaryURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excludedURL.setResourceValues(values)
            // Same-directory rename atomically replaces the previous credential.
            guard rename(temporaryURL.path, fileURL.path) == 0 else { throw StorageError.save }
            self.token = token
        } catch { throw StorageError.save }
    }

    func remove() throws {
        token = nil
        do {
            if fileManager.fileExists(atPath: directory.path) {
                guard hasFileType(mode_t(S_IFDIR), at: directory) else { throw StorageError.remove }
            }
            try fileManager.removeItem(at: fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return
        } catch { throw StorageError.remove }
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        guard hasFileType(mode_t(S_IFDIR), at: directory) else { throw StorageError.save }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var excludedURL = directory
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        try excludedURL.setResourceValues(excluded)
    }

    private func hasFileType(_ type: mode_t, at url: URL) -> Bool {
        // lstat bypasses URL resource caches and does not follow the final symlink.
        var path = url.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        var attributes = stat()
        return lstat(path, &attributes) == 0 && attributes.st_mode & mode_t(S_IFMT) == type
    }

    private enum StorageError: LocalizedError {
        case accountRequired, read, save, remove

        var errorDescription: String? {
            switch self {
            case .accountRequired: "Sign in to Samply before saving an upload token."
            case .read: "The saved upload token could not be restored. Verify and save a new token, or sign out to delete the saved file."
            case .save: "The upload token could not be saved on this Mac."
            case .remove: "The saved upload token could not be deleted. It is no longer active in Tunes."
            }
        }
    }
}
