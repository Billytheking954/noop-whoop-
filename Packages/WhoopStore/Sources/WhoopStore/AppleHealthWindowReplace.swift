import Foundation
import GRDB

/// Atomic source-window replacement for live Apple Health reads.
///
/// HealthKit aggregate/sample queries return the current truth for a bounded window. Treating that truth
/// as a stream of UPSERTS cannot represent deletion: a removed sample simply stops appearing and its old
/// row survives forever. This replacement primitive clears ONLY the apple-health source inside the exact
/// successfully-read window, then inserts the freshly collected snapshot in the SAME SQLite transaction.
///
/// The caller must not invoke this after any failed HealthKit read. Empty arrays are authoritative here:
/// they mean the successfully-read source contains nothing in that part of the window and stale rows must
/// be removed.
extension WhoopStore {
    @discardableResult
    public func replaceAppleHealthWindow(
        appleDailyRows: [AppleDaily],
        dailyMetricRows: [DailyMetric],
        metricPoints: [MetricPoint],
        workoutRows: [WorkoutRow],
        hourlyStepRows: [(ts: Int, steps: Int)],
        deviceId: String,
        fromDay: String,
        toDay: String,
        fromTs: Int,
        toTs: Int,
        hourlyFromTs: Int,
        workoutSource: String
    ) async throws -> [WorkoutRow] {
        try syncWrite { db in
            // Capture the rows this authoritative snapshot is replacing. The iOS layer owns the route
            // side-store and uses these keys after commit to remove routes for Health workouts that were
            // actually deleted, without touching a same-window route belonging to another source.
            let oldWorkouts = try Row.fetchAll(db, sql: """
                SELECT startTs, endTs, sport, source, durationS, energyKcal, avgHr, maxHr,
                       strain, distanceM, zonesJSON, notes, steps
                FROM workout
                WHERE deviceId = ? AND source = ? AND startTs >= ? AND startTs <= ?
                ORDER BY startTs ASC
                """, arguments: [deviceId, workoutSource, fromTs, toTs])
                .map {
                    WorkoutRow(startTs: $0["startTs"], endTs: $0["endTs"], sport: $0["sport"],
                               source: $0["source"], durationS: $0["durationS"],
                               energyKcal: $0["energyKcal"], avgHr: $0["avgHr"], maxHr: $0["maxHr"],
                               strain: $0["strain"], distanceM: $0["distanceM"],
                               zonesJSON: $0["zonesJSON"], notes: $0["notes"], steps: $0["steps"])
                }

            try db.execute(sql: """
                DELETE FROM appleDaily
                WHERE deviceId = ? AND day >= ? AND day <= ?
                """, arguments: [deviceId, fromDay, toDay])
            try db.execute(sql: """
                DELETE FROM dailyMetric
                WHERE deviceId = ? AND day >= ? AND day <= ?
                """, arguments: [deviceId, fromDay, toDay])
            try db.execute(sql: """
                DELETE FROM metricSeries
                WHERE deviceId = ? AND day >= ? AND day <= ?
                """, arguments: [deviceId, fromDay, toDay])
            try db.execute(sql: """
                DELETE FROM workout
                WHERE deviceId = ? AND source = ? AND startTs >= ? AND startTs <= ?
                """, arguments: [deviceId, workoutSource, fromTs, toTs])
            try db.execute(sql: """
                DELETE FROM appleStepHour
                WHERE deviceId = ? AND ts >= ? AND ts <= ?
                """, arguments: [deviceId, hourlyFromTs, toTs])

            for r in appleDailyRows {
                try db.execute(sql: """
                    INSERT INTO appleDaily
                        (deviceId, day, steps, activeKcal, basalKcal, vo2max,
                         avgHr, maxHr, walkingHr, weightKg)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, day) DO UPDATE SET
                        steps = excluded.steps,
                        activeKcal = excluded.activeKcal,
                        basalKcal = excluded.basalKcal,
                        vo2max = excluded.vo2max,
                        avgHr = excluded.avgHr,
                        maxHr = excluded.maxHr,
                        walkingHr = excluded.walkingHr,
                        weightKg = excluded.weightKg
                    """, arguments: [deviceId, r.day, r.steps, r.activeKcal, r.basalKcal, r.vo2max,
                                     r.avgHr, r.maxHr, r.walkingHr, r.weightKg])
            }
            _ = try Self.upsertDailyMetrics(dailyMetricRows, deviceId: deviceId, in: db)
            _ = try Self.upsertMetricSeries(metricPoints, deviceId: deviceId, in: db)

            for r in workoutRows {
                try db.execute(sql: """
                    INSERT INTO workout
                        (deviceId, startTs, endTs, sport, source, durationS, energyKcal,
                         avgHr, maxHr, strain, distanceM, zonesJSON, notes, steps)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, startTs, sport) DO UPDATE SET
                        endTs = excluded.endTs,
                        source = excluded.source,
                        durationS = excluded.durationS,
                        energyKcal = excluded.energyKcal,
                        avgHr = excluded.avgHr,
                        maxHr = excluded.maxHr,
                        strain = excluded.strain,
                        distanceM = excluded.distanceM,
                        zonesJSON = excluded.zonesJSON,
                        notes = excluded.notes,
                        steps = excluded.steps
                    """, arguments: [deviceId, r.startTs, r.endTs, r.sport, r.source, r.durationS,
                                     r.energyKcal, r.avgHr, r.maxHr, r.strain, r.distanceM,
                                     r.zonesJSON, r.notes, r.steps])
            }

            for r in hourlyStepRows {
                try db.execute(sql: """
                    INSERT INTO appleStepHour (deviceId, ts, steps)
                    VALUES (?, ?, ?)
                    ON CONFLICT(deviceId, ts) DO UPDATE SET steps = excluded.steps
                    """, arguments: [deviceId, r.ts, r.steps])
            }
            return oldWorkouts
        }
    }
}
