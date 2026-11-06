import Foundation
import XCTest
@testable import StrandImport

final class HealthKitSleepSummaryTests: XCTestCase {
    private func interval(_ stage: SleepStage, _ start: Double, _ end: Double) -> HealthKitSleepSummary.Interval {
        .init(stage: stage, start: Date(timeIntervalSince1970: start * 60),
              end: Date(timeIntervalSince1970: end * 60))
    }

    func testUnspecifiedSleepDoesNotBecomeCoreOrMeasuredZeroStages() {
        let result = HealthKitSleepSummary.summarize([interval(.asleepUnspecified, 0, 60)])
        XCTAssertEqual(result.asleepMin, 60)
        XCTAssertNil(result.coreMin)
        XCTAssertNil(result.deepMin)
        XCTAssertNil(result.remMin)
        XCTAssertEqual(result.unspecifiedAsleepMin, 60)
        XCTAssertEqual(result.status, .incompleteStages)
    }

    func testDuplicatesAndPartialOverlapsAreCountedOnce() {
        let intervals = [interval(.asleepCore, 0, 30), interval(.asleepCore, 15, 45)]
        let result = HealthKitSleepSummary.summarize(intervals + intervals)
        XCTAssertEqual(result.asleepMin, 45)
        XCTAssertEqual(result.coreMin, 45)
        XCTAssertEqual(result.deepMin, 0)
        XCTAssertEqual(result.remMin, 0)
        XCTAssertEqual(result.status, .completeStages)
        XCTAssertEqual(result, HealthKitSleepSummary.summarize(intervals))
    }

    func testUnspecifiedOverlayDoesNotEraseExplicitStages() {
        let result = HealthKitSleepSummary.summarize([
            interval(.asleepUnspecified, 0, 60), interval(.asleepCore, 0, 30),
            interval(.asleepDeep, 30, 60), interval(.inBed, -10, 70)
        ])
        XCTAssertEqual(result.asleepMin, 60)
        XCTAssertEqual(result.coreMin, 30)
        XCTAssertEqual(result.deepMin, 30)
        XCTAssertEqual(result.unspecifiedAsleepMin, 0)
        XCTAssertEqual(result.status, .completeStages)
    }

    func testConflictingAsleepStagesKeepTotalButWithholdWholeBreakdown() {
        let result = HealthKitSleepSummary.summarize([
            interval(.asleepCore, 0, 45), interval(.asleepREM, 30, 60)
        ])
        XCTAssertEqual(result.asleepMin, 60)
        XCTAssertEqual(result.stageConflictMin, 15)
        XCTAssertEqual(result.unspecifiedAsleepMin, 15)
        XCTAssertNil(result.coreMin)
        XCTAssertNil(result.remMin)
        XCTAssertNil(result.deepMin)
        XCTAssertEqual(result.status, .incompleteStages)
    }

    func testAwakeAsleepConflictWithholdsTotalInsteadOfChoosingSource() {
        let result = HealthKitSleepSummary.summarize([
            interval(.asleepCore, 0, 60), interval(.awake, 20, 25)
        ])
        XCTAssertNil(result.asleepMin)
        XCTAssertNil(result.coreMin)
        XCTAssertNil(result.deepMin)
        XCTAssertNil(result.remMin)
        XCTAssertEqual(result.observedAsleepMin, 60)
        XCTAssertEqual(result.conflictingMin, 5)
        XCTAssertEqual(result.status, .conflictingSleepWake)
    }

    func testGapsRemainAbsentAndTouchingAwakeDoesNotConflict() {
        let result = HealthKitSleepSummary.summarize([
            interval(.asleepCore, 0, 10), interval(.awake, 10, 20),
            interval(.asleepDeep, 40, 50)
        ])
        XCTAssertEqual(result.asleepMin, 20)
        XCTAssertEqual(result.coreMin, 10)
        XCTAssertEqual(result.deepMin, 10)
        XCTAssertEqual(result.conflictingMin, 0)
    }

    func testWindowClipsIntervalsAndDropsOutsideSamples() {
        let window = DateInterval(start: Date(timeIntervalSince1970: 10 * 60), duration: 20 * 60)
        let result = HealthKitSleepSummary.summarize([
            interval(.asleepCore, 0, 20), interval(.asleepDeep, 20, 40),
            interval(.asleepREM, 50, 60)
        ], window: window)
        XCTAssertEqual(result.asleepMin, 20)
        XCTAssertEqual(result.coreMin, 10)
        XCTAssertEqual(result.deepMin, 10)
        XCTAssertEqual(result.remMin, 0)
    }

    func testInvalidIntervalsAreRejectedAndUnmappedStatesDoNotInventSleep() {
        let result = HealthKitSleepSummary.summarize([
            interval(.asleepCore, 10, 0), interval(.asleepCore, 5, 5),
            interval(.asleepCore, .nan, 10), interval(.asleepCore, 0, .infinity),
            interval(.unknown, 0, 60), interval(.inBed, 0, 60), interval(.awake, 0, 60)
        ])
        XCTAssertEqual(result.rejectedIntervalCount, 4)
        XCTAssertEqual(result.status, .noSleep)
        XCTAssertNil(result.asleepMin)
        XCTAssertNil(result.coreMin)
    }

    func testZeroLengthWindowProducesNoSummary() {
        let result = HealthKitSleepSummary.summarize([interval(.asleepCore, 0, 10)],
            window: DateInterval(start: Date(timeIntervalSince1970: 0), duration: 0))
        XCTAssertNil(result.asleepMin)
        XCTAssertEqual(result.rejectedIntervalCount, 1)
    }

    func testOrderAndDuplicatingInputsDoNotChangeResolution() {
        let intervals = [interval(.asleepCore, 0, 20), interval(.asleepDeep, 10, 30),
                         interval(.asleepUnspecified, 30, 40), interval(.awake, 50, 60)]
        let expected = HealthKitSleepSummary.summarize(intervals)
        XCTAssertEqual(expected, HealthKitSleepSummary.summarize(Array(intervals.reversed())))
        XCTAssertEqual(expected, HealthKitSleepSummary.summarize(intervals + intervals))
    }
}
