import XCTest
import Foundation
import StrandDesign
@testable import Strand

/// Phase 2 overnight-chart interaction tests. Selection must reflect a stored
/// sample rather than a made-up line-interpolated value inside a missing gap.
final class SleepNightHRInspectionTests: XCTestCase {
    func testNearestBucketPicksRecordedTimestamp() {
        let stamps = [100, 160, 220, 280]
        XCTAssertEqual(SleepView.nearestNightSampleIndex(stamps, target: 201), 2)
        XCTAssertEqual(SleepView.nearestNightSampleIndex(stamps, target: 190), 1)
        XCTAssertEqual(SleepView.nearestNightSampleIndex(stamps, target: 100), 0)
        XCTAssertEqual(SleepView.nearestNightSampleIndex(stamps, target: 350), 3)
    }

    func testUnavailableSpanShowsNoFabricatedReading() {
        XCTAssertNil(SleepView.nearestNightSampleIndex([], target: 100))
        XCTAssertNil(SleepView.nearestNightSampleIndex([0, 60, 3_600, 3_660],
                                                      target: 1_800))
        XCTAssertEqual(SleepView.nearestNightSampleIndex([0, 60, 3_600, 3_660],
                                                         target: 1_800, maxDistance: 2_000), 1)
    }

    func testOvernightHRVSegmentsRespectMissingData() {
        let seconds = [0, 60, 120, 3_600, 3_660]
        let source = seconds.map {
            TrendPoint(date: Date(timeIntervalSince1970: Double($0)), value: Double($0 / 60))
        }
        let separated = SleepView.gapSeparatedOvernightPoints(source, maxGap: 300)
        XCTAssertEqual(separated.map(\.value), source.map(\.value))
        XCTAssertEqual(separated.map(\.date), source.map(\.date))
        XCTAssertEqual(separated.map(\.segment),
                       ["overnight-0", "overnight-0", "overnight-0",
                        "overnight-1", "overnight-1"])
    }

    func testDenseOvernightSeriesUsesBoundedSearch() {
        let stamps = Array(stride(from: 0, through: 120_000, by: 60))
        XCTAssertEqual(SleepView.nearestNightSampleIndex(stamps, target: 72_017), 1_200)
        XCTAssertEqual(SleepView.nearestNightSampleIndex(stamps, target: 120_000),
                       stamps.count - 1)
    }
}
