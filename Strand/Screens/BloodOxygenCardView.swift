import SwiftUI
import Charts
import StrandDesign

struct BloodOxygenTrendPoint: Identifiable, Equatable, Sendable {
    let date: Date
    let percent: Double
    var id: Date { date }
}

/// Display-only view for a validated nightly aggregate. The biomedical decoding and gating stay in
/// WhoopProtocol/StrandAnalytics so the UI cannot manufacture a value from incomplete raw evidence.
struct BloodOxygenCardView: View {
    let percent: Double?
    let coverageFraction: Double?
    let trend: [BloodOxygenTrendPoint]
    var isExperimental = true

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Blood Oxygen").font(.headline)
                        if isExperimental {
                            Text("Experimental WHOOP 5 telemetry")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    coverageCapsule
                }

                if let percent {
                    Text(percent, format: .number.precision(.fractionLength(1)))
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        + Text("%")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Unavailable")
                        .font(.title2.weight(.semibold))
                    Text("Not enough validated Slow-Wave Sleep telemetry")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if trend.isEmpty {
                    Text("No validated 7-day history")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Chart(Array(trend.sorted { $0.date < $1.date }.suffix(7))) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("SpO2", point.percent)
                        )
                        PointMark(
                            x: .value("Date", point.date),
                            y: .value("SpO2", point.percent)
                        )
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading)
                    }
                    .frame(height: 120)
                    .accessibilityLabel("Seven day blood oxygen trend")
                }
            }
        }
    }

    @ViewBuilder
    private var coverageCapsule: some View {
        if let coverageFraction {
            Text(coverageFraction, format: .percent.precision(.fractionLength(0)))
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
                .accessibilityLabel("Telemetry coverage")
        } else {
            Text("No coverage")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
        }
    }
}
