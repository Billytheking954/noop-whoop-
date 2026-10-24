import SwiftUI
import StrandDesign

/// Phase 2 Aura Today presentation. The existing repository remains authoritative.
/// No Bluetooth commands, scoring, history queries or new persistence live in this view.
struct AuraTodayView: View {
    @EnvironmentObject private var repo: Repository
    let onShowClassic: () -> Void

    private var todayKey: String { Repository.localDayKey(Date()) }
    private var today: AuraTodayState {
        // Repository.days is a cross-source merged read model. A per-value source cannot safely be
        // recovered from it: leave sourceID absent instead of claiming the connected strap produced it.
        AuraTodayAdapter.map(repo.today, todayKey: todayKey)
    }
    private var rest: AuraRestState {
        AuraRestAdapter.map(repo.today, todayKey: todayKey)
    }
    private var fitness: AuraFitnessState {
        AuraFitnessAdapter.map(repo.today, todayKey: todayKey)
    }

    var body: some View {
        ZStack {
            NoopPalette.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 6) {
                            NoopSpecCaption("Today")
                            Text("Your day")
                                .font(NoopSpecType.screenTitle)
                                .foregroundStyle(NoopPalette.textPrimary)
                        }
                        Spacer(minLength: 12)
                        Button(action: onShowClassic) {
                            Text("Full V2 dashboard")
                                .font(NoopSpecType.buttonLabel)
                                .foregroundStyle(NoopSpecTokens.auraPale)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .background(Capsule().fill(NoopPalette.controlFill))
                        }
                        .accessibilityHint("Open all NOOP V2 tracking and settings controls")
                    }

                    NoopSpecCard(.hero) {
                        VStack(alignment: .leading, spacing: 12) {
                            NoopSpecCaption("Morning Charge")
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(number(today.charge, digits: 0))
                                    .font(NoopSpecType.heroNumeral)
                                    .foregroundStyle(NoopSpecTokens.auraPale)
                                    .minimumScaleFactor(0.7)
                                if today.charge.value != nil {
                                    Text("%")
                                        .font(NoopSpecType.sectionHead)
                                        .foregroundStyle(NoopPalette.textSecondary)
                                }
                            }
                            Text("NOOP Charge estimate from the recorded day, not a live energy level.")
                                .font(NoopSpecType.body)
                                .foregroundStyle(NoopSpecTokens.textBody)
                                .fixedSize(horizontal: false, vertical: true)
                            sourceCaption(today.charge)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    HStack(alignment: .top, spacing: 12) {
                        metricCard(title: "Resting HR", reading: today.restingHeartRate, tint: NoopPalette.accent)
                        metricCard(title: "Overnight HRV", reading: today.hrv, tint: NoopPalette.rest)
                    }

                    NoopSpecCard {
                        VStack(alignment: .leading, spacing: 14) {
                            NoopSpecCaption("Rest")
                            HStack {
                                Text(number(rest.sleepMinutes, digits: 0))
                                    .font(NoopSpecType.headline)
                                    .foregroundStyle(NoopPalette.textPrimary)
                                Text("min asleep")
                                    .font(NoopSpecType.body)
                                    .foregroundStyle(NoopPalette.textSecondary)
                                Spacer()
                                Text(percent(rest.sleepEfficiency))
                                    .font(NoopSpecType.rowFigure)
                                    .foregroundStyle(NoopPalette.rest)
                            }
                            Text("Sleep stages are estimates. Original sleep records and editing stay in the V2 dashboard.")
                                .font(NoopSpecType.bodySmall)
                                .foregroundStyle(NoopPalette.textSecondary)
                            sourceCaption(rest.sleepMinutes)
                        }
                    }

                    NoopSpecCard {
                        VStack(alignment: .leading, spacing: 12) {
                            NoopSpecCaption("NOOP Effort")
                            Text(number(fitness.effort, digits: 0) + (fitness.effort.value == nil ? "" : " / 100"))
                                .font(NoopSpecType.headline)
                                .foregroundStyle(NoopPalette.effort)
                            Text("Calculated by V2 from recorded activity. No missing samples are filled in.")
                                .font(NoopSpecType.bodySmall)
                                .foregroundStyle(NoopPalette.textSecondary)
                            sourceCaption(fitness.effort)
                        }
                    }

                    Text("This Aura preview uses V2's day-level summary. Sensor sample times and per-field provenance are not exposed by this summary, so neither is invented here.")
                        .font(NoopSpecType.finePrint)
                        .foregroundStyle(NoopPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
            .refreshable { await repo.refresh() }
        }
        .preferredColorScheme(.dark)
    }

    private func metricCard(title: String, reading: AuraDailyReading, tint: Color) -> some View {
        NoopSpecCard {
            VStack(alignment: .leading, spacing: 8) {
                NoopSpecCaption(title)
                Text(number(reading, digits: reading.unit == "ms" ? 1 : 0))
                    .font(NoopSpecType.headline)
                    .foregroundStyle(tint)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(reading.unit)
                    .font(NoopSpecType.subline)
                    .foregroundStyle(NoopPalette.textSecondary)
                sourceCaption(reading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sourceCaption(_ reading: AuraDailyReading) -> some View {
        Text(reading.day.map { "\($0) · \(reading.state == .stale ? "Older reading" : "Daily aggregate")" }
             ?? "No measured data")
            .font(NoopSpecType.finePrint)
            .foregroundStyle(NoopPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func number(_ reading: AuraDailyReading, digits: Int) -> String {
        guard let value = reading.value else { return "—" }
        return String(format: "%.*f", digits, value)
    }

    private func percent(_ reading: AuraDailyReading) -> String {
        guard let value = reading.value else { return "—" }
        return String(format: "%.0f%%", value)
    }
}
