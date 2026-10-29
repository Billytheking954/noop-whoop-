import XCTest
@testable import Strand

final class ExploreRangeWideningTests: XCTestCase {
    func testTwoAndThreeWeekWindowsWidenGradually() {
        XCTAssertEqual(ExploreRange.twoWeeks.widening,
                       [.twoWeeks, .threeWeeks, .month, .quarter, .half, .year, .all])
        XCTAssertEqual(ExploreRange.threeWeeks.widening,
                       [.threeWeeks, .month, .quarter, .half, .year, .all])
    }

    func testAllHistoryCannotWidenFurther() {
        XCTAssertEqual(ExploreRange.all.widening, [.all])
        XCTAssertEqual(ExploreRange.week.widening.first, .week)
    }
}
