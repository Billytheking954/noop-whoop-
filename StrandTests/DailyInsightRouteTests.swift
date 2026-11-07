import XCTest
@testable import Strand

@MainActor
final class DailyInsightRouteTests: XCTestCase {
    func testNotificationRouteKeepsExactInsightIdentifier() {
        let router = NavRouter()
        router.openDailyInsight(id: "rhr:2026-09-29")
        XCTAssertEqual(router.pendingDailyInsightID, "rhr:2026-09-29")
        XCTAssertEqual(router.requestedDestination, .insightsHub)
    }
}
