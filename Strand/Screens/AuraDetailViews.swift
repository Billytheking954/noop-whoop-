import Foundation
import SwiftUI
import Charts
import StrandDesign

// Aura presentation detail screens. The original V2 screens remain the
// authority for editing sleep, managing workouts and inspecting the full record.
// These screens must never infer per-sample provenance from Repository.days.

private struct AuraDetailHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            NoopSpecCaption(subtitle)
            Text(title)
                .font(NoopSpecType.screenTitle)
                .foregroundStyle(NoopPalette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AuraDetailReading: View {
    let title: String
    let reading: AuraDailyReading
    let tint: Color
    var digits = 0

    private var statusLabel: String {
        switch reading.state {
        case .loading: return String(localized: "Loading reading", table: "AuraPreview")
        case .available: return String(localized: "Daily aggregate", table: "AuraPreview")
        case .stale: return String(localized: "Older reading", table: "AuraPreview")
        case .unavailable: return String(localized: "No measured data", table: "AuraPreview")
        case .failed: return String(localized: "Reading unavailable", table: "AuraPreview")
        }
    }

    var body: some View {
        NoopSpecCard {
            VStack(alignment: .leading, spacing: 9) {
                NoopSpecCaption(title)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(reading.value.map { String(format: "%.*f", digits, $0) } ?? "—")
                        .font(NoopSpecType.headline)
                        .foregroundStyle(tint)
                    if reading.value != nil {
                        Text(reading.unit)
                            .font(NoopSpecType.subline)
                            .foregroundStyle(NoopPalette.textSecondary)
                    }
                }
                Text(statusLabel)
                    .font(NoopSpecType.finePrint)
                    .foregroundStyle(NoopPalette.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

struct AuraRestDetailView: View {
    @EnvironmentObject private var repo: Repository

    private var current: AuraRestState {
        AuraRestAdapter.map(repo.today, todayKey: Repository.logicalDayKey(Date()))
    }

    var body: some View {
        ZStack {
            NoopPalette.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AuraDetailHeading(
                        title: String(localized: "Rest", table: "AuraPreview"),
                        subtitle: String(localized: "Today", table: "AuraPreview"))
                    AuraDetailReading(
                        title: String(localized: "Time asleep", table: "AuraPreview"),
                        reading: current.sleepMinutes, tint: NoopPalette.rest)
                    AuraDetailReading(
                        title: String(localized: "Sleep efficiency", table: "AuraPreview"),
                        reading: current.sleepEfficiency, tint: NoopPalette.rest)
                    HStack(alignment: .top, spacing: 12) {
                        AuraDetailReading(
                            title: String(localized: "Deep sleep (estimated)", table: "AuraPreview"),
                            reading: current.deepMinutes, tint: NoopPalette.rest)
                        AuraDetailReading(
                            title: String(localized: "REM sleep (estimated)", table: "AuraPreview"),
                            reading: current.remMinutes, tint: NoopPalette.rest)
                    }
                    Text(String(localized: "Sleep stages are estimates. Original sleep records and editing stay in the V2 dashboard.", table: "AuraPreview"))
                        .font(NoopSpecType.body)
                        .foregroundStyle(NoopPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    AuraSleepHistorySection()

                    NavigationLink {
                        SleepView()
                    } label: {
                        AuraDetailDestinationLabel(
                            title: String(localized: "Open sleep records", table: "AuraPreview"),
                            symbol: "bed.double")
                    }
                    .buttonStyle(.plain)
                }
                .padding(18)
            }
            .refreshable { await repo.refresh() }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AuraFitnessDetailView: View {
    @EnvironmentObject private var repo: Repository

    private var current: AuraFitnessState {
        AuraFitnessAdapter.map(repo.today, todayKey: Repository.logicalDayKey(Date()))
    }

    var body: some View {
        ZStack {
            NoopPalette.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AuraDetailHeading(
                        title: String(localized: "Activity", table: "AuraPreview"),
                        subtitle: String(localized: "Today", table: "AuraPreview"))
                    AuraDetailReading(
                        title: String(localized: "NOOP Effort", table: "AuraPreview"),
                        reading: current.effort, tint: NoopPalette.effort)
                    AuraDetailReading(
                        title: String(localized: "Steps", table: "AuraPreview"),
                        reading: current.steps, tint: NoopPalette.accent)
                    Text(String(localized: "Stored activity score from V2. Imported and computed values may differ; missing samples are not fabricated.", table: "AuraPreview"))
                        .font(NoopSpecType.body)
                        .foregroundStyle(NoopPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    AuraWorkoutHistorySection()

                    NavigationLink {
                        WorkoutsView()
                    } label: {
                        AuraDetailDestinationLabel(
                            title: String(localized: "Open workouts", table: "AuraPreview"),
                            symbol: "figure.run")
                    }
                    .buttonStyle(.plain)
                }
                .padding(18)
            }
            .refreshable { await repo.refresh() }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AuraDetailDestinationLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        NoopSpecCard(.row) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(NoopSpecTokens.auraPale)
                Text(title)
                    .font(NoopSpecType.buttonLabel)
                    .foregroundStyle(NoopPalette.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(NoopPalette.textSecondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(.isButton)
    }
}

struct AuraTrendsDetailView: View {
    @EnvironmentObject private var repo: Repository
    @State private var selection = 0
    @State private var rangeDays = 30

    private struct ChartReading: Identifiable {
        let day: String
        let date: Date
        let value: Double
        var id: String { day }
    }

    private static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()

    private var metric: AuraTrendsAdapter.Metric {
        switch selection {
        case 1: return .restingHeartRate
        case 2: return .sleepMinutes
        case 3: return .effort
        case 4: return .charge
        default: return .hrv
        }
    }

    private var points: [ChartReading] {
        // Anchor to the phone's logical day, not an old imported last day.
        // Bars show only stored observations: a missing day never becomes a
        // synthetic zero or a connected/interpolated line segment.
        let anchor = Repository.logicalDayKey(Date())
        let threshold: String = {
            guard let date = Self.parser.date(from: anchor),
                  let start = Calendar(identifier: .gregorian).date(byAdding: .day, value: -(rangeDays - 1), to: date)
            else { return anchor }
            return Self.parser.string(from: start)
        }()
        return AuraTrendsAdapter.map(repo.days, metric: metric)
            .compactMap { sample -> ChartReading? in
                guard sample.day >= threshold, sample.day <= anchor,
                      let date = Self.parser.date(from: sample.day),
                      Self.parser.string(from: date) == sample.day else { return nil }
                return ChartReading(day: sample.day, date: date, value: sample.value)
            }
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        ZStack {
            NoopPalette.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AuraDetailHeading(
                        title: String(localized: "Trends", table: "AuraPreview"),
                        subtitle: String(format: String(localized: "Past %d days", table: "AuraPreview"), rangeDays))
                    Picker(String(localized: "Period", table: "AuraPreview"), selection: $rangeDays) {
                        Text(verbatim: "7D").tag(7)
                        Text(verbatim: "30D").tag(30)
                        Text(verbatim: "90D").tag(90)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel(Text(String(localized: "Period", table: "AuraPreview")))
                    Picker(String(localized: "Metric", table: "AuraPreview"), selection: $selection) {
                        Text(String(localized: "Overnight HRV", table: "AuraPreview")).tag(0)
                        Text(String(localized: "Resting HR", table: "AuraPreview")).tag(1)
                        Text(String(localized: "Rest", table: "AuraPreview")).tag(2)
                        Text(String(localized: "NOOP Effort", table: "AuraPreview")).tag(3)
                        Text(String(localized: "Charge / Recovery", table: "AuraPreview")).tag(4)
                    }
                    .pickerStyle(.menu)
                    .tint(NoopSpecTokens.auraPale)
                    .accessibilityLabel(Text(String(localized: "Metric", table: "AuraPreview")))
                    NoopSpecCard {
                        VStack(alignment: .leading, spacing: 14) {
                            if points.isEmpty {
                                Text(String(localized: "No measurements in this period", table: "AuraPreview"))
                                    .font(NoopSpecType.body)
                                    .foregroundStyle(NoopPalette.textSecondary)
                                    .frame(maxWidth: .infinity, minHeight: 150)
                            } else {
                                Chart(points) { reading in
                                    BarMark(
                                        x: .value("Date", reading.date),
                                        y: .value("Value", reading.value))
                                    .foregroundStyle(NoopSpecTokens.auraPale)
                                }
                                .frame(height: 210)
                                .accessibilityLabel(Text(String(localized: "Recorded daily values", table: "AuraPreview")))
                            }
                            Text(String(localized: "Gaps indicate missing measurements; no values are estimated.", table: "AuraPreview"))
                                .font(NoopSpecType.finePrint)
                                .foregroundStyle(NoopPalette.textSecondary)
                        }
                    }
                    NavigationLink {
                        TrendsView()
                    } label: {
                        AuraDetailDestinationLabel(
                            title: String(localized: "Open full trends", table: "AuraPreview"),
                            symbol: "chart.line.uptrend.xyaxis")
                    }
                    .buttonStyle(.plain)
                }
                .padding(18)
            }
            .refreshable { await repo.refresh() }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}
