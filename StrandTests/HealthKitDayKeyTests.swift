#if os(iOS)
import XCTest
import Foundation
@testable import Strand

final class HealthKitDayKeyTests: XCTestCase {
    func testDayKeyUsesTheSuppliedZoneRatherThanAProcessFrozenZone() {
        let instant = Date(timeIntervalSince1970: 1_767_247_400) // 2026-01-01 00:30:00Z
        let london = TimeZone(identifier: "Europe/London")!
        let newYork = TimeZone(identifier: "America/New_York")!

        XCTAssertEqual(HealthKitBridge.dayString(instant, in: london), "2026-01-01")
        XCTAssertEqual(HealthKitBridge.dayString(instant, in: newYork), "2025-12-31")
    }

    func testParsingDayUsesRealSpringForwardMidnight() throws {
        let london = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        let midnight = try XCTUnwrap(HealthKitBridge.date(from: "2025-03-30", in: london))

        XCTAssertEqual(midnight.timeIntervalSince1970, 1_743_292_800, accuracy: 0.5) // 2025-03-30 00:00:00Z
    }

    func testParsingDayUsesRealFallBackMidnight() throws {
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let midnight = try XCTUnwrap(HealthKitBridge.date(from: "2025-11-02", in: newYork))

        XCTAssertEqual(midnight.timeIntervalSince1970, 1_762_059_600, accuracy: 0.5) // 2025-11-02 04:00:00Z
    }
}
#endif
