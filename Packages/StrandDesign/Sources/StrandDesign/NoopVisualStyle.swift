import SwiftUI

// MARK: - NOOP visual foundation
//
// These tokens describe the visual treatment used by NOOP's existing views. They deliberately
// contain no navigation, state, or domain semantics: screens keep their current hierarchy and data
// bindings, while cards, gauges, typography, and chrome share one maintainable source of truth.

public enum NoopVisualStyle {
    // NOOP's cool mineral canvas and midnight ink give the metrics room to lead.
    // CRUX contributes spacing discipline, while the colour and atmosphere remain NOOP's own.
    public static let canvas = Color(light: "#F4F7FA", dark: "#10151E")
    public static let surface = Color(light: "#FFFFFF", dark: "#1C2531")
    public static let surfaceTop = Color(light: "#FFFFFF", dark: "#243141")
    public static let surfaceBottom = Color(light: "#FAFCFE", dark: "#1B2633")
    public static let inset = Color(light: "#E9EFF4", dark: "#141D28")

    public static let border = Color(light: "#DCE4EB", dark: "#2C3948")
    public static let borderHighlight = Color(light: "#FFFFFF", dark: "#4B5C70")
    public static let divider = Color(light: "#E3EAF0", dark: "#334153")

    public static let primaryText = Color(light: "#18212C", dark: "#F4F8FC")
    public static let secondaryText = Color(light: "#536170", dark: "#BAC7D5")
    public static let tertiaryText = Color(light: "#6E7C8A", dark: "#8F9EB0")

    // Tide green anchors navigation and controls; domain scoring colours stay independent.
    public static let mint = Color(light: "#147D6C", dark: "#6AD9B8")
    public static let mintDeep = Color(light: "#0D655B", dark: "#36B994")
    public static let mintGlow = Color(light: "#42A995", dark: "#A3E4D4")

    public static let cardRadius: CGFloat = 18
    public static let compactRadius: CGFloat = 14
    public static let pillRadius: CGFloat = 999
    public static let pagePadding: CGFloat = 16
    public static let cardPadding: CGFloat = 16
    public static let itemGap: CGFloat = 12
    public static let sectionGap: CGFloat = 24
}

/// Shared card/panel treatment: a cool surface, quiet hairline, and restrained depth.
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
