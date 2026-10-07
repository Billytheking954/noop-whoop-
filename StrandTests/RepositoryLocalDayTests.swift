import XCTest
import Foundation
@testable import Strand

final class RepositoryLocalDayTests: XCTestCase {
    private func iso(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func londonCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    func testLocalDayKeyUsesInjectedZoneForSameInstant() {
        let instant = iso("2026-01-01T00:30:00Z")
        XCTAssertEqual(Repository.localDayKey(instant, timeZone: TimeZone(identifier: "Europe/London")!),
                       "2026-01-01")
        XCTAssertEqual(Repository.localDayKey(instant, timeZone: TimeZone(identifier: "America/New_York")!),
                       "2025-12-31")
    }

    func testLogicalDayRollsAtFourLocalAcrossSpringForward() {
        let calendar = londonCalendar()

        // 04:01 BST is 03:01Z. Subtracting four elapsed hours lands on 23:01 the previous
        // UTC/local day, which was the old bug; calendar semantics say the logical day has rolled.
        let afterRollover = iso("2025-03-30T03:01:00Z")
        XCTAssertEqual(Repository.logicalDayKey(afterRollover, calendar: calendar), "2025-03-30")

        let beforeRollover = iso("2025-03-30T02:59:00Z") // 03:59 BST
        XCTAssertEqual(Repository.logicalDayKey(beforeRollover, calendar: calendar), "2025-03-29")
    }

    func testLogicalDayStartIsRealMidnightOnSpringForwardDate() {
        let calendar = londonCalendar()
        let afterRollover = iso("2025-03-30T03:01:00Z")
        XCTAssertEqual(Repository.logicalDayStart(afterRollover, calendar: calendar),
                       iso("2025-03-30T00:00:00Z"))
    }

    func testDayAfterIsCivilCalendarArithmetic() {
        XCTAssertEqual(Repository.dayAfter("2024-02-28"), "2024-02-29")
        XCTAssertEqual(Repository.dayAfter("2024-02-29"), "2024-03-01")
        XCTAssertEqual(Repository.dayAfter("2026-12-31"), "2027-01-01")
        XCTAssertEqual(Repository.dayAfter("not-a-day"), "not-a-day")
    }
}
