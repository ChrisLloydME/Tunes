import AppKit
import Foundation

/// Supplies Kaset's artwork glow using Tunes artwork URLs and memory-only caching.
@MainActor
enum PlayerArtworkCache {
    private static let images = NSCache<NSURL, NSImage>()
    private static let session = URLSession(configuration: .ephemeral)

    static func image(for url: URL, targetSize: CGSize?,
                      diagnostics: SamplyDiagnostics? = nil) async -> NSImage? {
        let diagnostics = diagnostics ?? .shared
        let operationID = diagnostics.nextOperationID()
        if let image = images.object(forKey: url as NSURL) {
            diagnostics.record(SamplyDiagnosticSample(stage: .artworkCacheHit,
                                                      operationID: operationID, itemCount: 1))
            return image
        }
        let clock = SystemMonotonicClock()
        let transferStartedAt = clock.now()
        do {
            let (data, response) = try await session.data(from: url)
            try Task.checkCancellation()
            let status = (response as? HTTPURLResponse)?.statusCode
            diagnostics.record(SamplyDiagnosticSample(
                stage: .artworkTransfer, command: .artwork, operationID: operationID,
                duration: clock.now() - transferStartedAt, responseBytes: data.count,
                outcome: status == 200 ? .success : .failure))
            guard status == 200 else { return nil }
            let decodeStartedAt = clock.now()
            guard let image = NSImage(data: data) else {
                diagnostics.record(SamplyDiagnosticSample(
                    stage: .artworkDecode, command: .artwork, operationID: operationID,
                    duration: clock.now() - decodeStartedAt, responseBytes: data.count,
                    outcome: .failure))
                return nil
            }
            diagnostics.record(SamplyDiagnosticSample(
                stage: .artworkDecode, command: .artwork, operationID: operationID,
                duration: clock.now() - decodeStartedAt, responseBytes: data.count,
                itemCount: 1))
            images.totalCostLimit = 4 * 1024 * 1024
            images.setObject(image, forKey: url as NSURL, cost: data.count)
            return image
        } catch {
            diagnostics.record(SamplyDiagnosticSample(
                stage: .artworkTransfer, command: .artwork, operationID: operationID,
                duration: clock.now() - transferStartedAt,
                outcome: SamplyDiagnosticOutcome(error)))
            return nil
        }
    }
}
