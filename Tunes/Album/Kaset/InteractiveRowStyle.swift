// From Kaset InteractiveCardStyle.swift, MIT license.
// Removed haptics; inlined the upstream animation constant.
import SwiftUI

struct InteractiveRowStyle: ButtonStyle {
    /// Corner radius for the hover background.
    var cornerRadius: CGFloat = 8

    /// Hover background color.
    var hoverColor: Color = .primary.opacity(0.06)

    /// Hover state from a parent that already tracks hover. When set, the style skips its
    /// own hover tracker, which adds up across the rows of a long list.
    var isHovered: Bool?

    @State private var isHovering = false

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if self.isHovered == nil {
            self.highlightedLabel(configuration, isHovered: self.isHovering)
                .onHover { hovering in
                    self.isHovering = hovering
                }
        } else {
            self.highlightedLabel(configuration, isHovered: self.isHovered == true)
        }
    }

    private func highlightedLabel(_ configuration: Configuration, isHovered: Bool) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: self.cornerRadius)
                    .fill(isHovered || configuration.isPressed ? self.hoverColor : .clear)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

extension ButtonStyle where Self == InteractiveRowStyle {
    static func interactiveRow(cornerRadius: CGFloat = 8, isHovered: Bool? = nil) -> InteractiveRowStyle {
        InteractiveRowStyle(cornerRadius: cornerRadius, isHovered: isHovered)
    }
}
