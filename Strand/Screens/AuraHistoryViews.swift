import SwiftUI
import Charts
import StrandDesign
import WhoopStore

// Read-only Aura presentation. All sessions and buckets originate from Repository.
// Sleep editing and workout recording remain owned by the original V2 screens.
enum AuraSessionHistory {
    static func sleep(_ rows: [CachedSleepSession], limit: Int = 10) -> [CachedSleepSession] {
        Array(rows.filter { $0.endTs > $0.effectiveStartTs }
            .sorted { $0.endTs > $1.endTs }
            .prefix(max(0, limit)))
    }

    static func workouts(_ rows: [WorkoutRow], limit: Int = 10) -> [WorkoutRow] {
        Array(rows.filter { $0.endTs > $0.startTs }
            .sorted { $0.startTs > $1.startTs }
            .prefix(max(0, limit)))
    }

    struct TimedStage: Decodable, Equatable {
        let start: Int
        let end: Int
        let stage: String
    }

    struct StageSummary: Equatable {
        let awakeMinutes: Double
        let lightMinutes: Double
        let deepMinutes: Double
        let remMinutes: Double
        let hasTimedIntervals: Bool

        var asleepMinutes: Double { lightMinutes + deepMinutes + remMinutes }
        var inBedMinutes: Double { asleepMinutes + awakeMinutes }
    }

    /// Imported stage totals have NO timestamps: never fabricate positions on a graph.
    static func timedStages(_ session: CachedSleepSession) -> [TimedStage] {
        guard let json = session.stagesJSON,
              let data = json.data(using: .utf8),
              let segments = try? JSONDecoder().decode([TimedStage].self, from: data)
        else { return [] }
        let accepted: Set<String> = ["wake", "awake", "light", "deep", "rem"]
        return segments.compactMap { segment in
            let start = max(session.effectiveStartTs, segment.start)
            let end = min(session.endTs, segment.end)
            guard end > start, accepted.contains(segment.stage) else { return nil }
            return TimedStage(start: start, end: end, stage: segment.stage)
        }.sorted { $0.start < $1.start }
    }

    /// Decode both V2 sleep-stage shapes without converting timestamp-free totals into a timeline.
    /// Timed segments are clipped to the user's effective sleep window before their totals are shown.
    static func stageSummary(_ session: CachedSleepSession) -> StageSummary? {
        let timed = timedStages(session)
        if !timed.isEmpty {
            func minutes(_ names: Set<String>) -> Double {
                timed.filter { names.contains($0.stage) }
                    .reduce(0) { $0 + Double($1.end - $1.start) / 60 }
            }
            return StageSummary(
                awakeMinutes: minutes(Set(["wake", "awake"])),
                lightMinutes: minutes(Set(["light"])),
                deepMinutes: minutes(Set(["deep"])),
                remMinutes: minutes(Set(["rem"])),
                hasTimedIntervals: true)
        }

        guard let json = session.stagesJSON,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let totals = object as? [String: Any] else { return nil }
        func value(_ key: String) -> Double {
            (totals[key] as? NSNumber)?.doubleValue ?? 0
        }
        let summary = StageSummary(
            awakeMinutes: max(0, value("awake")),
            lightMinutes: max(0, value("light")),
            deepMinutes: max(0, value("deep")),
            remMinutes: max(0, value("rem")),
            hasTimedIntervals: false)
        return summary.inBedMinutes > 0 ? summary : nil
    }
}

private struct AuraHistoryRow: View {
    let title: String
    let description: String
    let symbol: String

    var body: some View {
        NoopSpecCard(.row) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(NoopSpecTokens.auraPale)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(NoopSpecType.cardTitle)
                        .foregroundStyle(NoopPalette.textPrimary)
                    Text(description).font(NoopSpecType.bodySmall)
                        .foregroundStyle(NoopPalette.textSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .foregroundStyle(NoopPalette.textSecondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 48)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

struct AuraSleepHistorySection: View {
    @EnvironmentObject private var repo: Repository
    @State private var nights: [CachedSleepSession] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Recent nights", table: "AuraPreview"))
                .font(NoopSpecType.sectionHead)
                .foregroundStyle(NoopPalette.textPrimary)
            if !repo.loaded {
                ProgressView().tint(NoopPalette.rest)
                    .accessibilityLabel(Text(String(localized: "Loading reading", table: "AuraPreview")))
            } else if nights.isEmpty {
                Text(String(localized: "No recorded sleep sessions", table: "AuraPreview"))
                    .font(NoopSpecType.body)
                    .foregroundStyle(NoopPalette.textSecondary)
            } else {
                ForEach(Array(AuraSessionHistory.sleep(nights).enumerated()), id: \.offset) { _, session in
                    NavigationLink {
                        AuraSleepNightDetail(session: session)
                    } label: {
                        AuraHistoryRow(
                            title: Date(timeIntervalSince1970: TimeInterval(session.endTs))
                                .formatted(date: .abbreviated, time: .omitted),
                            description: String(
                                format: String(localized: "%.0f min in bed", table: "AuraPreview"),
                                Double(session.endTs - session.effectiveStartTs) / 60),
                            symbol: "moon.stars")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task(id: repo.refreshSeq) {
            nights = await repo.allSleepSessions(days: 90)
        }
    }
}

struct AuraSleepNightDetail: View {
    @EnvironmentObject private var repo: Repository
    let session: CachedSleepSession

    private var stages: [AuraSessionHistory.TimedStage] {
        AuraSessionHistory.timedStages(session)
    }

    private var stageSummary: AuraSessionHistory.StageSummary? {
        AuraSessionHistory.stageSummary(session)
    }

    private var daily: DailyMetric? {
        let day = Repository.localDayKey(
            Date(timeIntervalSince1970: TimeInterval(session.endTs)))
        return repo.days.first { $0.day == day }
    }

    private var inBedMinutes: Double {
        Double(max(0, session.endTs - session.effectiveStartTs)) / 60
    }

    private var asleepMinutes: Double? {
        if let value = stageSummary?.asleepMinutes, value > 0 { return value }
        guard let efficiency = session.efficiency, efficiency.isFinite,
              (0...1).contains(efficiency) else { return nil }
        return inBedMinutes * efficiency
    }

    private var efficiencyPercent: Double? {
        if let summary = stageSummary, summary.inBedMinutes > 0 {
            return summary.asleepMinutes / summary.inBedMinutes * 100
        }
        guard let efficiency = session.efficiency, efficiency.isFinite,
              (0...1).contains(efficiency) else { return nil }
        return efficiency * 100
    }

    private func color(_ stage: String) -> Color {
        switch stage {
        case "deep": return NoopPalette.accent
        case "rem": return NoopPalette.rest
        case "light": return NoopSpecTokens.auraPale
        default: return NoopPalette.effort
        }
    }

    var body: some View {
        ZStack {
            NoopPalette.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(String(localized: "Sleep window", table: "AuraPreview"))
                        .font(NoopSpecType.screenTitle)
                        .foregroundStyle(NoopPalette.textPrimary)
                    NoopSpecCard(.hero) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(Date(timeIntervalSince1970: TimeInterval(session.effectiveStartTs))
                                .formatted(date: .abbreviated, time: .shortened))
                                .font(NoopSpecType.headline)
                                .foregroundStyle(NoopPalette.textPrimary)
                            Image(systemName: "arrow.down")
                                .foregroundStyle(NoopPalette.rest)
                            Text(Date(timeIntervalSince1970: TimeInterval(session.endTs))
                                .formatted(date: .abbreviated, time: .shortened))
                                .font(NoopSpecType.headline)
                                .foregroundStyle(NoopPalette.textPrimary)
                            Text(String(localized: "Time in bed, not time asleep", table: "AuraPreview"))
                                .font(NoopSpecType.finePrint)
                                .foregroundStyle(NoopPalette.textSecondary)
                            if let deviceId = session.deviceId {
                                Text(String(localized: "Stored source ID", table: "AuraPreview") + ": " + deviceId)
                                    .font(NoopSpecType.finePrint)
                                    .foregroundStyle(NoopPalette.textSecondary)
                                    .textSelection(.enabled)
                            } else {
                                Text(String(localized: "Source unknown", table: "AuraPreview"))
                                    .font(NoopSpecType.finePrint)
                                    .foregroundStyle(NoopPalette.textSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        sleepMetric(title: "Time in bed", value: inBedMinutes, unit: "min",
                                    tint: NoopSpecTokens.auraPale)
                        sleepMetric(title: "Time asleep", value: asleepMinutes, unit: "min",
                                    tint: NoopPalette.rest)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        sleepMetric(title: "Efficiency", value: efficiencyPercent, unit: "%",
                                    tint: NoopPalette.rest)
                        sleepMetric(title: "Charge / Recovery", value: daily?.recovery, unit: "%",
                                    tint: NoopSpecTokens.auraPale)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        sleepMetric(title: "Overnight HRV", value: session.avgHrv, unit: "ms",
                                    tint: NoopPalette.rest, digits: 1)
                        sleepMetric(title: "Resting HR", value: session.restingHr.map(Double.init), unit: "bpm",
                                    tint: NoopPalette.accent)
                    }

                    NoopSpecCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(String(localized: "Stage timeline", table: "AuraPreview"))
                                .font(NoopSpecType.cardTitle)
                                .foregroundStyle(NoopPalette.textPrimary)
                            if stages.isEmpty {
                                Text(String(localized: "Timed stage data unavailable; no timeline has been invented.", table: "AuraPreview"))
                                    .font(NoopSpecType.bodySmall)
                                    .foregroundStyle(NoopPalette.textSecondary)
                            } else {
                                GeometryReader { geometry in
                                    ZStack(alignment: .leading) {
                                        ForEach(Array(stages.enumerated()), id: \.offset) { _, segment in
                                            let total = Double(session.endTs - session.effectiveStartTs)
                                            let x = Double(segment.start - session.effectiveStartTs) / total
                                            let width = Double(segment.end - segment.start) / total
                                            Rectangle()
                                                .fill(color(segment.stage))
                                                .frame(width: max(1, geometry.size.width * CGFloat(width)), height: 25)
                                                .offset(x: geometry.size.width * CGFloat(x))
                                        }
                                    }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                                .frame(height: 25)
                                .accessibilityLabel(Text(String(localized: "Stored estimated sleep stages", table: "AuraPreview")))
                                Text(String(localized: "Stages are estimates; blank sections have no timed data.", table: "AuraPreview"))
                                    .font(NoopSpecType.finePrint)
                                    .foregroundStyle(NoopPalette.textSecondary)
                            }
                            if session.userEdited {
                                Text(String(localized: "Sleep times manually edited", table: "AuraPreview"))
                                    .font(NoopSpecType.finePrint)
                                    .foregroundStyle(NoopPalette.textSecondary)
                            }
                            if session.stagingSparse == true {
                                Text(String(localized: "Sparse motion data: staging may be incomplete", table: "AuraPreview"))
                                    .font(NoopSpecType.bodySmall)
                                    .foregroundStyle(NoopPalette.effort)
                            }
                        }
                    }

                    if let summary = stageSummary {
                        NoopSpecCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(String(localized: "Sleep-stage breakdown", table: "AuraPreview"))
                                    .font(NoopSpecType.cardTitle)
                                    .foregroundStyle(NoopPalette.textPrimary)
                                stageRow("Awake", minutes: summary.awakeMinutes, tint: NoopPalette.effort)
                                stageRow("REM", minutes: summary.remMinutes, tint: NoopPalette.rest)
                                stageRow("Light", minutes: summary.lightMinutes, tint: NoopSpecTokens.auraPale)
                                stageRow("Deep", minutes: summary.deepMinutes, tint: NoopPalette.accent)
                                Text(summary.hasTimedIntervals
                                     ? String(localized: "Breakdown calculated from stored timed intervals.", table: "AuraPreview")
                                     : String(localized: "Aggregate stage durations; no timing order is available.", table: "AuraPreview"))
                                    .font(NoopSpecType.finePrint)
                                    .foregroundStyle(NoopPalette.textSecondary)
                            }
                        }
                    }
                    NavigationLink {
                        SleepView()
                    } label: {
                        AuraHistoryRow(
                            title: String(localized: "Edit or inspect in V2 Sleep", table: "AuraPreview"),
                            description: String(localized: "Original editing and full sleep analysis", table: "AuraPreview"),
                            symbol: "pencil")
                    }
                    .buttonStyle(.plain)
                }
                .padding(18)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sleepMetric(title: LocalizedStringKey, value: Double?, unit: String,
                             tint: Color, digits: Int = 0) -> some View {
        NoopSpecCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(NoopSpecType.cardTitle)
                    .foregroundStyle(NoopPalette.textPrimary)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value.map { String(format: "%.*f", digits, $0) } ?? "—")
                        .font(NoopSpecType.headline)
                        .foregroundStyle(tint)
                        .minimumScaleFactor(0.7)
                    if value != nil {
                        Text(unit)
                            .font(NoopSpecType.subline)
                            .foregroundStyle(NoopPalette.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func stageRow(_ title: LocalizedStringKey, minutes: Double, tint: Color) -> some View {
        HStack(spacing: 10) {
            Circle().fill(tint).frame(width: 9, height: 9)
                .accessibilityHidden(true)
            Text(title)
                .font(NoopSpecType.body)
                .foregroundStyle(NoopPalette.textPrimary)
            Spacer()
            Text(String(format: String(localized: "%.0f min", table: "AuraPreview"), minutes))
                .font(NoopSpecType.rowFigure)
                .foregroundStyle(NoopPalette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct AuraWorkoutHistorySection: View {
    @EnvironmentObject private var repo: Repository
    @State private var workouts: [WorkoutRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Recent workouts", table: "AuraPreview"))
                .font(NoopSpecType.sectionHead)
                .foregroundStyle(NoopPalette.textPrimary)
            if !repo.loaded {
                ProgressView().tint(NoopPalette.accent)
                    .accessibilityLabel(Text(String(localized: "Loading reading", table: "AuraPreview")))
            } else if workouts.isEmpty {
                Text(String(localized: "No recorded workouts", table: "AuraPreview"))
                    .font(NoopSpecType.body)
                    .foregroundStyle(NoopPalette.textSecondary)
            } else {
                ForEach(Array(AuraSessionHistory.workouts(workouts).enumerated()), id: \.offset) { _, row in
                    NavigationLink {
                        AuraWorkoutSessionDetail(row: row)
                    } label: {
                        AuraHistoryRow(
                            title: row.sport,
                            description: Date(timeIntervalSince1970: TimeInterval(row.startTs))
                                .formatted(date: .abbreviated, time: .shortened),
                            symbol: "figure.run")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task(id: repo.refreshSeq) {
            workouts = await repo.workoutRows(days: 90)
        }
    }
}

struct AuraWorkoutSessionDetail: View {
    @EnvironmentObject private var repo: Repository
    let row: WorkoutRow
    @State private var buckets: [HRBucket] = []
    @State private var loaded = false

    private var points: [HRBucket] {
        buckets.filter { $0.bpm.isFinite && $0.bpm > 0 &&
            $0.ts >= row.startTs && $0.ts <= row.endTs }
    }

    var body: some View {
        ZStack {
            NoopPalette.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(row.sport)
                        .font(NoopSpecType.screenTitle)
                        .foregroundStyle(NoopPalette.textPrimary)
                    NoopSpecCard(.hero) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(Date(timeIntervalSince1970: TimeInterval(row.startTs))
                                .formatted(date: .abbreviated, time: .shortened))
                                .font(NoopSpecType.cardTitle)
                                .foregroundStyle(NoopPalette.textPrimary)
                            Text(String(format: String(localized: "%.0f min", table: "AuraPreview"),
                                        (row.durationS ?? Double(row.endTs - row.startTs)) / 60))
                                .font(NoopSpecType.headline)
                                .foregroundStyle(NoopPalette.accent)
                            if let hr = row.avgHr {
                                Text(String(format: String(localized: "Avg HR: %d bpm", table: "AuraPreview"), hr))
                                    .font(NoopSpecType.body)
                                    .foregroundStyle(NoopPalette.textPrimary)
                            }
                            Text(String(localized: "Recorded source", table: "AuraPreview") + ": " + row.source)
                                .font(NoopSpecType.finePrint)
                                .foregroundStyle(NoopPalette.textSecondary)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    NoopSpecCard {
                        VStack(spacing: 11) {
                            workoutMetric("Effort", value: row.strain.map { String(format: "%.0f / 100", $0) })
                            workoutMetric("Max HR", value: row.maxHr.map { "\($0) bpm" })
                            workoutMetric("Active energy", value: row.energyKcal.map { String(format: "%.0f kcal", $0) })
                            workoutMetric("Distance", value: distanceText(row.distanceM))
                            workoutMetric("Steps", value: row.steps.map { String($0) })
                            if let notes = row.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                workoutMetric("Notes", value: notes)
                            }
                        }
                    }
                    NoopSpecCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(String(localized: "Heart-rate history", table: "AuraPreview"))
                                .font(NoopSpecType.cardTitle)
                                .foregroundStyle(NoopPalette.textPrimary)
                            if !loaded {
                                ProgressView().tint(NoopPalette.accent)
                            } else if points.isEmpty {
                                Text(String(localized: "No heart-rate samples for this workout", table: "AuraPreview"))
                                    .font(NoopSpecType.body)
                                    .foregroundStyle(NoopPalette.textSecondary)
                            } else {
                                Chart(points, id: \.ts) { bucket in
                                    BarMark(
                                        x: .value("Time", Date(timeIntervalSince1970: TimeInterval(bucket.ts))),
                                        y: .value("BPM", bucket.bpm)
                                    )
                                    .foregroundStyle(NoopPalette.accent)
                                }
                                .frame(height: 185)
                                .accessibilityLabel(Text(String(localized: "Recorded heart-rate buckets", table: "AuraPreview")))
                            }
                            Text(String(localized: "Only stored buckets are shown; missing samples are not filled.", table: "AuraPreview"))
                                .font(NoopSpecType.finePrint)
                                .foregroundStyle(NoopPalette.textSecondary)
                        }
                    }
                    NavigationLink {
                        WorkoutDetailView(row: row)
                    } label: {
                        AuraHistoryRow(
                            title: String(localized: "Open workout management", table: "AuraPreview"),
                            description: String(localized: "Recording, editing and full analysis remain in V2", table: "AuraPreview"),
                            symbol: "figure.run")
                    }
                    .buttonStyle(.plain)
                }
                .padding(18)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: row.startTs) {
            loaded = false
            buckets = await repo.workoutHrBuckets(
                from: row.startTs, to: row.endTs, source: row.source)
            loaded = true
        }
    }

    private func workoutMetric(_ title: LocalizedStringKey, value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(NoopSpecType.body)
                .foregroundStyle(NoopPalette.textSecondary)
            Spacer(minLength: 8)
            Text(value ?? "—")
                .font(NoopSpecType.rowFigure)
                .foregroundStyle(NoopPalette.textPrimary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func distanceText(_ metres: Double?) -> String? {
        guard let metres, metres.isFinite, metres >= 0 else { return nil }
        if metres < 1_000 { return String(format: "%.0f m", metres) }
        return String(format: "%.2f km", metres / 1_000)
    }
}

struct AuraHealthSummary: View {
    @EnvironmentObject private var repo: Repository

    private var readings: AuraTodayState {
        AuraTodayAdapter.map(repo.today,
            todayKey: Repository.logicalDayKey(Date()))
    }

    var body: some View {
        ZStack {
            NoopPalette.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(String(localized: "Health & Stress", table: "AuraPreview"))
                        .font(NoopSpecType.screenTitle)
                        .foregroundStyle(NoopPalette.textPrimary)
                    NoopSpecCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(String(localized: "Overnight HRV", table: "AuraPreview"))
                                .font(NoopSpecType.cardTitle)
                                .foregroundStyle(NoopPalette.textPrimary)
                            Text(readings.hrv.value.map { String(format: "%.1f ms", $0) } ?? "—")
                                .font(NoopSpecType.headline)
                                .foregroundStyle(NoopPalette.rest)
                            Text(String(localized: "Daily aggregate, not a live sample", table: "AuraPreview"))
                                .font(NoopSpecType.finePrint)
                                .foregroundStyle(NoopPalette.textSecondary)
                        }
                    }
                    NoopSpecCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(String(localized: "Resting HR", table: "AuraPreview"))
                                .font(NoopSpecType.cardTitle)
                                .foregroundStyle(NoopPalette.textPrimary)
                            Text(readings.restingHeartRate.value.map { String(format: "%.0f bpm", $0) } ?? "—")
                                .font(NoopSpecType.headline)
                                .foregroundStyle(NoopPalette.accent)
                            Text(String(localized: "Daily aggregate, not a live sample", table: "AuraPreview"))
                                .font(NoopSpecType.finePrint)
                                .foregroundStyle(NoopPalette.textSecondary)
                        }
                    }
                    NavigationLink {
                        HealthView()
                    } label: {
                        AuraHistoryRow(title: String(localized: "Full health monitor", table: "AuraPreview"),
                                       description: String(localized: "All V2 readings and sources", table: "AuraPreview"),
                                       symbol: "heart")
                    }
                    .buttonStyle(.plain)
                    NavigationLink {
                        StressView()
                    } label: {
                        AuraHistoryRow(title: String(localized: "Stress", table: "AuraPreview"),
                                       description: String(localized: "Open V2 stress analysis", table: "AuraPreview"),
                                       symbol: "waveform.path.ecg")
                    }
                    .buttonStyle(.plain)
                }
                .padding(18)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}
