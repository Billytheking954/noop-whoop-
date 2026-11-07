import XCTest
import WhoopStore
import StrandDesign
@testable import Strand

final class SleepTimelineEvidenceTests: XCTestCase {
    private func night(segments: [SleepInterval]? = nil) -> Night {
        Night(session: CachedSleepSession(startTs: 1_000, endTs: 29_800,
              efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil),
              stages: Stages(awake: 30, light: 240, deep: 90, rem: 120),
              realSegments: segments)
    }

    func testImportedTotalsDoNotInventStageTiming() {
        let value = night()
        XCTAssertTrue(value.intervals.isEmpty)
        XCTAssertEqual(value.stages.asleep, 450)
        XCTAssertEqual(value.stages.deep, 90)
    }

    func testRecordedSegmentsPreserveTheirTimesAndGaps() {
        let value = night(segments: [
            SleepInterval(stage: .deep, start: 600, end: 900),
            SleepInterval(stage: .rem, start: 1_800, end: 2_100)
        ])
        XCTAssertEqual(value.intervals.count, 2)
        XCTAssertEqual(value.intervals[0].start, 600)
        XCTAssertEqual(value.intervals[0].end, 900)
        XCTAssertEqual(value.intervals[1].start, 1_800)
        XCTAssertEqual(value.intervals[1].end, 2_100)
    }

    func testSingleRecordedSegmentIsNotReplacedWithSyntheticStages() {
        let value = night(segments: [SleepInterval(stage: .light, start: 60, end: 180)])
        XCTAssertEqual(value.intervals.count, 1)
        XCTAssertEqual(value.intervals[0].start, 60)
        XCTAssertEqual(value.intervals[0].end, 180)
    }
}
