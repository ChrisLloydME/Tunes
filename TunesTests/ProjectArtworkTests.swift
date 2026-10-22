import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Tunes

@MainActor
@Suite(.serialized)
struct ProjectArtworkTests {
    @Test func processorBoundsAndEncodesSupportedImages() throws {
        let source = try imageData(width: 3000, height: 1200)
        let selection = try ProjectArtworkProcessor.selection(from: source,
                                                              suggestedName: "Cover Art")
        #expect(selection.payload.mimeType == "image/jpeg")
        #expect(selection.payload.fileName == "Cover Art.jpg")
        #expect(selection.payload.data.starts(with: [0xFF, 0xD8]))
        #expect(max(selection.preview.size.width, selection.preview.size.height) <= 2000)
    }

    @Test func fileProcessingDoesNotLeaveTemporaryCopies() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Cover.png")
        try imageData(width: 40, height: 40).write(to: file)

        _ = try ProjectArtworkProcessor.selection(fromFile: file)

        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["Cover.png"])
    }

    @Test func processorRejectsUnsupportedAndOversizedData() throws {
        #expect(throws: ProjectArtworkError.self) {
            try ProjectArtworkProcessor.selection(from: Data("not an image".utf8),
                                                  suggestedName: "Cover")
        }
        let oversized = Data(repeating: 0, count: ProjectArtworkProcessor.maxSourceBytes + 1)
        #expect(throws: ProjectArtworkError.self) {
            try ProjectArtworkProcessor.selection(from: oversized, suggestedName: "Cover")
        }
    }

    @Test func storeDropsStaleAccountCompletion() async throws {
        let data = try imageData(width: 40, height: 40)
        let store = ProjectArtworkSelectionStore()
        store.updateAccount("account-a")
        let load = Task {
            await store.load(data: data, suggestedName: "First", accountID: "account-a")
        }
        store.updateAccount("account-b")
        await load.value

        #expect(store.selection == nil)
        #expect(!store.isLoading)
    }

    @Test func removeInvalidatesAnInFlightSelection() async throws {
        let data = try imageData(width: 40, height: 40)
        let store = ProjectArtworkSelectionStore()
        store.updateAccount("account-a")
        let load = Task {
            await store.load(data: data, suggestedName: "First", accountID: "account-a")
        }
        await waitUntil { store.isLoading }
        store.remove()
        await load.value

        #expect(store.selection == nil)
        #expect(!store.isLoading)
        #expect(store.errorMessage == nil)
    }

    @Test func storeReportsDecodeErrorsWithoutLeavingLoadingState() async {
        let store = ProjectArtworkSelectionStore()
        store.updateAccount("account-a")
        await store.load(data: Data([0, 1, 2]), suggestedName: "Broken",
                         accountID: "account-a")
        #expect(store.selection == nil)
        #expect(!store.isLoading)
        #expect(store.errorMessage != nil)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func imageData(width: Int, height: Int) throws -> Data {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = context.makeImage() else {
            throw ProjectArtworkError.encodeFailed
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { throw ProjectArtworkError.encodeFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ProjectArtworkError.encodeFailed
        }
        return data as Data
    }
}
