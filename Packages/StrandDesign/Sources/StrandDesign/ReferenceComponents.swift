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
    public static let ringWidth: CGFloat = 4
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


/// Original vector artwork shared by connection and device screens.
public struct ReferenceBandIllustration: View {
    public init() {}
    public var body: some View {
        ZStack {
            Ellipse().stroke(Color(white: 0.17), lineWidth: 24)
                .frame(width: 104, height: 150)
            Ellipse().stroke(Color(white: 0.35), lineWidth: 1)
                .frame(width: 104, height: 150)
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [Color(white: 0.43), Color(white: 0.12)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.42), lineWidth: 1))
                .frame(width: 46, height: 80).offset(x: 47, y: 6)
        }
        .rotationEffect(.degrees(-23))
        .frame(width: 180, height: 190)
        .accessibilityHidden(true)
    }
}
