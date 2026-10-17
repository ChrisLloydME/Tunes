import AppKit
import Foundation

/// Supplies Kaset's artwork glow using Tunes artwork URLs and memory-only caching.
@MainActor
enum PlayerArtworkCache {
    private static let images = NSCache<NSURL, NSImage>()
    private static let session = URLSession(configuration: .ephemeral)

    static func image(for url: URL, targetSize: CGSize?) async -> NSImage? {
        if let image = images.object(forKey: url as NSURL) { return image }
        do {
            let (data, response) = try await session.data(from: url)
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data) else { return nil }
            images.totalCostLimit = 4 * 1024 * 1024
            images.setObject(image, forKey: url as NSURL, cost: data.count)
            return image
        } catch {
            return nil
        }
    }
}
