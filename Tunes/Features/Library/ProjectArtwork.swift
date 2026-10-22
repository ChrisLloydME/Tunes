import AppKit
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

struct ProjectArtworkPayload: Equatable, Sendable {
    let data: Data
    let fileName: String
    let mimeType: String
}

@MainActor
struct ProjectArtworkSelection {
    let preview: NSImage
    let payload: ProjectArtworkPayload
}

enum ProjectArtworkError: LocalizedError {
    case tooLarge, unsupported, unreadable, tooManyPixels, encodeFailed

    var errorDescription: String? {
        switch self {
        case .tooLarge: "The selected image is too large. Choose one smaller than 30 MB."
        case .unsupported: "The selected file is not a supported image."
        case .unreadable: "The selected image could not be read."
        case .tooManyPixels: "The selected image has too many pixels to process safely."
        case .encodeFailed: "The selected image could not be prepared for upload."
        }
    }
}

enum ProjectArtworkProcessor {
    static let maxSourceBytes = 30 * 1024 * 1024
    static let maxOutputBytes = 6 * 1024 * 1024
    static let maxPixelSize = 2000
    static let maxSourcePixels = 80_000_000

    static func selection(fromFile fileURL: URL) throws -> ProjectArtworkSelection {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        } catch {
            throw ProjectArtworkError.unreadable
        }
        guard values.isRegularFile == true,
              let size = values.fileSize, size > 0 else {
            throw ProjectArtworkError.unreadable
        }
        guard size <= maxSourceBytes else { throw ProjectArtworkError.tooLarge }
        let type = values.contentType ?? UTType(filenameExtension: fileURL.pathExtension)
        guard type?.conforms(to: .image) == true else { throw ProjectArtworkError.unsupported }
        do {
            let data = try Data(contentsOf: fileURL)
            return try selection(from: data,
                                 suggestedName: fileURL.deletingPathExtension().lastPathComponent)
        } catch let error as ProjectArtworkError {
            throw error
        } catch {
            throw ProjectArtworkError.unreadable
        }
    }

    static func selection(from data: Data,
                          suggestedName: String) throws -> ProjectArtworkSelection {
        guard !data.isEmpty else { throw ProjectArtworkError.unreadable }
        guard data.count <= maxSourceBytes else { throw ProjectArtworkError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw ProjectArtworkError.unsupported
        }
        guard width <= maxSourcePixels / max(height, 1) else {
            throw ProjectArtworkError.tooManyPixels
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let flattened = flattened(thumbnail),
              let payload = encoded(flattened, suggestedName: suggestedName) else {
            throw ProjectArtworkError.encodeFailed
        }
        let image = NSImage(cgImage: flattened,
                            size: NSSize(width: flattened.width, height: flattened.height))
        return ProjectArtworkSelection(preview: image, payload: payload)
    }

    private static func flattened(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return nil
        }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func encoded(_ image: CGImage,
                                suggestedName: String) -> ProjectArtworkPayload? {
        let base = (suggestedName as NSString).deletingPathExtension
        let cleaned = base.components(separatedBy: CharacterSet.controlCharacters)
            .joined()
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = cleaned.isEmpty ? "Project Artwork" : String(cleaned.prefix(160))
        let fileName = baseName + ".jpg"
        for quality in [0.86, 0.72, 0.55] as [CGFloat] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output, UTType.jpeg.identifier as CFString, 1, nil
            ) else { continue }
            CGImageDestinationAddImage(destination, image, [
                kCGImageDestinationLossyCompressionQuality: quality
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination),
                  output.length > 0, output.length <= maxOutputBytes else {
                continue
            }
            return ProjectArtworkPayload(data: output as Data, fileName: fileName,
                                         mimeType: UTType.jpeg.preferredMIMEType ?? "image/jpeg")
        }
        return nil
    }
}

@MainActor
@Observable
final class ProjectArtworkSelectionStore {
    private(set) var selection: ProjectArtworkSelection?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var accountID: String?

    func updateAccount(_ newAccountID: String?) {
        guard newAccountID != accountID else { return }
        accountID = newAccountID
        generation = UUID()
        selection = nil
        isLoading = false
        errorMessage = nil
    }

    func load(fileURL: URL, accountID: String?) async {
        await load(accountID: accountID) {
            try ProjectArtworkProcessor.selection(fromFile: fileURL)
        }
    }

    func load(data: Data, suggestedName: String, accountID: String?) async {
        await load(accountID: accountID) {
            try ProjectArtworkProcessor.selection(from: data,
                                                  suggestedName: suggestedName)
        }
    }

    func remove() {
        generation = UUID()
        selection = nil
        isLoading = false
        errorMessage = nil
    }

    func reject(_ message: String) {
        generation = UUID()
        selection = nil
        isLoading = false
        errorMessage = message
    }

    private func load(accountID: String?,
                      operation: @escaping @MainActor () throws -> ProjectArtworkSelection) async {
        guard self.accountID == accountID else { return }
        let token = UUID()
        generation = token
        isLoading = true
        errorMessage = nil
        // A Photos transfer or a second file selection can complete later. Yield
        // first so account changes and replacement selections can invalidate it.
        await Task.yield()
        guard generation == token, self.accountID == accountID else {
            if generation == token { isLoading = false }
            return
        }
        do {
            selection = try operation()
        } catch {
            selection = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
