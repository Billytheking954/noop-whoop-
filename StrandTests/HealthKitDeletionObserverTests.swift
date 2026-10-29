#if os(iOS)
import XCTest
import Foundation
@testable import Strand

/// Pins the safe observer behaviour: deletion-only wakes trigger a bounded reread, but do not pretend
/// that a reread of aggregate data provides enough identity to delete a cached source row.
final class HealthKitDeletionObserverTests: XCTestCase {
    func testDeletionOnlyWakeUsesBoundedHorizon() {
        let oldSample = Date(timeIntervalSince1970: 1_600_000_000)
        let horizon = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            HealthKitBridge.observerTouchedDate(oldestAdded: oldSample,
                                                 hadDeletions: true,
                                                 deletionHorizon: horizon),
            horizon
        )
    }

    func testAdditionWithoutDeletionKeepsOldestAddedDate() {
        let oldSample = Date(timeIntervalSince1970: 1_600_000_000)
        let horizon = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            HealthKitBridge.observerTouchedDate(oldestAdded: oldSample,
                                                 hadDeletions: false,
                                                 deletionHorizon: horizon),
            oldSample
        )
    }

    func testEmptyWakeDoesNotInventTouchedDate() {
        let horizon = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertNil(
            HealthKitBridge.observerTouchedDate(oldestAdded: nil,
                                                 hadDeletions: false,
                                                 deletionHorizon: horizon)
        )
    }
}
#endif
