import AppKit
import Foundation

/// Kaset-compatible facade over the shared artwork pipeline. New code should
/// use `ArtworkPipeline` directly.
@MainActor
enum PlayerArtworkCache {
    static func image(for url: URL, targetSize: CGSize?,
                      diagnostics: SamplyDiagnostics? = nil) async -> NSImage? {
        await ArtworkPipeline.shared.image(for: url, targetSize: targetSize,
                                           diagnostics: diagnostics)
    }
}
