import Foundation

/// Pure notification decision. Stored daily findings never become a production score input.
struct DailyInsightNotificationPolicy {
    static let enabledKey = "noop.insights.notifications.enabled"
    static let rhrKey = "noop.insights.notifications.rhr"
    static let hrvKey = "noop.insights.notifications.hrv"
    static let sleepKey = "noop.insights.notifications.sleep"
    static let startHourKey = "noop.insights.notifications.quietStartHour"
    static let endHourKey = "noop.insights.notifications.quietEndHour"
    static let lastDayKey = "noop.insights.notifications.lastDay"

    let enabled: Bool
    let metrics: Set<DailyChangeInsight.Metric>
    let quietStart: Int      // local minutes since midnight
    let quietEnd: Int
    let lastNotifiedDay: String?

    static func load(from defaults: UserDefaults) -> Self {
        func allowed(_ key: String) -> Bool {
            defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
        }
        let metrics = Set(DailyChangeInsight.Metric.allCases.filter { metric in
            switch metric {
            case .restingHr: return allowed(rhrKey)
            case .hrv: return allowed(hrvKey)
            case .sleep: return allowed(sleepKey)
            }
        })
        let start = defaults.object(forKey: startHourKey) == nil ? 22 : defaults.integer(forKey: startHourKey)
        let end = defaults.object(forKey: endHourKey) == nil ? 8 : defaults.integer(forKey: endHourKey)
        return .init(enabled: defaults.bool(forKey: enabledKey), metrics: metrics,
                     quietStart: min(23, max(0, start)) * 60,
                     quietEnd: min(23, max(0, end)) * 60,
                     lastNotifiedDay: defaults.string(forKey: lastDayKey))
    }

    func isQuiet(at date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        guard quietStart != quietEnd else { return false }
        if quietStart < quietEnd { return minute >= quietStart && minute < quietEnd }
        return minute >= quietStart || minute < quietEnd
    }

    /// One notification per local day, never for an old import or a day lacking a personal baseline.
    func eligible(_ insights: [DailyChangeInsight], now: Date,
                  calendar: Calendar = .current) -> DailyChangeInsight? {
        guard enabled, !isQuiet(at: now, calendar: calendar) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        guard let year = parts.year, let month = parts.month, let date = parts.day else { return nil }
        let day = String(format: "%04d-%02d-%02d", year, month, date)
        guard lastNotifiedDay != day else { return nil }
        return insights.first { $0.day == day && metrics.contains($0.metric) }
    }
}
