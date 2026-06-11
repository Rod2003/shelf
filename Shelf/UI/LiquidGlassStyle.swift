import SwiftUI

enum ShelfGlass {
    static let panelCornerRadius: CGFloat = 26
}

struct ShelfGlassContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

struct ShelfGlassPanelBackground: ViewModifier {
    let isDropTargeted: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: ShelfGlass.panelCornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .background(Color.accentColor.opacity(isDropTargeted ? 0.08 : 0), in: shape)
                .background(.regularMaterial, in: shape)
                .shadow(color: Color.black.opacity(0.24), radius: 18, x: 0, y: 10)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .shadow(color: Color.black.opacity(0.30), radius: 20, x: 0, y: 12)
        }
    }
}

struct ShelfPanelBorder: View {
    let isDropTargeted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: ShelfGlass.panelCornerRadius, style: .continuous)
            .strokeBorder(
                isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.24),
                lineWidth: isDropTargeted ? 2.5 : 0.75
            )
            .animation(.easeOut(duration: 0.12), value: isDropTargeted)
            .allowsHitTesting(false)
    }
}

struct ShelfGlassCircleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            content
                .background(.regularMaterial, in: Circle())
                .overlay(
                    Circle().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
                )
        }
    }
}

struct ShelfGlassPillBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(0.46), lineWidth: 1)
                        .allowsHitTesting(false)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(.black.opacity(0.20), lineWidth: 0.5)
                        .blendMode(.overlay)
                        .allowsHitTesting(false)
                )
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator.opacity(0.65), lineWidth: 0.75))
        }
    }
}

struct ShelfGlassItemBackground: ViewModifier {
    let isSelected: Bool
    let isHovering: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            nativeContent(content)
        } else {
            fallbackContent(content)
        }
    }

    @available(macOS 26.0, *)
    @ViewBuilder
    private func nativeContent(_ content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(nativeFill)
            )
    }

    private func fallbackContent(_ content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fallbackFill)
            )
    }

    private var fallbackFill: Color {
        if isSelected { return Color.accentColor.opacity(0.30) }
        if isHovering { return Color.primary.opacity(0.06) }
        return .clear
    }

    private var nativeFill: Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        if isHovering { return Color.primary.opacity(0.04) }
        return .clear
    }
}
