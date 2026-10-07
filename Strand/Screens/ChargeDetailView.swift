import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Charge presents the saved recovery metric. Display comparisons never feed production scoring.
struct ChargeDetailView: View {
    var day: String? = nil
    @EnvironmentObject private var repo: Repository
    @State private var showComparison = false
    private var row: DailyMetric? {
        if let day { return repo.days.first { $0.day == day } }
        return repo.days.sorted { $0.day < $1.day }.last
    }
    private func rest(_ row: DailyMetric) -> Double? {
        repo.importedSleep[row.day]?.performancePct ?? AnalyticsEngine.Rest.composite(daily: row)
    }
    private func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard sorted.count >= 7 else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
    private var baselineRows: [DailyMetric] {
        guard let row else { return [] }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: row.day),
              let start = Calendar.current.date(byAdding: .day, value: -30, to: date) else { return [] }
        let floor = parser.string(from: start)
        return repo.days.filter { $0.day >= floor && $0.day < row.day }
    }
    var body: some View {
        ScrollView {
            VStack(spacing: ReferenceStyle.section) {
                ReferenceRing(progress: row?.recovery.map { $0 / 100 }, color: ReferenceStyle.green,
                              value: row?.recovery.map { "\(Int($0.rounded()))%" } ?? "—", label: "Charge", valueSize: 64)
                    .frame(width: ReferenceStyle.chartHeight * 1.4, height: ReferenceStyle.chartHeight * 1.4)
                if let row {
                    Text(row.day).font(ReferenceStyle.caption).foregroundStyle(StrandPalette.textSecondary)
                    ReferenceCard {
                        VStack(spacing: ReferenceStyle.padding) {
                            metric("Heart rate variability", icon: "waveform.path.ecg", value: row.avgHrv,
                                   baseline: median(baselineRows.compactMap(\.avgHrv)), unit: "ms")
                            Divider()
                            metric("Resting heart rate", icon: "heart", value: row.restingHr.map(Double.init),
                                   baseline: median(baselineRows.compactMap { $0.restingHr.map(Double.init) }), unit: "bpm")
                            Divider()
                            metric("Respiratory rate", icon: "lungs", value: row.respRateBpm,
                                   baseline: median(baselineRows.compactMap(\.respRateBpm)), unit: "rpm")
                            Divider()
                            metric("Sleep performance", icon: "moon", value: rest(row),
                                   baseline: median(baselineRows.compactMap { rest($0) }), unit: "%")
                        }
                    }
                    DisclosureGroup(isExpanded: $showComparison) {
                        VStack(alignment: .leading, spacing: ReferenceStyle.padding) {
                            Text("Baseline: median of eligible saved readings in the preceding 30 days. At least seven readings are required.")
                                .font(ReferenceStyle.body).foregroundStyle(StrandPalette.textSecondary)
                            if let baselines = repo.chargeBaselines,
                               let breakdown = ChargeBreakdownWiring.breakdown(baselines: baselines, row: row, sleepPerfPercent: rest(row)) {
                                ChargeBreakdownSection(drivers: breakdown.drivers, confidence: breakdown.confidence)
                            } else {
                                Text("More comparable nights are needed for a scoring breakdown.")
                                    .font(ReferenceStyle.body)
                            }
                        }.padding(.top, ReferenceStyle.padding)
                    } label: {
                        Label("Today vs. 30-day baseline", systemImage: "chart.bar").font(ReferenceStyle.headline)
                    }
                    .padding(ReferenceStyle.padding)
                    .background(ReferenceStyle.surface, in: RoundedRectangle(cornerRadius: ReferenceStyle.radius))
                } else {
                    ReferenceCard {
                        Text(repo.loaded ? "No saved Charge for this day" : "Loading…").font(ReferenceStyle.body)
                    }
                }
            }.padding(ReferenceStyle.page)
        }
        .background(ReferenceStyle.canvas.ignoresSafeArea())
        .navigationTitle("Charge")
        .navigationBarTitleDisplayMode(.inline)
    }
    private func metric(_ title: String, icon: String, value: Double?, baseline: Double?, unit: String) -> some View {
        HStack(spacing: ReferenceStyle.padding) {
            Image(systemName: icon).font(ReferenceStyle.value).foregroundStyle(StrandPalette.textSecondary)
            Text(title).font(ReferenceStyle.caption)
            Spacer()
            VStack(alignment: .trailing, spacing: ReferenceStyle.gap) {
                Text(value.map { String(format: unit == "rpm" ? "%.1f %@" : "%.0f %@", $0, unit) } ?? "Unavailable")
                    .font(ReferenceStyle.value).monospacedDigit()
                Text(baseline.map { String(format: "%.1f %@", $0, unit) } ?? "No baseline")
                    .font(ReferenceStyle.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }.accessibilityElement(children: .combine)
    }
}
