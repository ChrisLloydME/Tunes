import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import Tunes

@MainActor
struct AlbumPaletteTests {
    private func artwork(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) throws -> NSImage {
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        return NSImage(cgImage: image, size: NSSize(width: 8, height: 8))
    }

    @Test func brightWarmArtworkProducesAWarmPaletteInsteadOfTheFallback() throws {
        for green: CGFloat in [0, 0.4] {
            let image = try artwork(red: 1, green: green, blue: 0)
            let palette = ColorExtractor.extractPalette(from: image)
            #expect(palette != .default)
            let tint = try #require(NSColor(palette.lightTint).usingColorSpace(.sRGB))
            #expect(tint.redComponent > tint.blueComponent + 0.2)
        }
    }

    @Test func brightCoolArtworkKeepsItsOwnHue() throws {
        let image = try artwork(red: 0, green: 0.2, blue: 1)
        let palette = ColorExtractor.extractPalette(from: image)
        #expect(palette != .default)
        let tint = try #require(NSColor(palette.lightTint).usingColorSpace(.sRGB))
        #expect(tint.blueComponent > tint.redComponent + 0.2)
    }

    @Test func translucentArtworkRetainsItsHueAfterUnpremultiplication() throws {
        let image = try artwork(red: 1, green: 0.4, blue: 0, alpha: 0.5)
        let palette = ColorExtractor.extractPalette(from: image)
        #expect(palette != .default)
        let tint = try #require(NSColor(palette.lightTint).usingColorSpace(.sRGB))
        #expect(tint.redComponent > tint.blueComponent + 0.2)
    }

    @Test func missingOrUnusableArtworkDoesNotBorrowTheControlAccent() throws {
        let fallback = try #require(NSColor(ColorExtractor.ColorPalette.default.lightTint).usingColorSpace(.sRGB))
        #expect(fallback.alphaComponent == 0)
        for image in [try artwork(red: 1, green: 1, blue: 1),
                      try artwork(red: 0, green: 0, blue: 0),
                      try artwork(red: 1, green: 0, blue: 0, alpha: 0)] {
            #expect(ColorExtractor.extractPalette(from: image) == .default)
        }
    }
}
