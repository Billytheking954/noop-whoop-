import XCTest
@testable import StrandAnalytics

final class WorkoutSuggestionAuditTests: XCTestCase {
    private func suggestion(_ start: Int, _ end: Int,
                            _ predicted: CoarseWorkoutClass) -> AuditedWorkoutSuggestion {
        AuditedWorkoutSuggestion(
            workout: DetectedWorkout(startSec: start, endSec: end, avgBpm: 130,
                                     peakBpm: 155, durationMin: (end - start) / 60),
            predictedClass: predicted)
    }

    func testReportsMissFalseDuplicateAndSportMistakeByRealActivity() {
        let labels = [
            LabeledWorkoutSession(startSec: 1_000, endSec: 2_000, activity: "Running"),
            LabeledWorkoutSession(startSec: 4_000, endSec: 5_000, activity: "Cycling"),
            LabeledWorkoutSession(startSec: 7_000, endSec: 8_000, activity: "Yoga"),
        ]
        let suggestions = [
            suggestion(1_050, 1_950, .walk),       // match Running, wrong sport
            suggestion(1_100, 1_900, .run),        // duplicate for the same Running label
            suggestion(9_000, 10_000, .strength),  // false prompt
        ]
        let cost = WorkoutSuggestionAuditCost(
            wallMilliseconds: 17, hrSamples: 100, gravitySamples: 20, stepSamples: 10)
        let report = WorkoutSuggestionAudit.evaluate(
            labels: labels, suggestions: suggestions, cost: cost)

        XCTAssertEqual(report.byActivity["run"]?.labelled, 1)
        XCTAssertEqual(report.byActivity["run"]?.matched, 1)
        XCTAssertEqual(report.byActivity["run"]?.duplicates, 1)
        XCTAssertEqual(report.byActivity["run"]?.sportMistakes, 1)
        XCTAssertEqual(report.byActivity["cycle"]?.missed, 1)
        XCTAssertEqual(report.byActivity["other"]?.missed, 1)
        XCTAssertEqual(report.byActivity["strength"]?.falsePrompts, 1)
        XCTAssertEqual(report.totals.missed, 2)
        XCTAssertEqual(report.totals.falsePrompts, 1)
        XCTAssertEqual(report.totals.duplicates, 1)
        XCTAssertEqual(report.totals.sportMistakes, 1)
        XCTAssertEqual(cost.approximateInputBytes, 100 * 8 + 20 * 32 + 10 * 16)
        XCTAssertTrue(report.traceLines().last?.contains("extraBLEReads=0") == true)
        XCTAssertTrue(report.traceLines().last?.contains("directBatteryEnergy=n/a") == true)
    }

    func testOtherUnsureIsAvailableAndUnsupportedSpecificGuessCountsAsMistake() {
        XCTAssertEqual(CoarseWorkoutClass.other.editableSportName, "Other")
        XCTAssertEqual(CoarseWorkoutClass.other.suggestionReviewLabel, "Other / unsure")
        XCTAssertEqual(WorkoutSuggestionAudit.expectedClass(for: "Yoga"), .other)

        let report = WorkoutSuggestionAudit.evaluate(
            labels: [LabeledWorkoutSession(startSec: 100, endSec: 1_000, activity: "Yoga")],
            suggestions: [suggestion(200, 900, .cycle)],
            cost: WorkoutSuggestionAuditCost(
                wallMilliseconds: 0, hrSamples: 0, gravitySamples: 0, stepSamples: 0))
        XCTAssertEqual(report.byActivity["other"]?.sportMistakes, 1)
    }
}
