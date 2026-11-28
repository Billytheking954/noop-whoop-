import XCTest
import WhoopStore
import StrandAnalytics
@testable import NOOPiOS

@MainActor
final class NewFeatureRegressionTests: XCTestCase {
    private func history() -> [DailyMetric] {
        (1...28).map { index in
            DailyMetric(day: String(format: "2026-11-%02d", index), totalSleepMin: 480,
                        efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                        disturbances: nil, restingHr: index.isMultiple(of: 2) ? 52 : 54,
                        avgHrv: index.isMultiple(of: 2) ? 60 : 64, recovery: 75,
                        strain: 10, exerciseCount: nil)
        }
    }

    func testReadinessSurvivesRolloverUsingChargesLabelledNight() throws {
        let days = history()
        let selected = "2026-11-29"
        let prior = TodayView.lastScoredRecoveryDay(
            days: days, selectedDayKey: selected, isToday: true,
            todayScored: false, isCalibrating: false)
        let priorKey = try XCTUnwrap(prior?.day)
        XCTAssertEqual(ReadinessEngine.evaluate(days: days, today: selected).level, .insufficient)
        let result = LiquidTodayView.resolveReadiness(
            days: days, selectedDayKey: selected, carriedDayKey: priorKey)
        XCTAssertNotNil(result.score)
        XCTAssertEqual(result, ReadinessEngine.evaluate(days: days, today: priorKey))
    }

    func testMissingHistoricalDayCannotBorrowTodaysReadiness() {
        let days = history()
        let selected = "2026-10-31"
        let prior = TodayView.lastScoredRecoveryDay(
            days: days, selectedDayKey: selected, isToday: false,
            todayScored: false, isCalibrating: false)
        XCTAssertNil(prior)
        let result = LiquidTodayView.resolveReadiness(
            days: days, selectedDayKey: selected, carriedDayKey: prior?.day)
        XCTAssertNil(result.score)
        XCTAssertEqual(result.level, .insufficient)
    }

    func testNewlyScoredDaySupersedesCarriedReadiness() {
        let days = history()
        let selected = "2026-11-28"
        let prior = TodayView.lastScoredRecoveryDay(
            days: days, selectedDayKey: selected, isToday: true,
            todayScored: true, isCalibrating: false)
        XCTAssertNil(prior)
        XCTAssertEqual(LiquidTodayView.resolveReadiness(
            days: days, selectedDayKey: selected, carriedDayKey: prior?.day),
                       ReadinessEngine.evaluate(days: days, today: selected))
    }

    func testReviewKeepsItsWorkoutWhenDetectionReplacesOrClearsTheCard() throws {
        let end = Int(Date().timeIntervalSince1970) - 60
        var candidate: DetectedWorkout? = DetectedWorkout(
            startSec: end - 1200, endSec: end, avgBpm: 140, peakBpm: 160, durationMin: 20)
        let review = try XCTUnwrap(AutoWorkoutCard.Review(
            candidate: try XCTUnwrap(candidate), prediction: nil))
        candidate = DetectedWorkout(startSec: end - 3600, endSec: end - 1800,
                                    avgBpm: 130, peakBpm: 150, durationMin: 30)
        XCTAssertNotEqual(review.candidate, candidate)
        candidate = nil
        XCTAssertEqual(review.draft.startTs, end - 1200)
        XCTAssertEqual(review.draft.endTs, end)
        XCTAssertEqual(review.draft.sport, "Other")
        XCTAssertEqual(review.draft.source, "manual")
        XCTAssertEqual(review.candidate.startSec, review.draft.startTs)
        XCTAssertEqual(review.candidate.endSec, review.draft.endTs)
    }
}
