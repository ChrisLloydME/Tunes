import AppKit
import ImageIO

/// One memory-only artwork pipeline for the Library, album header, player bar,
/// and palette extraction. Transfers are coalesced by account epoch and complete
/// URL; decodes are coalesced by account epoch, URL, and pixel-size bucket.
@MainActor
final class ArtworkPipeline {
    static let shared = ArtworkPipeline()

    private struct TransferKey: Hashable {
        let epoch: UInt64
        let url: URL
    }

    private struct DecodeKey: Hashable {
        let epoch: UInt64
        let url: URL
        let bucket: Int
    }

    private struct CachedImage {
        let image: NSImage
        let cost: Int
    }

    private final class SharedTransfer {
        let key: TransferKey
        var waiters: [UUID: CheckedContinuation<Data, Error>] = [:]
        var download: Task<Void, Never>?
        var isRunning = false
        var isQueued = false

        init(key: TransferKey) {
            self.key = key
        }
    }

    private let loader: any BoundedDataLoading
    private let costLimit: Int
    private let maxArtworkBytes = 8 * 1024 * 1024
    private let maxConcurrentTransfers = 4

    private(set) var epoch: UInt64 = 0
    private var cache: [DecodeKey: CachedImage] = [:]
    private var cacheOrder: [DecodeKey] = []
    private var totalCost = 0
    private var palettes: [DecodeKey: ColorExtractor.ColorPalette] = [:]
    private var transfers: [TransferKey: SharedTransfer] = [:]
    private var queuedTransfers: [SharedTransfer] = []
    private var activeTransfers = 0
    private var decodeTasks: [DecodeKey: Task<CGImage?, Never>] = [:]

    init(loader: (any BoundedDataLoading)? = nil,
         costLimit: Int = 32 * 1024 * 1024) {
        self.loader = loader ?? BoundedHTTPDataLoader()
        self.costLimit = costLimit
    }

    var cachedImageCount: Int { cache.count }
    var cachedImageCost: Int { totalCost }
    var cachedPaletteCount: Int { palettes.count }
    var activeTransferCount: Int { activeTransfers }
    var queuedTransferCount: Int { queuedTransfers.count }

    /// Sign-out or an account/session change invalidates every cached image,
    /// palette, transfer, and late decode from the previous epoch.
    func updateEpoch(_ newEpoch: UInt64) {
        guard newEpoch != epoch else { return }
        epoch = newEpoch
        cache.removeAll()
        cacheOrder.removeAll()
        totalCost = 0
        palettes.removeAll()
        for transfer in transfers.values {
            let waiters = transfer.waiters
            transfer.waiters.removeAll()
            for continuation in waiters.values {
                continuation.resume(throwing: CancellationError())
            }
            transfer.download?.cancel()
        }
        transfers.removeAll()
        queuedTransfers.removeAll()
        activeTransfers = 0
        for task in decodeTasks.values { task.cancel() }
        decodeTasks.removeAll()
    }

    /// Returns a decoded image bounded to the requested display pixel bucket.
    func image(for url: URL?, targetSize: CGSize?,
               diagnostics: SamplyDiagnostics? = nil) async -> NSImage? {
        guard let url, url.scheme?.lowercased() == "https" else { return nil }
        let diagnostics = diagnostics ?? .shared
        let operationID = diagnostics.nextOperationID()
        let key = DecodeKey(epoch: epoch, url: url,
                            bucket: Self.bucket(for: targetSize, scale: Self.displayScale))
        if let cached = cachedImage(for: key) {
            diagnostics.record(SamplyDiagnosticSample(
                stage: .artworkCacheHit, command: .artwork, operationID: operationID,
                itemCount: 1))
            return cached
        }

        let transferStartedAt = SystemMonotonicClock().now()
        do {
            let data = try await transferData(for: url)
            try Task.checkCancellation()
            guard key.epoch == epoch else { return nil }
            diagnostics.record(SamplyDiagnosticSample(
                stage: .artworkTransfer, command: .artwork, operationID: operationID,
                duration: SystemMonotonicClock().now() - transferStartedAt,
                responseBytes: data.count))

            let decodeStartedAt = SystemMonotonicClock().now()
            let cgImage: CGImage?
            if let existing = decodeTasks[key] {
                cgImage = await existing.value
            } else {
                let task = Task.detached(priority: .utility) {
                    ArtworkDecoder.downsample(data, maxPixelSize: key.bucket)
                }
                decodeTasks[key] = task
                cgImage = await task.value
                decodeTasks[key] = nil
            }
            guard let cgImage, key.epoch == epoch else { return nil }
            diagnostics.record(SamplyDiagnosticSample(
                stage: .artworkDecode, command: .artwork, operationID: operationID,
                duration: SystemMonotonicClock().now() - decodeStartedAt,
                responseBytes: data.count, itemCount: 1))

            let image = NSImage(cgImage: cgImage,
                                size: NSSize(width: cgImage.width, height: cgImage.height))
            store(image, key: key, cost: max(1, cgImage.bytesPerRow * cgImage.height))
            return image
        } catch {
            diagnostics.record(SamplyDiagnosticSample(
                stage: .artworkTransfer, command: .artwork, operationID: operationID,
                duration: SystemMonotonicClock().now() - transferStartedAt,
                outcome: SamplyDiagnosticOutcome(error)))
            return nil
        }
    }

    /// Extracts and caches a palette for the same decoded-image identity.
    func palette(for url: URL?, targetSize: CGSize = CGSize(width: 64, height: 64))
        async -> ColorExtractor.ColorPalette {
        guard let url else { return .default }
        let key = DecodeKey(epoch: epoch, url: url,
                            bucket: Self.bucket(for: targetSize, scale: Self.displayScale))
        if let cached = palettes[key] { return cached }
        guard let image = await image(for: url, targetSize: targetSize) else { return .default }
        guard key.epoch == epoch else { return .default }
        let palette = ColorExtractor.extractPalette(from: image)
        if palettes.count >= 128 { palettes.removeAll() }
        palettes[key] = palette
        return palette
    }

    // MARK: - Pixel buckets

    static var displayScale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2
    }

    static func bucket(for size: CGSize?, scale: CGFloat) -> Int {
        let width = size?.width ?? 256
        let height = size?.height ?? 256
        let pixels = max(width, height) * max(1, scale)
        let bucket = Int((pixels / 64).rounded(.up)) * 64
        return min(max(bucket, 32), 2_048)
    }

    // MARK: - Transfer coalescing

    private func transferData(for url: URL) async throws -> Data {
        let key = TransferKey(epoch: epoch, url: url)
        let transfer: SharedTransfer
        if let existing = transfers[key] {
            transfer = existing
        } else {
            transfer = SharedTransfer(key: key)
            transfers[key] = transfer
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                transfer.waiters[waiterID] = continuation
                if !transfer.isRunning && !transfer.isQueued {
                    if activeTransfers < maxConcurrentTransfers {
                        start(transfer)
                    } else {
                        transfer.isQueued = true
                        queuedTransfers.append(transfer)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.removeWaiter(waiterID, from: transfer)
            }
        }
    }

    private func start(_ transfer: SharedTransfer) {
        guard transfers[transfer.key] === transfer, !transfer.isRunning else { return }
        transfer.isRunning = true
        transfer.isQueued = false
        activeTransfers += 1
        transfer.download = Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await self.loader.data(from: transfer.key.url,
                                                      maxBytes: self.maxArtworkBytes)
                self.complete(transfer, result: .success(data))
            } catch {
                self.complete(transfer, result: .failure(error))
            }
        }
    }

    private func complete(_ transfer: SharedTransfer, result: Result<Data, Error>) {
        guard transfers[transfer.key] === transfer else { return }
        transfers[transfer.key] = nil
        activeTransfers = max(0, activeTransfers - 1)
        transfer.download = nil
        transfer.isRunning = false
        let waiters = transfer.waiters
        transfer.waiters.removeAll()
        for continuation in waiters.values {
            continuation.resume(with: result)
        }
        startNextQueued()
    }

    private func startNextQueued() {
        while activeTransfers < maxConcurrentTransfers, !queuedTransfers.isEmpty {
            let next = queuedTransfers.removeFirst()
            next.isQueued = false
            guard transfers[next.key] === next, !next.waiters.isEmpty else { continue }
            start(next)
        }
    }

    private func removeWaiter(_ waiterID: UUID, from transfer: SharedTransfer) {
        guard let continuation = transfer.waiters.removeValue(forKey: waiterID) else { return }
        continuation.resume(throwing: CancellationError())
        guard transfer.waiters.isEmpty else { return }
        if transfer.isQueued {
            transfer.isQueued = false
            queuedTransfers.removeAll { $0 === transfer }
            transfers[transfer.key] = nil
        } else if transfer.isRunning {
            transfer.download?.cancel()
            transfer.download = nil
            transfer.isRunning = false
            transfers[transfer.key] = nil
            activeTransfers = max(0, activeTransfers - 1)
            startNextQueued()
        }
    }

    // MARK: - Decoded image cache

    private func cachedImage(for key: DecodeKey) -> NSImage? {
        guard let entry = cache[key] else { return nil }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return entry.image
    }

    private func store(_ image: NSImage, key: DecodeKey, cost: Int) {
        if let old = cache[key] {
            totalCost -= old.cost
            cacheOrder.removeAll { $0 == key }
        }
        cache[key] = CachedImage(image: image, cost: cost)
        cacheOrder.append(key)
        totalCost += cost
        while totalCost > costLimit, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) {
                totalCost -= removed.cost
            }
            palettes[oldest] = nil
        }
    }
}

/// Explicit off-main ImageIO thumbnail decoding. Source pixel dimensions come
/// from the requested bucket rather than the original image size.
enum ArtworkDecoder {
    nonisolated static func downsample(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
