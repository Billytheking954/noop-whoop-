import SwiftUI
import StrandDesign

/// The exact measured day and comparison behind a daily change. The source can be a strap or
/// an import after the repository merge; the metric detail owns the finer source attribution.
struct DailyChangeDetailView: View {
    let insight: DailyChangeInsight
    @Environment(\.dismiss) private var dismiss

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
