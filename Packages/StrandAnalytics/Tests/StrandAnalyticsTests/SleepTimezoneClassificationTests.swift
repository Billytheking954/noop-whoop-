import Foundation
import XCTest
@testable import StrandAnalytics

final class SleepTimezoneClassificationTests: XCTestCase {
    func testLondonHistoricalNightUsesSpringForwardOffsetForClassification() throws {
        let london = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        // 19:30Z on 30 March 2025 was 20:30 BST. A winter offset of zero classifies it
        // as daytime and drops this otherwise-valid four-hour sleep from the main-night set.
        let onset = try utc("2025-03-30T19:30:00Z")
        assertHistoricalNight(onset: onset, timeZone: london, staleOffset: 0)
    }

    func testSydneyHistoricalNightUsesPreFallBackOffsetForClassification() throws {
        let sydney = try XCTUnwrap(TimeZone(identifier: "Australia/Sydney"))
        // 09:30Z on 5 April 2025 was 20:30 AEDT, before the autumn fall-back at 16:00Z.
        // The later standard-time offset (+10h) would incorrectly classify it as 19:30.
        let onset = try utc("2025-04-05T09:30:00Z")
        XCTAssertEqual(sydney.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(onset))), 11 * 3_600)
        assertHistoricalNight(onset: onset, timeZone: sydney, staleOffset: 10 * 3_600)
    }

    private func assertHistoricalNight(onset: Int, timeZone: TimeZone, staleOffset: Int,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(SleepStageTotals.isOvernightOnset(onset, offsetSec: staleOffset), file: file, line: line)
        XCTAssertTrue(SleepStageTotals.isOvernightOnset(onset, timeZone: timeZone), file: file, line: line)
        XCTAssertFalse(SleepStager.isOvernightOnset(onset, tzOffsetSeconds: staleOffset), file: file, line: line)
        XCTAssertTrue(SleepStager.isOvernightOnset(onset, tzOffsetSeconds: staleOffset,
                                                    timeZone: timeZone), file: file, line: line)

        let block = PhysiologicalSteps.SleepBlock(onset: onset, end: onset + 4 * 3_600, id: "night")
        let legacy = PhysiologicalSteps.classifyForCycle([block], offsetSec: staleOffset,
                                                          habitualMidsleepSec: nil)
        guard case .nap? = legacy.first?.kind else {
            return XCTFail("the fixed-offset overload should preserve its legacy classification", file: file, line: line)
        }

        let ruleAware = PhysiologicalSteps.classifyForCycle([block], offsetSec: staleOffset,
                                                             habitualMidsleepSec: nil,
                                                             timeZone: timeZone)
        guard case .mainSleep? = ruleAware.first?.kind else {
            return XCTFail("the rule-aware overload should classify the historical night as main sleep", file: file, line: line)
        }
    }

    private func utc(_ value: String, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        let formatter = ISO8601DateFormatter()
        let date = try XCTUnwrap(formatter.date(from: value), file: file, line: line)
        return Int(date.timeIntervalSince1970.rounded(.down))
    }
}
