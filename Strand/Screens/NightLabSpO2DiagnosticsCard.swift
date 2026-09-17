import SwiftUI
import StrandAnalytics
import StrandDesign

struct NightLabSpO2DiagnosticsCard: View {
    let inspection: NightLabInspection

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "Experimental summary-frame hypothesis").font(.headline)
                Text(verbatim: "Unverified format and scaling. Synthetic fixtures do not establish a WHOOP SpO₂ measurement. This is separate from historical byte 82.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = inspection.spO2DiagnosticsError {
                    Text("SpO₂ diagnostics failed: \(error)").foregroundStyle(.red)
                } else if let diagnostic = inspection.spO2Diagnostics {
                    field("Archived frames", String(diagnostic.archivedFrameCount))
                    field("Decoded frames", String(diagnostic.decodedFrameCount))
                    field("Decode failures", String(diagnostic.decodeFailureCount))
                    field("CRC failures", String(diagnostic.crcFailureCount))
                    field("Quality/motion rejected", String(diagnostic.qualityRejectedCount))
                    field("Low-quality frames", String(diagnostic.lowQualityCount))
                    field("High-motion frames", String(diagnostic.highMotionCount))
                    field("Expected 5-minute frames", String(diagnostic.expectedNightlyFrameCount))
                    field("Whole-night frame coverage", String(format: "%.1f%%", diagnostic.frameCoverageFraction * 100))
                    field("Fully-SWS frames", String(diagnostic.slowWaveFrameCount))
                    field("Valid fully-SWS frames", String(diagnostic.validSlowWaveFrameCount))

                    if let aggregate = diagnostic.aggregate {
                        field("Experimental aggregate", String(format: "%.2f%%", aggregate.spo2Percent))
                        field("SWS quality coverage", String(format: "%.1f%%", aggregate.coverageFraction * 100))
                        field("Trimmed per tail", String(aggregate.trimCountPerTail))
                    } else if let aggregationError = diagnostic.aggregationError {
                        field("Experimental aggregate", "Unavailable")
                        Text(aggregationError).font(.caption).foregroundStyle(.secondary)
                    }

                    DisclosureGroup("Epoch-by-epoch decoded distribution") {
                        ForEach(Array(diagnostic.epochs.enumerated()), id: \.offset) { _, epoch in
                            VStack(alignment: .leading, spacing: 2) {
                                if let timestamp = epoch.timestampUnix {
                                    field("Timestamp", String(timestamp))
                                }
                                if let percent = epoch.spo2Percent {
                                    field("Candidate value", String(format: "%.2f%%", percent))
                                }
                                if let quality = epoch.qualityScore {
                                    field("Quality", String(quality))
                                }
                                if let motion = epoch.motionVarianceG {
                                    field("Motion variance", String(format: "%.3f g", motion))
                                }
                                field("Fully SWS", epoch.isSlowWaveSleep ? "Yes" : "No")
                                field("Quality gate", epoch.acceptedByQualityGate ? "Accepted" : "Rejected")
                                if let decodeError = epoch.decodeError {
                                    Text(decodeError).foregroundStyle(.red)
                                }
                            }
                            Divider()
                        }
                    }
                } else {
                    Text("No whoop5-spo2-summary raw asset is archived for this night.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func field(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
