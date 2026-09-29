import XCTest
@testable import Strand

final class DailyInsightNotificationPolicyTests: XCTestCase {
    private let utc = Calendar(identifier: .gregorian)
    private var insight: DailyChangeInsight {
        .init(metric: .restingHr, day: "2026-09-29", value: 70, median: 60,
              comparisonDays: 10, windowStart: "2026-09-08", windowEnd: "2026-09-28")
    }
    private var now: Date {
        var c = utc; c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 10))!
    }
    func testOptInCategoryAndOnePerDay() {
        var c = utc; c.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertNil(DailyInsightNotificationPolicy(enabled: false, metrics: [.restingHr], quietStart: 1320,
                    quietEnd: 480, lastNotifiedDay: nil).eligible([insight], now: now, calendar: c))
        XCTAssertNil(DailyInsightNotificationPolicy(enabled: true, metrics: [.hrv], quietStart: 1320,
                    quietEnd: 480, lastNotifiedDay: nil).eligible([insight], now: now, calendar: c))
        XCTAssertEqual(DailyInsightNotificationPolicy(enabled: true, metrics: [.restingHr], quietStart: 1320,
                    quietEnd: 480, lastNotifiedDay: nil).eligible([insight], now: now, calendar: c)?.id, insight.id)
        XCTAssertNil(DailyInsightNotificationPolicy(enabled: true, metrics: [.restingHr], quietStart: 1320,
                    quietEnd: 480, lastNotifiedDay: "2026-09-29").eligible([insight], now: now, calendar: c))
    }
    func testQuietHoursAcrossMidnightAndStaleDay() {
        var c = utc; c.timeZone = TimeZone(secondsFromGMT: 0)!
        let policy = DailyInsightNotificationPolicy(enabled: true, metrics: [.restingHr],
                                                     quietStart: 1320, quietEnd: 480, lastNotifiedDay: nil)
        XCTAssertTrue(policy.isQuiet(at: now.addingTimeInterval(-4 * 3600), calendar: c))
        XCTAssertTrue(policy.isQuiet(at: now.addingTimeInterval(13 * 3600), calendar: c))
        XCTAssertNil(policy.eligible([insight], now: now.addingTimeInterval(24 * 3600), calendar: c))
    }
}
