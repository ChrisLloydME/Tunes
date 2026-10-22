import AppKit
import Foundation
import Testing
@testable import Tunes

@MainActor
final class ControllableArtworkLoader: BoundedDataLoading {
    struct Request {
        let url: URL
        let maxBytes: Int
        var completion: CheckedContinuation<Data, Error>?
    }

    private(set) var requests: [Request] = []

    func data(from url: URL, maxBytes: Int) async throws -> Data {
        let id = requests.count
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                requests.append(Request(url: url, maxBytes: maxBytes, completion: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    private func cancel(_ id: Int) {
        guard id < requests.count, let continuation = requests[id].completion else { return }
        requests[id].completion = nil
        continuation.resume(throwing: CancellationError())
    }

    func complete(_ id: Int, with data: Data) {
        guard id < requests.count, let continuation = requests[id].completion else { return }
        requests[id].completion = nil
        continuation.resume(returning: data)
    }

    func fail(_ id: Int, with error: Error) {
        guard id < requests.count, let continuation = requests[id].completion else { return }
        requests[id].completion = nil
        continuation.resume(throwing: error)
    }
}

@MainActor
func testArtworkPNG(width: Int = 4, height: Int = 4) -> Data {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor.systemRed.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let representation = NSBitmapImageRep(data: tiff),
          let data = representation.representation(using: .png, properties: [:]) else {
        return Data()
    }
    return data
}

@MainActor
struct ArtworkPipelineTests {
    private func waitUntil(_ condition: () -> Bool, _ message: String) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record(Comment(rawValue: message))
    }

    @Test func sameSourceConsumersShareOneTransferAndOneDecode() async {
        let loader = ControllableArtworkLoader()
        let pipeline = ArtworkPipeline(loader: loader)
        let url = URL(string: "https://example.test/cover.png?signature=abc")!
        let size = CGSize(width: 64, height: 64)
        let first = Task { await pipeline.image(for: url, targetSize: size) }
        let second = Task { await pipeline.image(for: url, targetSize: size) }
        await waitUntil({ loader.requests.count == 1 }, "the transfer was not coalesced")

        loader.complete(0, with: testArtworkPNG())
        let images = await (first.value, second.value)
        #expect(images.0 != nil)
        #expect(images.1 != nil)
        #expect(loader.requests.count == 1)
        #expect(pipeline.cachedImageCount == 1)
        #expect(loader.requests[0].url == url)
    }

    @Test func differentPixelBucketsDecodeSeparatelyFromOneTransfer() async {
        let loader = ControllableArtworkLoader()
        let pipeline = ArtworkPipeline(loader: loader)
        let url = URL(string: "https://example.test/cover.png")!
        let small = Task { await pipeline.image(for: url, targetSize: CGSize(width: 64, height: 64)) }
        let large = Task { await pipeline.image(for: url, targetSize: CGSize(width: 180, height: 180)) }
        await waitUntil({ loader.requests.count == 1 }, "the transfer was not coalesced")

        loader.complete(0, with: testArtworkPNG(width: 32, height: 32))
        let images = await (small.value, large.value)
        #expect(images.0 != nil)
        #expect(images.1 != nil)
        #expect(loader.requests.count == 1)
        #expect(pipeline.cachedImageCount == 2)
        #expect(pipeline.cachedImageCost > 0)
    }

    @Test func cancellingOneConsumerKeepsTheTransferForTheOther() async {
        let loader = ControllableArtworkLoader()
        let pipeline = ArtworkPipeline(loader: loader)
        let url = URL(string: "https://example.test/cover.png")!
        let size = CGSize(width: 64, height: 64)
        let first = Task { await pipeline.image(for: url, targetSize: size) }
        await waitUntil({ loader.requests.count == 1 }, "the first transfer did not start")
        let second = Task { await pipeline.image(for: url, targetSize: size) }
        await Task.yield()
        second.cancel()
        loader.complete(0, with: testArtworkPNG())

        #expect(await first.value != nil)
        #expect(await second.value == nil)
    }

    @Test func accountEpochChangeDropsLateImagesAndClearsTheCache() async {
        let loader = ControllableArtworkLoader()
        let pipeline = ArtworkPipeline(loader: loader)
        let url = URL(string: "https://example.test/cover.png")!
        let task = Task { await pipeline.image(for: url, targetSize: CGSize(width: 64, height: 64)) }
        await waitUntil({ loader.requests.count == 1 }, "the transfer did not start")

        pipeline.updateEpoch(1)
        loader.complete(0, with: testArtworkPNG())
        #expect(await task.value == nil)
        #expect(pipeline.cachedImageCount == 0)
        #expect(pipeline.cachedImageCost == 0)
        #expect(pipeline.epoch == 1)
    }

    @Test func malformedAndOversizedDataTerminateSafely() async {
        let loader = ControllableArtworkLoader()
        let pipeline = ArtworkPipeline(loader: loader)
        let url = URL(string: "https://example.test/cover.png")!
        let size = CGSize(width: 64, height: 64)
        let malformed = Task { await pipeline.image(for: url, targetSize: size) }
        await waitUntil({ loader.requests.count == 1 }, "the malformed transfer did not start")
        loader.complete(0, with: Data("not an image".utf8))
        #expect(await malformed.value == nil)

        let oversized = Task { await pipeline.image(for: url, targetSize: size) }
        await waitUntil({ loader.requests.count == 2 }, "the oversized transfer did not start")
        loader.fail(1, with: BoundedHTTPDataLoader.Failure.tooLarge)
        #expect(await oversized.value == nil)
        #expect(pipeline.cachedImageCount == 0)
    }

    @Test func decodedCostEvictionHonorsTheBudget() async {
        let loader = ControllableArtworkLoader()
        let pipeline = ArtworkPipeline(loader: loader, costLimit: 1)
        let url = URL(string: "https://example.test/cover.png")!
        let task = Task { await pipeline.image(for: url, targetSize: CGSize(width: 64, height: 64)) }
        await waitUntil({ loader.requests.count == 1 }, "the transfer did not start")
        loader.complete(0, with: testArtworkPNG(width: 32, height: 32))
        #expect(await task.value != nil)
        #expect(pipeline.cachedImageCount == 0)
        #expect(pipeline.cachedImageCost == 0)
    }

    @Test func paletteUsesTheDecodedImageIdentityAndIsCached() async {
        let loader = ControllableArtworkLoader()
        let pipeline = ArtworkPipeline(loader: loader)
        let url = URL(string: "https://example.test/cover.png")!
        let first = Task { await pipeline.palette(for: url) }
        await waitUntil({ loader.requests.count == 1 }, "the palette transfer did not start")
        loader.complete(0, with: testArtworkPNG(width: 64, height: 64))
        let palette = await first.value
        #expect(palette != ColorExtractor.ColorPalette.default)
        #expect(pipeline.cachedPaletteCount == 1)

        let cached = await pipeline.palette(for: url)
        #expect(cached == palette)
        #expect(loader.requests.count == 1)
    }

    @Test func transfersAreCappedAtFourWithAWaitingQueue() async {
        let loader = ControllableArtworkLoader()
        let pipeline = ArtworkPipeline(loader: loader)
        var tasks: [Task<NSImage?, Never>] = []
        for index in 0..<5 {
            let url = URL(string: "https://example.test/cover-\(index).png")!
            tasks.append(Task {
                await pipeline.image(for: url, targetSize: CGSize(width: 64, height: 64))
            })
        }
        await waitUntil({ loader.requests.count == 4 }, "five transfers started at once")
        #expect(pipeline.activeTransferCount == 4)
        #expect(pipeline.queuedTransferCount == 1)

        loader.complete(0, with: testArtworkPNG())
        await waitUntil({ loader.requests.count == 5 }, "the queued transfer did not start")
        for index in 1..<5 {
            loader.complete(index, with: testArtworkPNG())
        }
        for task in tasks { #expect(await task.value != nil) }
        await waitUntil({ pipeline.activeTransferCount == 0 }, "transfers did not finish")
    }

    @Test func bucketsAccountForDisplayScaleAndRejectNonHTTPS() async {
        #expect(ArtworkPipeline.bucket(for: CGSize(width: 100, height: 100), scale: 2) == 256)
        #expect(ArtworkPipeline.bucket(for: CGSize(width: 100, height: 100), scale: 1) == 128)
        #expect(ArtworkPipeline.bucket(for: nil, scale: 2) == 512)

        let loader = ControllableArtworkLoader()
        let pipeline = ArtworkPipeline(loader: loader)
        let insecure = await pipeline.image(for: URL(string: "http://example.test/a.png")!,
                                            targetSize: CGSize(width: 64, height: 64))
        #expect(insecure == nil)
        #expect(loader.requests.isEmpty)
    }
}
