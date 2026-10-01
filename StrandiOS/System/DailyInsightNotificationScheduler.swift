#if os(iOS)
import Foundation
import UserNotifications
import WhoopStore

/// Foreground/offload reconciliation only. iOS does not guarantee a background launch after a strap
/// offload, so notifications are offered when NOOP next runs with reliable saved data.
@MainActor
enum DailyInsightNotificationScheduler {
    static let category = "noop-daily-insight"
    private static let prefix = "noop-daily-insight-"
    static let enabledKey = DailyInsightNotificationPolicy.enabledKey
    static let rhrKey = DailyInsightNotificationPolicy.rhrKey
    static let hrvKey = DailyInsightNotificationPolicy.hrvKey
    static let sleepKey = DailyInsightNotificationPolicy.sleepKey
    static let startHourKey = DailyInsightNotificationPolicy.startHourKey
    static let endHourKey = DailyInsightNotificationPolicy.endHourKey
    private static let lastDayKey = DailyInsightNotificationPolicy.lastDayKey
    private static let fingerprintKey = "noop.insights.notifications.fingerprint"

    static func preferences(_ defaults: UserDefaults = .standard) -> DailyInsightNotificationPolicy {
        DailyInsightNotificationPolicy.load(from: defaults)
    }

    static func reconcile(rows: [DailyMetric], now: Date = Date(),
                          defaults: UserDefaults = .standard) async {
        let center = UNUserNotificationCenter.current()
        let findings = DailyChangeInsight.derive(from: rows, now: now)
        let policy = preferences(defaults)
        let currentDay = localDay(now)
        let current = findings.first { $0.day == currentDay && policy.metrics.contains($0.metric) }
        let currentFingerprint = current.map(fingerprint)
        let priorFingerprint = defaults.string(forKey: fingerprintKey)
        let priorDay = defaults.string(forKey: lastDayKey)

        // A new offload can revise or withdraw the finding after an alert was delivered. Remove the
        // old alert; the in-app history is derived anew and the one-per-day cap prevents a second ping.
        if !policy.enabled || (priorDay == currentDay && priorFingerprint != currentFingerprint) {
            let id = prefix + currentDay
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.removeDeliveredNotifications(withIdentifiers: [id])
        }
        guard let selected = policy.eligible(findings, now: now) else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = "Measured change in your history"
        content.body = "\(selected.metric.title): \(Int(selected.value.rounded())) \(selected.metric.unit), compared with your \(Int(selected.median.rounded())) \(selected.metric.unit) median."
        content.categoryIdentifier = category
        content.userInfo = ["insightID": selected.id]
        let request = UNNotificationRequest(identifier: prefix + currentDay, content: content, trigger: nil)
        do {
            try await center.add(request)
            defaults.set(currentDay, forKey: lastDayKey)
            defaults.set(fingerprint(selected), forKey: fingerprintKey)
        } catch {
            // No dedup state is written on failure, so the next foreground refresh can retry.
        }
    }

    static func disable() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            center.removePendingNotificationRequests(withIdentifiers:
                requests.map(\.identifier).filter { $0.hasPrefix(prefix) })
        }
        center.getDeliveredNotifications { notifications in
            center.removeDeliveredNotifications(withIdentifiers:
                notifications.map { $0.request.identifier }.filter { $0.hasPrefix(prefix) })
        }
    }

    private static func fingerprint(_ insight: DailyChangeInsight) -> String {
        "\(insight.id):\(insight.value):\(insight.median):\(insight.comparisonDays)"
    }
    private static func localDay(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
#endif
