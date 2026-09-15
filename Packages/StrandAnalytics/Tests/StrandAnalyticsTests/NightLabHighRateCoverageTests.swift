import XCTest
@testable import StrandAnalytics

final class NightLabHighRateCoverageTests: XCTestCase {

    func testOneSecondAt100HzDoesNotCollapseToOneSample() {
        let timestamps = (0..<100).map { Int64($0 * 10) }
        let report = NightHighRateCoverage.analyze(
            kind: .accelerometer,
            timestampsMilliseconds: timestamps,
            windowStartMilliseconds: 0,
            windowEndMilliseconds: 1_000,
            expectedCadenceHz: 100
        )

        XCTAssertEqual(report.sampleCount, 100)
        XCTAssertEqual(report.expectedSamples, 100)
        XCTAssertEqual(report.coverageFraction ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(report.gapCount, 0)
        XCTAssertEqual(report.largestGapMilliseconds, 10)
    }

    func testMissingHighRateBlockIsReportedAsGap() {
        var timestamps = (0..<100).map { Int64($0 * 10) }
        timestamps.removeAll { $0 >= 400 && $0 < 600 }

        let report = NightHighRateCoverage.analyze(
            kind: .gyroscope,
            timestampsMilliseconds: timestamps,
            windowStartMilliseconds: 0,
            windowEndMilliseconds: 1_000,
            expectedCadenceHz: 100
        )

        XCTAssertEqual(report.sampleCount, 80)
        XCTAssertEqual(report.expectedSamples, 100)
        XCTAssertEqual(report.coverageFraction ?? -1, 0.8, accuracy: 0.0001)
        XCTAssertEqual(report.gapCount, 1)
        XCTAssertEqual(report.largestGapMilliseconds, 210)
    }

    func testUnknownCadenceReportsGeometryWithoutFabricatedCoverage() {
        let report = NightHighRateCoverage.analyze(
            kind: .optical,
            timestampsMilliseconds: [0, 12, 25, 39],
            windowStartMilliseconds: 0,
            windowEndMilliseconds: 50,
            expectedCadenceHz: nil
        )

        XCTAssertEqual(report.sampleCount, 4)
        XCTAssertNil(report.expectedSamples)
        XCTAssertNil(report.coverageFraction)
        XCTAssertNil(report.gapCount)
        XCTAssertEqual(report.largestGapMilliseconds, 14)
    }

    func testDuplicateMillisecondSamplesStillCountAsSamples() {
        let report = NightHighRateCoverage.analyze(
            kind: .optical,
            timestampsMilliseconds: [0, 0, 10, 20, 30],
            windowStartMilliseconds: 0,
            windowEndMilliseconds: 40,
            expectedCadenceHz: 100
        )

        XCTAssertEqual(report.sampleCount, 5)
        XCTAssertEqual(report.expectedSamples, 4)
        XCTAssertEqual(report.coverageFraction ?? -1, 1, accuracy: 0.0001)
    }
}
