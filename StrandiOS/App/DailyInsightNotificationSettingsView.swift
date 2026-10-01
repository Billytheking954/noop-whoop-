#if os(iOS)
import SwiftUI
import StrandDesign
import UserNotifications

struct DailyInsightNotificationSettingsView: View {
    @EnvironmentObject private var repo: Repository
    @AppStorage(DailyInsightNotificationScheduler.enabledKey) private var enabled = false
    @AppStorage(DailyInsightNotificationScheduler.rhrKey) private var rhr = true
    @AppStorage(DailyInsightNotificationScheduler.hrvKey) private var hrv = true
    @AppStorage(DailyInsightNotificationScheduler.sleepKey) private var sleep = true
    @AppStorage(DailyInsightNotificationScheduler.startHourKey) private var startHour = 22
    @AppStorage(DailyInsightNotificationScheduler.endHourKey) private var endHour = 8
    @State private var denied = false

    var body: some View {
        ScreenScaffold(title: "Insight notifications", subtitle: "Optional local alerts after reliable data is saved") {
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    Toggle("Measured changes", isOn: $enabled)
                    Text("At most one alert per day. A new sync can update or withdraw a finding. Alerts are checked while NOOP is running; iOS may delay background work.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                    if denied {
                        Text("Notifications are disabled in iPhone Settings. Allow NOOP notifications there to use these alerts.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.statusWarning)
                    }
                }
            }
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    Toggle("Resting heart rate", isOn: $rhr)
                    Toggle("Overnight HRV", isOn: $hrv)
                    Toggle("Sleep duration", isOn: $sleep)
                }
                .disabled(!enabled)
            }
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    Text("Quiet hours").font(StrandFont.headline)
                    Picker("From", selection: $startHour) {
                        ForEach(0..<24) { hour in Text(verbatim: String(format: "%02d:00", hour)).tag(hour) }
                    }
                    Picker("Until", selection: $endHour) {
                        ForEach(0..<24) { hour in Text(verbatim: String(format: "%02d:00", hour)).tag(hour) }
                    }
                    Text("The hours follow your iPhone's current time zone.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .disabled(!enabled)
            }
        }
        .onChange(of: enabled) { _, isEnabled in
            if isEnabled {
                Task {
                    do {
                        let granted = try await UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert, .sound, .badge])
                        denied = !granted
                        if !granted { enabled = false }
                        else { await DailyInsightNotificationScheduler.reconcile(rows: repo.days) }
                    } catch {
                        denied = true
                        enabled = false
                    }
                }
            } else {
                DailyInsightNotificationScheduler.disable()
            }
        }
        .onChange(of: rhr) { _, _ in refresh() }
        .onChange(of: hrv) { _, _ in refresh() }
        .onChange(of: sleep) { _, _ in refresh() }
        .onChange(of: startHour) { _, _ in refresh() }
        .onChange(of: endHour) { _, _ in refresh() }
    }
    private func refresh() {
        Task { await DailyInsightNotificationScheduler.reconcile(rows: repo.days) }
    }
}
#endif
