import XCTest
import Foundation
@testable import Strand
import StrandAnalytics

/// #277 — IntelligenceEngine's LOCAL-midnight floor used to re-bucket daily metrics by the device's
/// local calendar day (the bucket the dashboard reads). Mirrors the Android
/// LocalDayBucketingTest.midnightLocal_* cases byte-for-byte in logic/constants.
final class LocalDayMidnightTests: XCTestCase {

    func testMidnightLocalFloorsToLocalMidnightWestOfUTC() {
        // UTC-4: local 21:00 on 2021-06-15 == 01:00 UTC 2021-06-16 == 1623805200. Local midnight is
        // 2021-06-15 00:00 local == 04:00 UTC == 1623729600.
        let offset = -4 * 3600
        let tsUtc = 1_623_805_200
        XCTAssertEqual(IntelligenceEngine.midnightLocal(tsUtc, offsetSec: offset), 1_623_729_600)
        // The floored value, re-keyed under the same offset, is the local day.
        XCTAssertEqual(
            AnalyticsEngine.dayString(IntelligenceEngine.midnightLocal(tsUtc, offsetSec: offset),
                                      offsetSec: offset),
            "2021-06-15")
    }

    func testMidnightLocalOffsetZeroEqualsMidnightUtc() {
        // floorMod-based local floor with offset 0 must equal the legacy UTC midnight floor for any sign.
        for ts in [1_609_459_200, 1_609_459_200 + 45_000, 0, 86_399, -1, -86_401] {
            XCTAssertEqual(IntelligenceEngine.midnightLocal(ts, offsetSec: 0),
                           IntelligenceEngine.midnightUtc(ts),
                           "midnightLocal(offset=0) must equal midnightUtc for ts=\(ts)")
        }
    }

    func testMidnightLocalNegativeOffsetSignCorrect() {
        // The floored local midnight must be <= ts and land exactly on a local-day boundary
        // (ts+offset divisible by 86400). Guards floorMod sign for negative offsets/timestamps.
        let offset = -5 * 3600 // UTC-5
        for ts in [1_623_805_200, 1_600_000_000, 100] {
            let mid = IntelligenceEngine.midnightLocal(ts, offsetSec: offset)
            let mod = ((mid + offset) % 86_400 + 86_400) % 86_400
            XCTAssertEqual(mod, 0, "must land on a local-day boundary")
            XCTAssertLessThanOrEqual(mid, ts, "midnight floor must not exceed ts")
            XCTAssertLessThan(ts - mid, 86_400, "floor must be within the same local day")
        }
    }
    private func utc(_ value: String) -> Int {
        Int(ISO8601DateFormatter().date(from: value)!.timeIntervalSince1970)
    }

    func testProductionWindowsUseTwentyFiveHourFallBackDay() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let windows = IntelligenceEngine.localDayWindows(
            now: utc("2025-11-02T17:00:00Z"), maxDays: 1, timeZone: zone)
        let window = try XCTUnwrap(windows.first)
        XCTAssertEqual(window.date.key, "2025-11-02")
        XCTAssertEqual(Int(window.start.timeIntervalSince1970), utc("2025-11-02T04:00:00Z"))
        XCTAssertEqual(Int(window.nextStart.timeIntervalSince1970), utc("2025-11-03T05:00:00Z"))
        XCTAssertEqual(Int(window.duration), 25 * 3_600)
    }

    func testProductionWindowsUseTwentyThreeHourSpringForwardDay() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        let windows = IntelligenceEngine.localDayWindows(
            now: utc("2025-03-30T12:00:00Z"), maxDays: 1, timeZone: zone)
        let window = try XCTUnwrap(windows.first)
        XCTAssertEqual(window.date.key, "2025-03-30")
        XCTAssertEqual(Int(window.start.timeIntervalSince1970), utc("2025-03-30T00:00:00Z"))
        XCTAssertEqual(Int(window.nextStart.timeIntervalSince1970), utc("2025-03-30T23:00:00Z"))
        XCTAssertEqual(Int(window.duration), 23 * 3_600)
    }

    func testProductionWindowsKeepOrdinaryDayAtTwentyFourHours() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Kathmandu"))
        let windows = IntelligenceEngine.localDayWindows(
            now: utc("2025-06-15T12:00:00Z"), maxDays: 1, timeZone: zone)
        XCTAssertEqual(Int(try XCTUnwrap(windows.first).duration), 86_400)
    }

    func testDelayedRecalculationAfterFallBackKeepsHistoricalMidnight() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let windows = IntelligenceEngine.localDayWindows(
            now: utc("2025-11-10T17:00:00Z"), maxDays: 23, timeZone: zone)
        let historical = try XCTUnwrap(windows.first { $0.date.key == "2025-10-19" })
        XCTAssertEqual(Int(historical.start.timeIntervalSince1970), utc("2025-10-19T04:00:00Z"))
        XCTAssertNotEqual(Int(historical.start.timeIntervalSince1970), utc("2025-10-19T05:00:00Z"))
    }

    func testSleepReadEndUsesResolvedNextMidnightInsteadOfFixedTwentyFourHours() {
        let start = utc("2025-11-02T04:00:00Z")
        let next = utc("2025-11-03T05:00:00Z")
        XCTAssertEqual(
            IntelligenceEngine.sleepReadWindowEnd(dayStart: start, nextDayStart: next,
                                                  nowLocalMidnight: next, now: next + 3_600),
            next
        )
    }

}
