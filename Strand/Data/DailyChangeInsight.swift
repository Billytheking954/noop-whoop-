import Foundation
import WhoopStore

/// A measured change against recent personal history. This is a display finding, not an input to
/// production scoring or a medical alert. It is recomputed from the current local rows after each sync,
/// so a late offload automatically revises or withdraws a finding.
struct DailyChangeInsight: Identifiable, Hashable {
    enum Metric: String, CaseIterable {
        case restingHr = "rhr"
        case hrv
        case sleep = "sleep"

        var title: String {
            switch self {
            case .restingHr: return "Resting heart rate"
            case .hrv: return "Overnight HRV"
            case .sleep: return "Sleep duration"
            }
        }
        var unit: String { self == .sleep ? "min" : self == .restingHr ? "bpm" : "ms" }
        var detailKey: String {
            switch self {
            case .restingHr: return "rhr"
            case .hrv: return "hrv"
            case .sleep: return "sleep"
            }
        }
        func value(_ row: DailyMetric) -> Double? {
            switch self {
            case .restingHr: return row.restingHr.map(Double.init)
            case .hrv: return row.avgHrv
            case .sleep: return row.totalSleepMin
            }
        }
        func plausible(_ value: Double) -> Bool {
            guard value.isFinite else { return false }
            switch self {
            case .restingHr: return (30...180).contains(value)
            case .hrv: return (5...250).contains(value)
            case .sleep: return (120...900).contains(value)
            }
        }
        func isMeaningful(value: Double, median: Double) -> Bool {
            let delta = abs(value - median)
            switch self {
            case .restingHr: return delta >= 5 && delta / median >= 0.08
            case .hrv: return delta >= 8 && delta / median >= 0.15
            case .sleep: return delta >= 60
            }
        }
    }

    let metric: Metric
    let day: String
    let value: Double
    let median: Double
    let comparisonDays: Int
    let windowStart: String
    let windowEnd: String
    var id: String { "\(metric.rawValue):\(day)" }
    var increased: Bool { value > median }

    /// Seven usable earlier days within a 30-calendar-day lookback. This protects cold starts and
    /// sparse imports from spurious comparisons. The median is resistant to one unusual prior day.
    static func derive(from rows: [DailyMetric], now: Date = Date()) -> [Self] {
        let ordered = rows.sorted { $0.day < $1.day }
        let today = localDayString(now)
        let visible = Array(ordered.suffix(35))
        var result: [Self] = []
        for row in visible where row.day <= today {
            guard let date = date(row.day),
                  let windowDate = utcCalendar.date(byAdding: .day, value: -30, to: date)
            else { continue }
            let floor = dayString(windowDate)
            let history = ordered.filter { $0.day >= floor && $0.day < row.day }
            for metric in Metric.allCases {
                guard let value = metric.value(row), metric.plausible(value) else { continue }
                let prior = history.compactMap { previous -> (String, Double)? in
                    guard let v = metric.value(previous), metric.plausible(v) else { return nil }
                    return (previous.day, v)
                }.suffix(20)
                guard prior.count >= 7 else { continue }
                let sorted = prior.map { $0.1 }.sorted()
                let middle = sorted.count / 2
                let median = sorted.count.isMultiple(of: 2)
                    ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
                guard metric.isMeaningful(value: value, median: median),
                      let first = prior.first?.0, let last = prior.last?.0 else { continue }
                result.append(Self(metric: metric, day: row.day, value: value, median: median,
                                   comparisonDays: prior.count, windowStart: first, windowEnd: last))
            }
        }
        return result.sorted { $0.day == $1.day ? $0.metric.rawValue < $1.metric.rawValue : $0.day > $1.day }
    }

    private static func date(_ key: String) -> Date? { formatter.date(from: key) }
    private static func dayString(_ date: Date) -> String { formatter.string(from: date) }
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
    private static func localDayString(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
