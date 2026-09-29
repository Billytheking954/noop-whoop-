import XCTest
import WhoopStore
@testable import Strand

final class DailyChangeInsightTests: XCTestCase {
    private func row(_ day: Int, rhr: Int? = 60, hrv: Double? = 60, sleep: Double? = 450) -> DailyMetric {
        DailyMetric(day: String(format: "2026-09-%02d", day), totalSleepMin: sleep,
                    efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil,
                    strain: nil, exerciseCount: nil)
    }

    func testRequiresSevenPlausiblePriorDaysAndWithdrawsRevisedFinding() {
        let six = (1...6).map { row($0) }
        XCTAssertTrue(DailyChangeInsight.derive(from: six + [row(7, rhr: 70)], now: .init(timeIntervalSince1970: 1_800_000_000)).isEmpty)
        let seven = (1...7).map { row($0) }
        let changed = seven + [row(8, rhr: 70)]
        let result = DailyChangeInsight.derive(from: changed, now: .init(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(result.map(\.id), ["rhr:2026-09-08"])
        XCTAssertEqual(result.first?.median, 60)
        XCTAssertEqual(result.first?.comparisonDays, 7)
        // A late offload replaces the same day's row. The finding is derived, so no stale copy remains.
        XCTAssertTrue(DailyChangeInsight.derive(from: seven + [row(8, rhr: 62)],
                                                    now: .init(timeIntervalSince1970: 1_800_000_000)).isEmpty)
    }

    func testMissingAndImplausibleReadingsCannotCreateAnInsight() {
        let prior = (1...10).map { row($0) }
        let result = DailyChangeInsight.derive(from: prior + [row(11, rhr: nil, hrv: .nan, sleep: 30)],
                                                now: .init(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(result.isEmpty)
    }

    func testAWindowDoesNotBorrowOldHistory() {
        let previous = (1...7).map { day in
            DailyMetric(day: String(format: "2026-07-%02d", day), totalSleepMin: 450,
                        efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                        disturbances: nil, restingHr: 60, avgHrv: 60, recovery: nil,
                        strain: nil, exerciseCount: nil)
        }
        XCTAssertTrue(DailyChangeInsight.derive(from: previous + [row(20, rhr: 75)],
                                                    now: .init(timeIntervalSince1970: 1_800_000_000)).isEmpty)
    }
}
