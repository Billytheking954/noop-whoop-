import XCTest
import GRDB
@testable import WhoopStore

final class AppleHealthWindowReplaceTests: XCTestCase {
    func testEmptyAuthoritativeWindowRemovesOnlyAppleHealthRows() async throws {
        let store = try await WhoopStore.inMemory()
        let db = store.registryWriter

        try db.write { db in
            try db.execute(sql: "INSERT INTO appleDaily (deviceId, day, steps) VALUES ('apple-health','2026-10-06',111)")
            try db.execute(sql: "INSERT INTO appleDaily (deviceId, day, steps) VALUES ('my-whoop','2026-10-06',222)")
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day, restingHr) VALUES ('apple-health','2026-10-06',60)")
            try db.execute(sql: "INSERT INTO dailyMetric (deviceId, day, restingHr) VALUES ('my-whoop','2026-10-06',50)")
            try db.execute(sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES ('apple-health','2026-10-06','weight',70)")
            try db.execute(sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES ('my-whoop','2026-10-06','weight',80)")
            try db.execute(sql: """
                INSERT INTO workout (deviceId,startTs,endTs,sport,source)
                VALUES ('apple-health',100,200,'Running','apple-health')
                """)
            try db.execute(sql: """
                INSERT INTO workout (deviceId,startTs,endTs,sport,source)
                VALUES ('apple-health',110,210,'Walking','manual')
                """)
            try db.execute(sql: "INSERT INTO appleStepHour (deviceId,ts,steps) VALUES ('apple-health',120,10)")
            try db.execute(sql: "INSERT INTO appleStepHour (deviceId,ts,steps) VALUES ('my-whoop',120,20)")
        }

        let old = try await store.replaceAppleHealthWindow(
            appleDailyRows: [], dailyMetricRows: [], metricPoints: [], workoutRows: [],
            hourlyStepRows: [], deviceId: "apple-health",
            fromDay: "2026-10-01", toDay: "2026-10-07",
            fromTs: 0, toTs: 1_000, hourlyFromTs: 0,
            workoutSource: "apple-health")

        XCTAssertEqual(old.map { ($0.startTs, $0.sport) }.count, 1)
        XCTAssertEqual(old.first?.sport, "Running")

        try db.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM appleDaily WHERE deviceId='apple-health'") ?? -1, 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dailyMetric WHERE deviceId='apple-health'") ?? -1, 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM metricSeries WHERE deviceId='apple-health'") ?? -1, 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workout WHERE deviceId='apple-health' AND source='apple-health'") ?? -1, 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workout WHERE deviceId='apple-health' AND source='manual'") ?? -1, 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM appleStepHour WHERE deviceId='apple-health'") ?? -1, 0)

            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM appleDaily WHERE deviceId='my-whoop'") ?? -1, 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dailyMetric WHERE deviceId='my-whoop'") ?? -1, 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM metricSeries WHERE deviceId='my-whoop'") ?? -1, 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM appleStepHour WHERE deviceId='my-whoop'") ?? -1, 1)
        }
    }

    func testReplacementReinsertsCurrentSnapshotAndRemovesMissingKeys() async throws {
        let store = try await WhoopStore.inMemory()
        let db = store.registryWriter
        try db.write { db in
            try db.execute(sql: "INSERT INTO metricSeries (deviceId,day,key,value) VALUES ('apple-health','2026-10-06','stale_metric',1)")
            try db.execute(sql: "INSERT INTO appleStepHour (deviceId,ts,steps) VALUES ('apple-health',120,999)")
            try db.execute(sql: """
                INSERT INTO workout (deviceId,startTs,endTs,sport,source)
                VALUES ('apple-health',100,200,'Running','apple-health')
                """)
        }

        let currentWorkout = WorkoutRow(startTs: 300, endTs: 500, sport: "Cycling", source: "apple-health",
                                        durationS: 200, energyKcal: nil, avgHr: 120, maxHr: 150,
                                        strain: nil, distanceM: 1000, zonesJSON: nil, notes: nil, steps: nil)
        _ = try await store.replaceAppleHealthWindow(
            appleDailyRows: [AppleDaily(day: "2026-10-06", steps: 321, activeKcal: nil, basalKcal: nil,
                                        vo2max: nil, avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: nil)],
            dailyMetricRows: [],
            metricPoints: [MetricPoint(day: "2026-10-06", key: "steps", value: 321)],
            workoutRows: [currentWorkout],
            hourlyStepRows: [(ts: 120, steps: 12), (ts: 360, steps: 36)],
            deviceId: "apple-health",
            fromDay: "2026-10-01", toDay: "2026-10-07",
            fromTs: 0, toTs: 1_000, hourlyFromTs: 0,
            workoutSource: "apple-health")

        try db.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT steps FROM appleDaily WHERE deviceId='apple-health' AND day='2026-10-06'"), 321)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM metricSeries WHERE deviceId='apple-health' AND key='stale_metric'") ?? -1, 0)
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT value FROM metricSeries WHERE deviceId='apple-health' AND key='steps'"), 321)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workout WHERE deviceId='apple-health' AND source='apple-health'") ?? -1, 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT sport FROM workout WHERE deviceId='apple-health' AND source='apple-health'"), "Cycling")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT steps FROM appleStepHour WHERE deviceId='apple-health' AND ts=120"), 12)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM appleStepHour WHERE deviceId='apple-health'") ?? -1, 2)
        }
    }
}
