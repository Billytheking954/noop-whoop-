import XCTest
import WhoopStore
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
}
