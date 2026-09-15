import Foundation
import XCTest
import WhoopStore
@testable import Strand

/// StressModel carry (#543). The Today "Stress" metric derives against a 30-day RHR/HRV baseline. Today's
/// own daily row is often vitals-less until the overnight is analyzed (especially right after an app update
/// relaunches and re-runs the analyze pass), and every OTHER Today vital carries last night's value — Stress
/// used to be the one card that didn't, so it dropped to "Calibrating" while the rest showed numbers. These
/// pin the carry: score the newest day that actually has RHR/HRV. Twin of the Android StressModelTest.
final class StressModelCarryTests: XCTestCase {

    private func day(_ d: String, rhr: Int?, hrv: Double?) -> DailyMetric {
        DailyMetric(day: d, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil,
                    strain: nil, exerciseCount: nil)
    }

    // 31 days that all carry RHR + HRV: a full 30-day baseline plus one more scorable day.
    private var baseline: [DailyMetric] {
        (1...30).map { day(String(format: "2026-06-%02d", $0), rhr: 55, hrv: 60) }
            + [day("2026-07-01", rhr: 55, hrv: 60)]
    }

    func testVitalsLessTodayCarriesInsteadOfCalibrating() {
        // Control: today HAS vitals → builds (unchanged).
        XCTAssertNotNil(StressModel(days: baseline + [day("2026-07-02", rhr: 58, hrv: 45)], stored: []))
        // The fix: today has NO RHR/HRV yet (the post-update window) but a prior day does → carries, not nil.
        XCTAssertNotNil(StressModel(days: baseline + [day("2026-07-02", rhr: nil, hrv: nil)], stored: []),
                        "a vitals-less today must carry the last day with RHR/HRV, not calibrate")
    }

    func testNoVitalsAnywhereStillCalibrates() {
        // Genuine cold start: no day has RHR/HRV and nothing stored → honestly calibrating (nil).
        let days = (1...5).map { day("2026-07-0\($0)", rhr: nil, hrv: nil) }
        XCTAssertNil(StressModel(days: days, stored: []))
    }

    func testStoredStressOnLatestVitalsLessDayIsUsedNotSkipped() {
        // An imported latest day carries a STORED vendor stress value but no RHR/HRV (e.g. a Xiaomi /
        // Garmin export). The original gate honoured it; the carry must NOT skip it back to an older vitals
        // day. The stored 2.5 must win over any derived carry.
        let days = baseline + [day("2026-07-02", rhr: nil, hrv: nil)]
        let model = StressModel(days: days, stored: [(day: "2026-07-02", value: 2.5)])
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.score ?? -1, 2.5, accuracy: 0.001,
                       "the latest day's stored stress must win over a carry")
    }

    func testStoredFallbackIsClampedToSharedScale() {
        let days = [day("2026-07-02", rhr: nil, hrv: nil)]
        XCTAssertEqual(StressModel(days: days, stored: [(day: "2026-07-02", value: 99)])?.score,
                       3.0)
    }

    func testStoredStressCannotOverrideDerivableImportedOrNativeVitals() {
        let days = baseline + [day("2026-07-02", rhr: 58, hrv: 45)]
        let native = StressModel(days: days, stored: [])
        let importedWithLegacyStoredRow = StressModel(
            days: days, stored: [(day: "2026-07-02", value: 0.0)]
        )

        XCTAssertNotNil(native)
        XCTAssertEqual(importedWithLegacyStoredRow?.score ?? -1, native?.score ?? -2, accuracy: 0,
                       "equivalent RHR/HRV must score identically regardless of acquisition path")
        XCTAssertFalse(importedWithLegacyStoredRow?.usingStored ?? true,
                       "legacy importer stress must not override derivable physiology")
    }

    func testFutureDaysCannotChangeAnEarlierHistoricalScore() {
        let history = (1...6).map {
            day("2026-06-0\($0)", rhr: 50 + $0, hrv: 72 - Double($0 * 2))
        }
        let target = day("2026-06-07", rhr: 61, hrv: 48)
        let before = StressModel(days: history + [target], stored: [])
        let after = StressModel(days: history + [target,
            day("2026-06-08", rhr: 120, hrv: 5),
            day("2026-06-09", rhr: 35, hrv: 250),
        ], stored: [])

        let targetDate = StressModelCarryTests.utcDay("2026-06-07")
        let beforeValue = before?.fullTrend.first(where: { $0.date == targetDate })?.value
        let afterValue = after?.fullTrend.first(where: { $0.date == targetDate })?.value
        XCTAssertNotNil(beforeValue)
        XCTAssertEqual(afterValue ?? -1, beforeValue ?? -2, accuracy: 0,
                       "T3/T4 observations leaked into T2's baseline")
    }

    func testTargetDayIsExcludedFromItsOwnBaseline() {
        let history = (1...6).map {
            day("2026-06-0\($0)", rhr: 50 + $0, hrv: 72 - Double($0 * 2))
        }
        let calm = StressModel(days: history + [day("2026-06-07", rhr: 58, hrv: 58)], stored: [])
        let extreme = StressModel(days: history + [day("2026-06-07", rhr: 118, hrv: 8)], stored: [])

        let calmBaselineRHR = 58.0 - (calm?.rhrDelta ?? Double.nan)
        let extremeBaselineRHR = 118.0 - (extreme?.rhrDelta ?? Double.nan)
        let calmBaselineHRV = 58.0 - (calm?.hrvDelta ?? Double.nan)
        let extremeBaselineHRV = 8.0 - (extreme?.hrvDelta ?? Double.nan)
        XCTAssertEqual(extremeBaselineRHR, calmBaselineRHR, accuracy: 0)
        XCTAssertEqual(extremeBaselineHRV, calmBaselineHRV, accuracy: 0)
    }

    func testOutOfOrderReplayMatchesChronologicalInput() {
        let ordered = (1...9).map {
            day("2026-06-0\($0)", rhr: 50 + $0, hrv: 75 - Double($0 * 2))
        }
        let chronological = StressModel(days: ordered, stored: [])
        let replayed = StressModel(days: [ordered[7], ordered[1], ordered[8], ordered[0],
                                          ordered[5], ordered[3], ordered[6], ordered[2], ordered[4]],
                                   stored: [])
        XCTAssertEqual(replayed?.score, chronological?.score)
        XCTAssertEqual(replayed?.fullTrend.map(\.date), chronological?.fullTrend.map(\.date))
        XCTAssertEqual(replayed?.fullTrend.map(\.value), chronological?.fullTrend.map(\.value))
    }

    func testRebuildFromPersistedInputsMatchesUninterruptedExecution() {
        let persistedPrefix = (1...7).map {
            day("2026-06-0\($0)", rhr: 50 + $0, hrv: 75 - Double($0 * 2))
        }
        let continuation = [
            day("2026-06-08", rhr: 59, hrv: 55),
            day("2026-06-09", rhr: 61, hrv: 51),
        ]
        _ = StressModel(days: persistedPrefix, stored: [])
        let uninterrupted = StressModel(days: persistedPrefix + continuation, stored: [])
        let afterRestart = StressModel(days: persistedPrefix + continuation, stored: [])

        XCTAssertEqual(afterRestart?.score, uninterrupted?.score)
        XCTAssertEqual(afterRestart?.fullTrend.map(\.date), uninterrupted?.fullTrend.map(\.date))
        XCTAssertEqual(afterRestart?.fullTrend.map(\.value), uninterrupted?.fullTrend.map(\.value))
    }

    private static func utcDay(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!
    }
}
