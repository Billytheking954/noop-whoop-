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

    private func valueCard(_ title: String, value: Double, footnote: String) -> some View {
        ReferenceCard {
            VStack(alignment: .leading, spacing: ReferenceStyle.gap) {
                Text(title).font(ReferenceStyle.caption).foregroundStyle(StrandPalette.textSecondary)
                Text("\(Int(value.rounded())) \(insight.metric.unit)")
                    .font(ReferenceStyle.value).monospacedDigit()
                Text(footnote).font(ReferenceStyle.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ReferenceStyle.gap) {
                ReferenceCard {
                    HStack(alignment: .top, spacing: ReferenceStyle.padding) {
                        Image(systemName: insight.increased ? "arrow.up.right" : "arrow.down.right")
                            .foregroundStyle(ReferenceStyle.blue)
                        VStack(alignment: .leading, spacing: ReferenceStyle.gap) {
                            Text(insight.increased ? "Above your baseline" : "Below your baseline")
                                .font(ReferenceStyle.headline)
                            Text("\(Int(abs(insight.value - insight.median).rounded())) \(insight.metric.unit) \(insight.increased ? "higher" : "lower") than your recent personal median.")
                                .font(ReferenceStyle.body).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
                HStack(alignment: .top, spacing: ReferenceStyle.gap) {
                    valueCard("Measured day", value: insight.value, footnote: insight.day)
                    valueCard("Personal median", value: insight.median,
                              footnote: "\(insight.comparisonDays) earlier days")
                }
                ReferenceCard {
                    VStack(alignment: .leading, spacing: ReferenceStyle.padding) {
                        HStack {
                            Text("Last 30 days").font(ReferenceStyle.headline)
                            Spacer()
                            Text(insight.metric.unit).font(ReferenceStyle.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        let points = history
                        if points.isEmpty {
                            Text("No readings recorded.").font(ReferenceStyle.body)
                        } else {
                            historyChart(points)
                                .frame(height: 125)
                                .chartYAxisLabel(insight.metric.unit)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Text("\(insight.metric.title), last 30 days"))
                                .accessibilityValue(Text("\(points.count) observed days; baseline \(Int(insight.median.rounded())) \(insight.metric.unit). Gaps indicate missing readings."))
                        }
                        Text("Dashed line: personal median · gaps: no reading")
                            .font(ReferenceStyle.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                VStack(alignment: .leading, spacing: ReferenceStyle.gap) {
                    Text("What this means").font(ReferenceStyle.headline)
                    Text("Compared with \(insight.comparisonDays) saved days from \(insight.windowStart) to \(insight.windowEnd). Daily readings vary with sleep, activity and measurement conditions. This finding describes a change, not its cause or a diagnosis.")
                        .font(ReferenceStyle.body).foregroundStyle(StrandPalette.textSecondary)
                }
                ReferenceCard {
                    VStack(alignment: .leading, spacing: ReferenceStyle.padding) {
                        Label("Source: local daily record", systemImage: "externaldrive")
                            .font(ReferenceStyle.body)
                        Divider()
                        Text("Reading date: \(insight.day)").font(ReferenceStyle.body)
                        Text("Sync details are available under Device.")
                            .font(ReferenceStyle.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                NavigationLink(value: insight.metric == .sleep ? TabRoute.sleep : TabRoute.metric(insight.metric.detailKey)) {
                    ReferenceCard {
                        HStack {
                            Label("View trend", systemImage: "chart.xyaxis.line")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }.font(ReferenceStyle.headline)
                    }
                }.buttonStyle(.plain)
            }
            .padding(ReferenceStyle.page)
        }
        .background(ReferenceStyle.canvas.ignoresSafeArea())
        .navigationTitle(insight.metric.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
