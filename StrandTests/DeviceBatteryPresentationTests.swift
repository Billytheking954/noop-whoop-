import XCTest
@testable import Strand

/// Device screen regression tests: never format raw BLE doubles or carry stale charge.
/// The production readout uses the same source-aware resolver as the Live console.
final class DeviceBatteryPresentationTests: XCTestCase {
    func testRoundsWholePercentageWithoutFloatingPointArtifacts() {
        XCTAssertEqual(DeviceBatteryPresentation.percent(
            connected: true, activeIsWhoop: true, whoopPct: 86.000001, ringPct: nil), 86)
        XCTAssertEqual(DeviceBatteryPresentation.percent(
            connected: true, activeIsWhoop: true, whoopPct: 86.7, ringPct: nil), 87)
    }

    func testDisconnectedDeviceCannotDisplayCachedBattery() {
        XCTAssertNil(DeviceBatteryPresentation.percent(
            connected: false, activeIsWhoop: true, whoopPct: 86, ringPct: nil))
    }

    func testWrongSourceNeverLeaksIntoRingReading() {
        XCTAssertEqual(DeviceBatteryPresentation.percent(
            connected: true, activeIsWhoop: false, whoopPct: 86, ringPct: 51), 51)
        XCTAssertNil(DeviceBatteryPresentation.percent(
            connected: true, activeIsWhoop: false, whoopPct: 86, ringPct: nil))
    }

    func testMissingAndInvalidReadingsStayUnavailable() {
        for pct in [Double.nan, .infinity, -.infinity, -1, 101] {
            XCTAssertNil(DeviceBatteryPresentation.percent(
                connected: true, activeIsWhoop: true, whoopPct: pct, ringPct: nil))
        }
        XCTAssertNil(DeviceBatteryPresentation.percent(
            connected: true, activeIsWhoop: true, whoopPct: nil, ringPct: 91))
        XCTAssertNil(DeviceBatteryPresentation.percent(
            connected: true, activeIsWhoop: false, whoopPct: 90, ringPct: -1))
        XCTAssertNil(DeviceBatteryPresentation.percent(
            connected: true, activeIsWhoop: false, whoopPct: 90, ringPct: 101))
    }
}
