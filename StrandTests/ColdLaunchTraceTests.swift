import XCTest
@testable import Strand

@MainActor
final class ColdLaunchTraceTests: XCTestCase {
    func testNewLaunchClearsOldMilestonesAndPhaseCounts() throws {
        let prefix = "noop.diagnostics.coldRootLoad."
        let defaults = UserDefaults.standard
        ColdLaunchTrace.begin()
        ColdLaunchTrace.mark("today-score-content-observed")
        let first = try XCTUnwrap(defaults.object(forKey: prefix + "milestone.today-score-content-observed") as? Double)
        ColdLaunchTrace.mark("today-score-content-observed")
        XCTAssertEqual(defaults.double(forKey: prefix + "milestone.today-score-content-observed"), first)
        for _ in 0..<2 {
            let phase = ColdLaunchTrace.beginPhase("today-day")
            ColdLaunchTrace.endPhase(phase)
        }
        XCTAssertEqual(defaults.integer(forKey: prefix + "count.today-day"), 2)
        ColdLaunchTrace.finish(cacheLoaded: true, cachedDays: 120)
        ColdLaunchTrace.finishTodayDataLoad()
        let snapshot = try XCTUnwrap(ColdLaunchTrace.latest())
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(snapshot.todayDataLoadSeconds), snapshot.seconds)
        ColdLaunchTrace.begin()
        XCTAssertNil(ColdLaunchTrace.latest())
        XCTAssertNil(defaults.object(forKey: prefix + "milestone.today-score-content-observed"))
        XCTAssertNil(defaults.object(forKey: prefix + "count.today-day"))
        XCTAssertNil(defaults.object(forKey: prefix + "phase.today-day"))
    }
}
