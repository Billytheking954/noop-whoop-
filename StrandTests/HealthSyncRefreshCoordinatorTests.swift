import XCTest
@testable import Strand

@MainActor
final class HealthSyncRefreshCoordinatorTests: XCTestCase {
    func testRefreshRunsAfterSuccessfulHealthKitSyncAndReceivesSuccess() async {
        var events: [String] = []

        await HealthSyncRefreshCoordinator.run(
            sync: { events.append("sync"); return true },
            refresh: { succeeded in events.append("refresh:\(succeeded)") }
        )

        XCTAssertEqual(events, ["sync", "refresh:true"])
    }

    func testRefreshStillRunsAfterFailedHealthKitSyncAndReceivesFailure() async {
        var events: [String] = []

        await HealthSyncRefreshCoordinator.run(
            sync: { events.append("sync"); return false },
            refresh: { succeeded in events.append("refresh:\(succeeded)") }
        )

        XCTAssertEqual(events, ["sync", "refresh:false"])
    }
}
