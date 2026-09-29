import Foundation

/// Pure notification decision. Stored daily findings never become a production score input.
struct DailyInsightNotificationPolicy {
    let enabled: Bool
    let metrics: Set<DailyChangeInsight.Metric>
    let quietStart: Int      // local minutes since midnight
    let quietEnd: Int
    let lastNotifiedDay: String?

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
