import XCTest
@testable import NOOPiOS

/// Pure local-history verdict guards. The self-test must never claim a blank
/// dashboard proves the database lost records, or pass while still loading.
@MainActor
final class LocalSelfTestVerdictTests: XCTestCase {
    func testStoredRecentRowsButEmptyLoadedCacheNeedsInvestigation() {
        XCTAssertEqual(LocalSelfTest.cacheVerdict(persistedDays: 5, cachedDays: 0,
                                                   cacheLoaded: true),
                       .storedDaysNotInCache)
    }

    func testUnfinishedInitialLoadIsInconclusive() {
        XCTAssertEqual(LocalSelfTest.cacheVerdict(persistedDays: 5, cachedDays: 0,
                                                   cacheLoaded: false),
                       .inconclusive)
    }

    func testFailedStorageReadIsInconclusiveRatherThanNoData() {
        XCTAssertEqual(LocalSelfTest.cacheVerdict(persistedDays: nil, cachedDays: 0,
                                                   cacheLoaded: true),
                       .inconclusive)
    }

    func testEmptyInstallIsNotMisreportedAsDataLoss() {
        XCTAssertEqual(LocalSelfTest.cacheVerdict(persistedDays: 0, cachedDays: 0,
                                                   cacheLoaded: true),
                       .present)
    }

    func testPopulatedCacheWithPopulatedStoreIsConsistent() {
        XCTAssertEqual(LocalSelfTest.cacheVerdict(persistedDays: 2, cachedDays: 3,
                                                   cacheLoaded: true),
                       .present)
    }

    func testUnmatchedCacheSourceDoesNotProduceFalsePass() {
        XCTAssertEqual(LocalSelfTest.cacheVerdict(persistedDays: 0, cachedDays: 3,
                                                   cacheLoaded: true),
                       .inconclusive)
    }
}
