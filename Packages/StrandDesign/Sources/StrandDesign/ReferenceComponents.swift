import SwiftUI

/// Screen-interior tokens from the NOOP concept sheets. Values belong here rather than in screens.
public enum ReferenceStyle {
    public static let canvas = Color(light: "#F3F6F7", dark: "#0D171B")
    public static let surface = Color(light: "#FFFFFF", dark: "#19262C")
    public static let border = Color(light: "#DBE3E6", dark: "#29373D")
    public static let blue = Color(light: "#2379B8", dark: "#62B3EE")
    public static let green = Color(light: "#218150", dark: "#21EA3C")
    public static let purple = Color(light: "#7155AF", dark: "#B79BE4")
    public static let page: CGFloat = 16
    public static let padding: CGFloat = 12
    public static let gap: CGFloat = 8
    public static let section: CGFloat = 16
    public static let radius: CGFloat = 10
    public static let hairline: CGFloat = 0.5
    public static let ringWidth: CGFloat = 6
    public static let chartHeight: CGFloat = 150
    public static let touch: CGFloat = 44
    public static let title = Font.system(.title3, design: .default).weight(.semibold)
    public static let headline = Font.system(.subheadline, design: .default).weight(.semibold)
    public static let body = Font.system(.subheadline, design: .default)
    public static let caption = Font.system(.caption, design: .default)
    public static let value = Font.system(.title2, design: .default).weight(.semibold)
}

/// Flat, compact card without decorative gradients or large shadows.
public struct ReferenceCard<Content: View>: View {
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        content
            .padding(ReferenceStyle.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ReferenceStyle.surface, in: RoundedRectangle(cornerRadius: ReferenceStyle.radius))
            .overlay(RoundedRectangle(cornerRadius: ReferenceStyle.radius)
                .strokeBorder(ReferenceStyle.border, lineWidth: ReferenceStyle.hairline))
    }
}

/// Missing values leave an unfilled track. The progress is always supplied by the existing metric.
public struct ReferenceRing: View {
    let progress: Double?
    let color: Color
    let value: String
    let label: String
    @ScaledMetric(relativeTo: .largeTitle) private var valueSize = 22.0
    public init(progress: Double?, color: Color, value: String, label: String, valueSize: Double = 22) {
        self.progress = progress; self.color = color; self.value = value; self.label = label
        self._valueSize = ScaledMetric(wrappedValue: valueSize, relativeTo: .largeTitle)
    }
    public var body: some View {
        ZStack {
            Circle().stroke(ReferenceStyle.border, lineWidth: ReferenceStyle.ringWidth)
            if let progress {
                Circle().trim(from: 0, to: min(1, max(0, progress)))
                    .stroke(color, style: StrokeStyle(lineWidth: ReferenceStyle.ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: ReferenceStyle.gap) {
                Text(value).font(.system(size: valueSize, weight: .bold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(label).font(ReferenceStyle.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value))
    }
}

public struct ReferenceStressGauge: View {
    let score: Double
    let category: String
    public init(score: Double, category: String) { self.score = score; self.category = category }
    public var body: some View {
        ZStack {
            Circle().trim(from: 0, to: 0.75)
                .stroke(AngularGradient(colors: [ReferenceStyle.blue, ReferenceStyle.green, StrandPalette.statusWarning],
                                        center: .center, startAngle: .degrees(0), endAngle: .degrees(270)),
                        style: StrokeStyle(lineWidth: ReferenceStyle.ringWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle().trim(from: 0, to: 0.006)
                .stroke(StrandPalette.textPrimary, style: StrokeStyle(lineWidth: ReferenceStyle.ringWidth * 3, lineCap: .round))
                .rotationEffect(.degrees(135 + min(3, max(0, score)) / 3 * 270))
            VStack(spacing: ReferenceStyle.gap) {
                Text(score, format: .number.precision(.fractionLength(1)))
                    .font(StrandFont.display(48)).monospacedDigit()
                Text(category).font(ReferenceStyle.headline).foregroundStyle(ReferenceStyle.green)
            }
        }
        .frame(width: ReferenceStyle.chartHeight * 1.5, height: ReferenceStyle.chartHeight * 1.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(category))
        .accessibilityValue(Text(score, format: .number.precision(.fractionLength(1))))
    }
}


/// Original, static vector illustration of a woven optical fitness band.
/// Not a WHOOP product render. The cut-out strap, fabric and raised optical
/// module are drawn without image assets, animations or live-data subscriptions.
public struct ReferenceBandIllustration: View {
    public init() {}

    public var body: some View {
        ZStack {
            // A real opening through the loop: the negative space stays transparent
            // on both light and dark device cards.
            Path { path in
                path.move(to: CGPoint(x: 73, y: 12))
                path.addCurve(to: CGPoint(x: 148, y: 66),
                              control1: CGPoint(x: 116, y: 5), control2: CGPoint(x: 147, y: 28))
                path.addCurve(to: CGPoint(x: 120, y: 165),
                              control1: CGPoint(x: 160, y: 111), control2: CGPoint(x: 150, y: 153))
                path.addCurve(to: CGPoint(x: 44, y: 148),
                              control1: CGPoint(x: 96, y: 179), control2: CGPoint(x: 45, y: 178))
                path.addCurve(to: CGPoint(x: 73, y: 12),
                              control1: CGPoint(x: 13, y: 109), control2: CGPoint(x: 32, y: 28))
                path.closeSubpath()

                path.move(to: CGPoint(x: 77, y: 36))
                path.addCurve(to: CGPoint(x: 122, y: 73),
                              control1: CGPoint(x: 99, y: 31), control2: CGPoint(x: 124, y: 49))
                path.addCurve(to: CGPoint(x: 104, y: 144),
                              control1: CGPoint(x: 130, y: 101), control2: CGPoint(x: 128, y: 139))
                path.addCurve(to: CGPoint(x: 62, y: 133),
                              control1: CGPoint(x: 84, y: 150), control2: CGPoint(x: 59, y: 148))
                path.addCurve(to: CGPoint(x: 77, y: 36),
                              control1: CGPoint(x: 47, y: 98), control2: CGPoint(x: 58, y: 48))
                path.closeSubpath()
            }
            .fill(LinearGradient(colors: [
                StrandPalette.deviceBandFabricLight,
                StrandPalette.deviceBandFabricDark,
                StrandPalette.deviceBandFabricLight.opacity(0.88)
            ], startPoint: .topLeading, endPoint: .bottomTrailing),
                  style: FillStyle(eoFill: true))

            // The exposed upper fabric has a subtle woven herringbone texture.
            // A Canvas is one drawing surface, not dozens of view subscriptions.
            Canvas { context, _ in
                var weave = Path()
                for row in 0..<15 {
                    let y = CGFloat(31 + row * 8)
                    let x = CGFloat(46 + row / 4)
                    weave.move(to: CGPoint(x: x, y: y))
                    weave.addLine(to: CGPoint(x: x + 14, y: y - 5))
                    weave.move(to: CGPoint(x: x + 5, y: y + 2))
                    weave.addLine(to: CGPoint(x: x + 17, y: y + 5))
                }
                context.stroke(weave,
                               with: .color(StrandPalette.onDarkPrimary.opacity(0.13)),
                               lineWidth: 0.8)
            }
            .frame(width: 180, height: 190)
            .mask(
                Path { path in
                    path.move(to: CGPoint(x: 73, y: 12))
                    path.addCurve(to: CGPoint(x: 44, y: 148),
                                  control1: CGPoint(x: 31, y: 34), control2: CGPoint(x: 16, y: 120))
                    path.addLine(to: CGPoint(x: 62, y: 133))
                    path.addCurve(to: CGPoint(x: 77, y: 36),
                                  control1: CGPoint(x: 46, y: 100), control2: CGPoint(x: 60, y: 46))
                    path.closeSubpath()
                }
            )

            // Slightly raised optical module and textile mounting edge.
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(StrandPalette.deviceBandMount)
                .frame(width: 61, height: 88)
                .rotationEffect(.degrees(-13))
                .offset(x: 31, y: 9)
                .shadow(color: StrandPalette.deviceBandShadow.opacity(0.23), radius: 6, x: 0, y: 5)

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(
                    colors: [StrandPalette.deviceBandMetalLight,
                             StrandPalette.deviceBandMetalMid,
                             StrandPalette.deviceBandMetalDark],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 53, height: 80)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(StrandPalette.onDarkPrimary.opacity(0.28), lineWidth: 1)
                }
                .rotationEffect(.degrees(-13))
                .offset(x: 31, y: 9)

            // The sensor surface uses its own dark glass, without a vendor logo.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(StrandPalette.deviceBandSensor)
                .frame(width: 39, height: 51)
                .overlay {
                    VStack(spacing: 5) {
                        Capsule().fill(StrandPalette.onDarkPrimary.opacity(0.22)).frame(width: 15, height: 2)
                        HStack(spacing: 8) {
                            Circle().fill(StrandPalette.deviceBandDetail).frame(width: 8, height: 8)
                            Circle().fill(StrandPalette.deviceBandMetalMid).frame(width: 8, height: 8)
                        }
                    }
                }
                .rotationEffect(.degrees(-13))
                .offset(x: 31, y: 9)
        }
        .frame(width: 180, height: 190)
        .accessibilityHidden(true)
    }
}
