import Foundation

/// Raw saved dashboard inputs from one committed SQLite read snapshot. Source
/// precedence and health calculations remain the repository's responsibility.
public struct DashboardSnapshot: Sendable {
    public let dailyByDevice: [String: [DailyMetric]]
    public let sleepByDevice: [String: [CachedSleepSession]]
    public let seriesByDevice: [String: [MetricPoint]]
}

extension WhoopStore {
    /// One GRDB read transaction and one actor hop for the dashboard. Separate
    /// per-table reads can straddle a sync commit and combine old daily scores
    /// with new sleep/series rows. This API cannot expose that partial snapshot.
    /// It reuses the existing indexed queries and decoders, without schema writes.
    public func dashboardSnapshot(dailyDeviceIds: [String], sleepDeviceIds: [String],
                                  seriesDeviceIds: [String], fromDay: String, toDay: String,
                                  fromTs: Int, toTs: Int, sleepLimit: Int = 4000) async throws -> DashboardSnapshot {
        try syncRead { db in
            var daily: [String: [DailyMetric]] = [:]
            for id in Set(dailyDeviceIds) {
                daily[id] = try Self.readDailyMetrics(deviceId: id, from: fromDay, to: toDay, in: db)
            }
            var sleep: [String: [CachedSleepSession]] = [:]
            for id in Set(sleepDeviceIds) {
                sleep[id] = try Self.readSleepSessions(deviceId: id, from: fromTs, to: toTs,
                                                      limit: sleepLimit, in: db)
            }
            var series: [String: [MetricPoint]] = [:]
            for id in Set(seriesDeviceIds) {
                var points: [MetricPoint] = []
                for key in ["sleep_performance", "sleep_consistency", "sleep_need_min", "sleep_debt_min"] {
                    points += try Self.readMetricSeries(deviceId: id, key: key, from: fromDay, to: toDay, in: db)
                }
                series[id] = points
            }
            return DashboardSnapshot(dailyByDevice: daily, sleepByDevice: sleep, seriesByDevice: series)
        }
    }
}
