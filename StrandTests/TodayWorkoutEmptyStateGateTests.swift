import XCTest
@testable import Strand

final class TodayWorkoutEmptyStateGateTests: XCTestCase {
    func testRepositoryLoadedBeforeWorkoutHistoryDoesNotClaimNoActivities() {
        XCTAssertFalse(TodayWorkoutEmptyStateGate.canShowEmpty(
            repositoryLoaded: true, workoutHistoryLoaded: false))
    }

    func testBothStoresMustBeReadyBeforeEmptyStateIsShown() {
        XCTAssertFalse(TodayWorkoutEmptyStateGate.canShowEmpty(
            repositoryLoaded: false, workoutHistoryLoaded: true))
        XCTAssertFalse(TodayWorkoutEmptyStateGate.canShowEmpty(
            repositoryLoaded: false, workoutHistoryLoaded: false))
        XCTAssertTrue(TodayWorkoutEmptyStateGate.canShowEmpty(
            repositoryLoaded: true, workoutHistoryLoaded: true))
    }
}
