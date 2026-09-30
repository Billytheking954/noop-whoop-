import SwiftUI
import Charts
import StrandDesign

/// The exact measured day and comparison behind a daily change. The source can be a strap or
/// an import after the repository merge; the metric detail owns the finer source attribution.
struct DailyChangeDetailView: View {
    let insight: DailyChangeInsight
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var repo: Repository

    private var history: [DailyChangeInsight.HistoryPoint] {
        DailyChangeInsight.history(for: insight, rows: repo.days)
    }

    private func historyChart(_ points: [DailyChangeInsight.HistoryPoint]) -> some View {
        let selected = points.first { $0.id == insight.day }
        return Chart {
            RuleMark(y: .value("Personal median", insight.median))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            ForEach(points) { point in
                LineMark(x: .value("Day", point.date),
                         y: .value("Reading", point.value),
                         series: .value("Observed run", point.segment))
                    .foregroundStyle(StrandPalette.metricCyan)
            }
            if let selected {
                PointMark(x: .value("Day", selected.date),
                          y: .value("Reading", selected.value))
                    .foregroundStyle(StrandPalette.statusPositive)
                    .symbolSize(80)
            }
        }
    }

    var body: some View {
        ScreenScaffold(title: "Measured change", subtitle: LocalizedStringKey(insight.metric.title)) {
            NoopCard(tint: StrandPalette.metricCyan) {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    Text(insight.increased ? "Higher than your recent median" : "Lower than your recent median")
                        .font(StrandFont.headline)
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            Text("Measured day").strandOverline()
                            Text("\(Int(insight.value.rounded())) \(insight.metric.unit)")
                                .font(StrandFont.title1)
                            Text(insight.day).font(StrandFont.footnote)
                        }
                        Spacer(minLength: 0)
                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            Text("Personal median").strandOverline()
                            Text("\(Int(insight.median.rounded())) \(insight.metric.unit)")
                                .font(StrandFont.title1)
                            Text("\(insight.comparisonDays) earlier days")
                                .font(StrandFont.footnote)
                        }
                    }
                    Text("Compared with \(insight.windowStart) to \(insight.windowEnd). This describes a change in saved readings, not its cause.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text("Source: NOOP local daily record. Open the metric history for the underlying source and coverage.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            NoopCard(tint: StrandPalette.metricCyan) {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    Text("Last 30 days").font(StrandFont.headline)
                    let points = history
                    if points.isEmpty {
                        Text("No readings recorded.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    } else {
                        historyChart(points)
                            .frame(height: NoopMetrics.chartHeight)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text("Last 30 days"))
                            .accessibilityValue(Text("\(points.count) observed days"))
                        HStack(spacing: NoopMetrics.space4) {
                            Text("\(points.count) observed days")
                            Spacer(minLength: 0)
                            Text("Personal median")
                        }
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
            NavigationLink(value: insight.metric == .sleep ? TabRoute.sleep : TabRoute.metric(insight.metric.detailKey)) {
                NoopCard {
                    Label("View metric history", systemImage: "chart.xyaxis.line")
                        .font(StrandFont.headline)
                }
            }
            .buttonStyle(.plain)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
