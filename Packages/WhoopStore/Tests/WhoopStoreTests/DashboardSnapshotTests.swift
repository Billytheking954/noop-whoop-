import GRDB
import XCTest
@testable import WhoopStore

final class DashboardSnapshotTests: XCTestCase {
    private func daily(recovery: Double) -> DailyMetric {
        DailyMetric(day: "2026-10-25", totalSleepMin: nil, efficiency: nil, deepMin: nil,
                    remMin: nil, lightMin: nil, disturbances: nil, restingHr: 52,
                    avgHrv: nil, recovery: recovery, strain: 0, exerciseCount: 0)
    }

    private func read(_ store: WhoopStore) async throws -> DashboardSnapshot {
        try await store.dashboardSnapshot(dailyDeviceIds: ["a", "a", "empty"],
                                           sleepDeviceIds: ["a"], seriesDeviceIds: ["a"],
                                           fromDay: "2026-10-24", toDay: "2026-10-26",
                                           fromTs: 0, toTs: 10_000)
    }

    func testSnapshotUsesExistingDecodersAndPreservesMissingVersusZero() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertDailyMetrics([daily(recovery: 75)], deviceId: "a")
        let sleep = CachedSleepSession(startTs: 1_000, endTs: 5_000, efficiency: 0.9,
                                       restingHr: 52, avgHrv: nil, stagesJSON: nil,
                                       userEdited: true, startTsAdjusted: 1_010, stagingSparse: true)
        _ = try await store.upsertSleepSessions([sleep], deviceId: "a")
        let point = MetricPoint(day: "2026-10-25", key: "sleep_performance", value: 75)
        _ = try await store.upsertMetricSeries([point], deviceId: "a")
        let snapshot = try await read(store)
        let dailyRows = try await store.dailyMetrics(deviceId: "a", from: "2026-10-24", to: "2026-10-26")
        let sleeps = try await store.sleepSessions(deviceId: "a", from: 0, to: 10_000, limit: 4000)
        XCTAssertEqual(snapshot.dailyByDevice["a"], dailyRows)
        XCTAssertEqual(snapshot.sleepByDevice["a"], sleeps)
        XCTAssertEqual(snapshot.seriesByDevice["a"], [point])
        XCTAssertEqual(snapshot.dailyByDevice["empty"], [])
        XCTAssertNil(snapshot.dailyByDevice["a"]?.first?.avgHrv)
        XCTAssertEqual(snapshot.dailyByDevice["a"]?.first?.strain, 0)
        XCTAssertEqual(snapshot.sleepByDevice["a"]?.first?.startTsAdjusted, 1_010)
    }

    func testSnapshotNeverMixesDailyAndSeriesFromDifferentCommits() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertDailyMetrics([daily(recovery: 1)], deviceId: "a")
        _ = try await store.upsertMetricSeries([
            MetricPoint(day: "2026-10-25", key: "sleep_performance", value: 1)
        ], deviceId: "a")
        let writer = store.registryWriter
        let writes = Task.detached {
            for revision in 2...100 {
                try await writer.write { db in
                    try db.execute(sql: "UPDATE dailyMetric SET recovery = ? WHERE deviceId = 'a'",
                                   arguments: [revision])
                    try db.execute(sql: "UPDATE metricSeries SET value = ? WHERE deviceId = 'a'",
                                   arguments: [revision])
                }
            }
        }
        for _ in 0..<100 {
            let snapshot = try await read(store)
            XCTAssertEqual(snapshot.dailyByDevice["a"]?.first?.recovery,
                           snapshot.seriesByDevice["a"]?.first?.value)
        }
        try await writes.value
    }
}
