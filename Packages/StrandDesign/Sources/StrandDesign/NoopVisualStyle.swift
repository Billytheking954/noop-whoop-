import SwiftUI

// MARK: - NOOP visual foundation
//
// These tokens describe the visual treatment used by NOOP's existing views. They deliberately
// contain no navigation, state, or domain semantics: screens keep their current hierarchy and data
// bindings, while cards, gauges, typography, and chrome share one maintainable source of truth.

public enum NoopVisualStyle {
    // Chalk and limestone form the light foundation; graphite keeps contrast strong.
    // The dark palette stays deliberately neutral so metric colours remain meaningful.
    public static let canvas = Color(light: "#F2F0E9", dark: "#1D1E23")
    public static let surface = Color(light: "#FFFEFA", dark: "#2A2C34")
    public static let surfaceTop = Color(light: "#FFFFFF", dark: "#30323B")
    public static let surfaceBottom = Color(light: "#FAF8F2", dark: "#282A31")
    public static let inset = Color(light: "#EBE8DF", dark: "#23252C")

    public static let border = Color(light: "#E1DDD2", dark: "#373A44")
    public static let borderHighlight = Color(light: "#FFFFFF", dark: "#4B4E59")
    public static let divider = Color(light: "#E9E5DC", dark: "#383A43")

    public static let primaryText = Color(light: "#252621", dark: "#F7F7FA")
    public static let secondaryText = Color(light: "#5E605A", dark: "#C3C4CA")
    public static let tertiaryText = Color(light: "#81827B", dark: "#7D7F88")

    // Lichen green is the quiet chrome accent; domain scoring colours stay independent.
    public static let mint = Color(light: "#52765B", dark: "#8CC79A")
    public static let mintDeep = Color(light: "#3E6048", dark: "#5D9D6C")
    public static let mintGlow = Color(light: "#79977A", dark: "#A5D2AB")

    public static let cardRadius: CGFloat = 18
    public static let compactRadius: CGFloat = 14
    public static let pillRadius: CGFloat = 999
    public static let pagePadding: CGFloat = 16
    public static let cardPadding: CGFloat = 16
    public static let itemGap: CGFloat = 12
    public static let sectionGap: CGFloat = 26
}

/// Shared card/panel treatment: a near-flat limestone surface, quiet hairline, and restrained depth.
/// `tint` is intentionally faint so metric identity never turns the whole card into a coloured tile.
public struct NoopPanelSurface: View {
    public var tint: Color?
    public var cornerRadius: CGFloat
    public var elevated: Bool
    public var surfaceOpacity: Double
    @Environment(\.colorScheme) private var scheme

    public init(
        tint: Color? = nil,
        cornerRadius: CGFloat = NoopVisualStyle.cardRadius,
        elevated: Bool = false,
        surfaceOpacity: Double = 1
    ) {
        self.tint = tint
        self.cornerRadius = cornerRadius
        self.elevated = elevated
        self.surfaceOpacity = surfaceOpacity
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(
                LinearGradient(
                    colors: [NoopVisualStyle.surfaceTop, NoopVisualStyle.surfaceBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                if let tint {
                    shape.fill(
                        LinearGradient(
                            colors: [tint.opacity(0.045), tint.opacity(0.008), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [NoopVisualStyle.borderHighlight.opacity(0.72), NoopVisualStyle.border.opacity(0.52)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
            )
            .shadow(
                color: scheme == .dark ? .black.opacity(elevated ? 0.30 : 0.12) : .black.opacity(elevated ? 0.075 : 0.035),
                radius: elevated ? 16 : 10,
                x: 0,
                y: elevated ? 7 : 3
            )
            .opacity(surfaceOpacity)
    }
}

/// Shared edge-to-edge chrome for sheet and split-view headers. Unlike a card it has no
/// rounded outline or elevation, but it uses the same top-lit surface ramp and divider token.
public struct NoopChromeSurface: View {
    public init() {}

    public var body: some View {
        LinearGradient(
            colors: [NoopVisualStyle.surfaceTop, NoopVisualStyle.surfaceBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(NoopVisualStyle.divider)
                .frame(height: 0.5)
        }
    }
}

public extension View {
    func noopPanel(
        tint: Color? = nil,
        cornerRadius: CGFloat = NoopVisualStyle.cardRadius,
        elevated: Bool = false,
        surfaceOpacity: Double = 1
    ) -> some View {
        background {
            NoopPanelSurface(
                tint: tint,
                cornerRadius: cornerRadius,
                elevated: elevated,
                surfaceOpacity: surfaceOpacity
            )
        }
    }
}
