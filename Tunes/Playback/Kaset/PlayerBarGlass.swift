// Native macOS branch of Kaset's LiquidGlassCompat.swift, MIT license.
// Tunes targets macOS 27, so legacy material fallbacks are unnecessary.
import SwiftUI

extension View {
    func compatGlass(interactive: Bool = false, tint: Color? = nil, in shape: some Shape) -> some View {
        var glass: Glass = .regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return self.glassEffect(glass, in: shape)
    }

    func compatGlassID(_ id: String, in namespace: Namespace.ID) -> some View {
        self.glassEffectID(id, in: namespace)
    }
}

struct CompatGlassContainer<Content: View>: View {
    var spacing: CGFloat = 0
    @ViewBuilder var content: () -> Content

    var body: some View {
        GlassEffectContainer(spacing: self.spacing) { self.content() }
    }
}
