import XCTest
import WhoopStore
import StrandDesign
@testable import Strand

final class SleepImportedTimelineTests: XCTestCase {
    func testImportedTotalsCannotImplyWhenStagesOccurred() {
        let session = CachedSleepSession(startTs: 1_700_000_000, endTs: 1_700_028_800,
                                         efficiency: 0.9, restingHr: nil, avgHrv: nil,
                                         stagesJSON: #"{"light":240,"deep":90,"rem":90,"awake":60}"#,
                                         userEdited: false, startTsAdjusted: nil)
        var night = Night(session: session, stages: Stages(awake: 60, light: 240, deep: 90, rem: 90))
        XCTAssertEqual(night.stages.asleep, 420)
        XCTAssertTrue(night.intervals.isEmpty, "Imported totals have no timing for a hypnogram")

        let measured = SleepInterval(stage: .deep, start: 3_600, end: 5_400)
        night.realSegments = [measured]
        XCTAssertEqual(night.intervals.count, 1)
        XCTAssertEqual(night.intervals[0].start, measured.start)
    }

    func testBridgeWithoutStageSamplesStaysUnknown() throws {
        let start = 1_700_000_000
        let first = CachedSleepSession(startTs: start, endTs: start + 7_200,
                                       efficiency: nil, restingHr: nil, avgHrv: nil,
                                       stagesJSON: #"{"light":120}"#)
        let second = CachedSleepSession(startTs: start + 7_500, endTs: start + 14_700,
                                        efficiency: nil, restingHr: nil, avgHrv: nil,
                                        stagesJSON: #"{"light":120}"#)
        let night = try XCTUnwrap(SleepModel.mergeDay([first, second],
                                                       habitualMidsleepSec: nil, motionByStart: [:]))
        XCTAssertEqual(night.sourceBlocks.count, 2)
        XCTAssertEqual(night.stages.awake, 0)
        XCTAssertTrue(night.intervals.isEmpty, "A five-minute data gap is not measured awake time")
    }
}
