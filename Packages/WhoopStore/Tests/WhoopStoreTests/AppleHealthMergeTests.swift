import XCTest
import GRDB
@testable import WhoopStore

final class AppleHealthMergeTests: XCTestCase {
    func testNilHealthFieldsPreserveLastGoodValuesWhileVisibleFieldsUpdate() async throws {
        let store = try await WhoopStore.inMemory()
        let db = store.registryWriter

        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO appleDaily
                    (deviceId, day, steps, activeKcal, basalKcal, vo2max, avgHr, maxHr, walkingHr, weightKg)
                VALUES ('apple-health','2026-10-06',1000,250,1500,48,70,150,80,67)
                """)
            try db.execute(sql: """
                INSERT INTO dailyMetric
                    (deviceId, day, totalSleepMin, deepMin, remMin, lightMin, restingHr, avgHrv,
                     recovery, spo2Pct, respRateBpm, avgSdnn)
                VALUES ('apple-health','2026-10-06',420,80,90,250,55,62,77,98,14,62)
                """)
            try db.execute(sql: """
                INSERT INTO metricSeries (deviceId, day, key, value)
                VALUES ('apple-health','2026-10-06','weight',67)
                """)
        }

        let apple = AppleDaily(day: "2026-10-06",
                               steps: 1200,
                               activeKcal: nil,
                               basalKcal: nil,
                               vo2max: nil,
                               avgHr: nil,
                               maxHr: nil,
                               walkingHr: nil,
                               weightKg: nil)
        let daily = DailyMetric(day: "2026-10-06",
                                totalSleepMin: nil, efficiency: nil,
                                deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                                restingHr: nil, avgHrv: 65,
                                recovery: nil, strain: nil, exerciseCount: nil,
                                spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil,
                                steps: nil, activeKcalEst: nil,
                                spo2Red: nil, spo2Ir: nil, avgSdnn: 65,
                                skinTempC: nil, sleepHrOnly: nil)

        _ = try await store.mergeAppleHealthReadRows(
            appleDailyRows: [apple],
            dailyMetricRows: [daily],
            metricPoints: [MetricPoint(day: "2026-10-06", key: "hrv", value: 65)],
            deviceId: "apple-health")

        try await db.read { db in
            let a = try Row.fetchOne(db, sql: """
                SELECT steps, activeKcal, vo2max, weightKg
                FROM appleDaily WHERE deviceId='apple-health' AND day='2026-10-06'
                """)!
            XCTAssertEqual(a["steps"] as Int?, 1200)
            XCTAssertEqual(a["activeKcal"] as Double?, 250)
            XCTAssertEqual(a["vo2max"] as Double?, 48)
            XCTAssertEqual(a["weightKg"] as Double?, 67)

            let d = try Row.fetchOne(db, sql: """
                SELECT totalSleepMin, restingHr, avgHrv, recovery, spo2Pct, respRateBpm
                FROM dailyMetric WHERE deviceId='apple-health' AND day='2026-10-06'
                """)!
            XCTAssertEqual(d["totalSleepMin"] as Double?, 420)
            XCTAssertEqual(d["restingHr"] as Int?, 55)
            XCTAssertEqual(d["avgHrv"] as Double?, 65)
            XCTAssertEqual(d["recovery"] as Double?, 77)
            XCTAssertEqual(d["spo2Pct"] as Double?, 98)
            XCTAssertEqual(d["respRateBpm"] as Double?, 14)

            XCTAssertEqual(try Double.fetchOne(db, sql: """
                SELECT value FROM metricSeries
                WHERE deviceId='apple-health' AND day='2026-10-06' AND key='weight'
                """), 67)
            XCTAssertEqual(try Double.fetchOne(db, sql: """
                SELECT value FROM metricSeries
                WHERE deviceId='apple-health' AND day='2026-10-06' AND key='hrv'
                """), 65)
        }
    }

    func testNewDayStillInsertsSparseVisibleHealthValues() async throws {
        let store = try await WhoopStore.inMemory()
        let apple = AppleDaily(day: "2026-10-07", steps: 4321, activeKcal: nil, basalKcal: nil,
                               vo2max: nil, avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: nil)
        let daily = DailyMetric(day: "2026-10-07", totalSleepMin: nil, efficiency: nil,
                                deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                                restingHr: 58, avgHrv: nil, recovery: nil, strain: nil,
                                exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil,
                                respRateBpm: nil, steps: nil, activeKcalEst: nil,
                                spo2Red: nil, spo2Ir: nil, avgSdnn: nil,
                                skinTempC: nil, sleepHrOnly: nil)

        _ = try await store.mergeAppleHealthReadRows(
            appleDailyRows: [apple], dailyMetricRows: [daily], metricPoints: [],
            deviceId: "apple-health")

        let rows = try await store.appleDaily(deviceId: "apple-health",
                                              from: "2026-10-07", to: "2026-10-07")
        XCTAssertEqual(rows.first?.steps, 4321)
        let dailyRows = try await store.dailyMetrics(deviceId: "apple-health",
                                                     from: "2026-10-07", to: "2026-10-07")
        XCTAssertEqual(dailyRows.first?.restingHr, 58)
    }
}
