import Foundation
import GRDB

/// Merge the current Apple Health read into the cached source WITHOUT interpreting nil as deletion.
///
/// HealthKit deliberately hides read authorization: a denied read can look exactly like "no matching
/// samples". The live bridge therefore may only overwrite a field when the query actually produced a
/// value. Explicit HealthKit deletion tombstones require a separate reconciliation path.
extension WhoopStore {
    @discardableResult
    public func mergeAppleHealthReadRows(
        appleDailyRows: [AppleDaily],
        dailyMetricRows: [DailyMetric],
        metricPoints: [MetricPoint],
        deviceId: String
    ) async throws -> Int {
        try syncWrite { db in
            var changes = 0

            for r in appleDailyRows {
                try db.execute(sql: """
                    INSERT INTO appleDaily
                        (deviceId, day, steps, activeKcal, basalKcal, vo2max,
                         avgHr, maxHr, walkingHr, weightKg)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, day) DO UPDATE SET
                        steps      = COALESCE(excluded.steps,      appleDaily.steps),
                        activeKcal = COALESCE(excluded.activeKcal, appleDaily.activeKcal),
                        basalKcal  = COALESCE(excluded.basalKcal,  appleDaily.basalKcal),
                        vo2max     = COALESCE(excluded.vo2max,     appleDaily.vo2max),
                        avgHr      = COALESCE(excluded.avgHr,      appleDaily.avgHr),
                        maxHr      = COALESCE(excluded.maxHr,      appleDaily.maxHr),
                        walkingHr  = COALESCE(excluded.walkingHr,  appleDaily.walkingHr),
                        weightKg   = COALESCE(excluded.weightKg,   appleDaily.weightKg)
                    """, arguments: [deviceId, r.day, r.steps, r.activeKcal, r.basalKcal, r.vo2max,
                                     r.avgHr, r.maxHr, r.walkingHr, r.weightKg])
                changes += db.changesCount
            }

            for d in dailyMetricRows {
                try db.execute(sql: """
                    INSERT INTO dailyMetric
                        (deviceId, day, totalSleepMin, efficiency, deepMin, remMin, lightMin,
                         disturbances, restingHr, avgHrv, recovery, strain, exerciseCount,
                         spo2Pct, skinTempDevC, respRateBpm, steps, activeKcalEst,
                         spo2Red, spo2Ir, avgSdnn, skinTempC, sleepHrOnly)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, day) DO UPDATE SET
                        totalSleepMin = COALESCE(excluded.totalSleepMin, dailyMetric.totalSleepMin),
                        efficiency    = COALESCE(excluded.efficiency,    dailyMetric.efficiency),
                        deepMin       = COALESCE(excluded.deepMin,       dailyMetric.deepMin),
                        remMin        = COALESCE(excluded.remMin,        dailyMetric.remMin),
                        lightMin      = COALESCE(excluded.lightMin,      dailyMetric.lightMin),
                        disturbances  = COALESCE(excluded.disturbances,  dailyMetric.disturbances),
                        restingHr     = COALESCE(excluded.restingHr,     dailyMetric.restingHr),
                        avgHrv        = COALESCE(excluded.avgHrv,        dailyMetric.avgHrv),
                        recovery      = COALESCE(excluded.recovery,      dailyMetric.recovery),
                        strain        = COALESCE(excluded.strain,        dailyMetric.strain),
                        exerciseCount = COALESCE(excluded.exerciseCount, dailyMetric.exerciseCount),
                        spo2Pct       = COALESCE(excluded.spo2Pct,       dailyMetric.spo2Pct),
                        skinTempDevC  = COALESCE(excluded.skinTempDevC,  dailyMetric.skinTempDevC),
                        respRateBpm   = COALESCE(excluded.respRateBpm,   dailyMetric.respRateBpm),
                        steps         = COALESCE(excluded.steps,         dailyMetric.steps),
                        activeKcalEst = COALESCE(excluded.activeKcalEst, dailyMetric.activeKcalEst),
                        spo2Red       = COALESCE(excluded.spo2Red,       dailyMetric.spo2Red),
                        spo2Ir        = COALESCE(excluded.spo2Ir,        dailyMetric.spo2Ir),
                        avgSdnn       = COALESCE(excluded.avgSdnn,       dailyMetric.avgSdnn),
                        skinTempC     = COALESCE(excluded.skinTempC,     dailyMetric.skinTempC),
                        sleepHrOnly   = COALESCE(excluded.sleepHrOnly,   dailyMetric.sleepHrOnly)
                    """, arguments: [deviceId, d.day, d.totalSleepMin, d.efficiency, d.deepMin,
                                     d.remMin, d.lightMin, d.disturbances, d.restingHr, d.avgHrv,
                                     d.recovery, d.strain, d.exerciseCount, d.spo2Pct,
                                     d.skinTempDevC, d.respRateBpm, d.steps, d.activeKcalEst,
                                     d.spo2Red, d.spo2Ir, d.avgSdnn, d.skinTempC, d.sleepHrOnly])
                changes += db.changesCount
            }

            changes += try Self.upsertMetricSeries(metricPoints, deviceId: deviceId, in: db)
            return changes
        }
    }
}
