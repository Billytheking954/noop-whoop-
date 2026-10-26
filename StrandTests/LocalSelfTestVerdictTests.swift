import XCTest
@testable import Strand

/// Pure local-history verdict guards. The self-test must never claim a blank
/// dashboard proves the database lost records, or pass while still loading.
@MainActor
final class LocalSelfTestVerdictTests: XCTestCase {
    func testStoredRecentRowsButEmptyLoadedCacheNeedsInvestigation() {
        XCTAssertEqual(LocalSelfTest.cacheVerdict(persistedDays: ["2026-10-23", "2026-10-24"], cachedDays: [],
                                                   cacheLoaded: true),
                       .storedDaysNotInCache)
    }

    func testUnfinishedInitialLoadIsInconclusive() {
        XCTAssertEqual(LocalSelfTest.cacheVerdict(persistedDays: ["2026-10-23", "2026-10-24"], cachedDays: [],
                                                   cacheLoaded: false),
                       .inconclusive)
    }

    func testFailedStorageReadIsInconclusiveRatherThanNoData() {
        XCTAssertEqual(LocalSelfTest.cacheVerdict(persistedDays: nil, cachedDays: [],
                                                   cacheLoaded: true),
                       .inconclusive)
    }

    func testEmptyInstallIsNotMisreportedAsDataLoss() {
        XCTAssertEqual(LocalSelfTest.cacheVerdict(persistedDays: [], cachedDays: [],
                                                   cacheLoaded: true),
                       .present)
    }

    func testPopulatedCacheWithPopulatedStoreIsConsistent() {
        XCTAssertEqual(LocalSelfTest.cacheVerdict(persistedDays: ["2026-10-23", "2026-10-24"], cachedDays: ["2026-10-23", "2026-10-24", "2026-10-25"],
                                                   cacheLoaded: true),
                       .present)
    }

    func testSomeStoredDaysAbsentFromLoadedCacheNeedsInvestigation() {
        XCTAssertEqual(LocalSelfTest.cacheVerdict(persistedDays: ["2026-10-22", "2026-10-23"],
                                                   cachedDays: ["2026-10-22"], cacheLoaded: true),
                       .storedDaysNotInCache)
    }

    func testEqualCountsButDifferentDayKeysStillFail() {
        XCTAssertEqual(LocalSelfTest.cacheVerdict(persistedDays: ["2026-10-22"],
                                                   cachedDays: ["2026-10-23"], cacheLoaded: true),
                       .storedDaysNotInCache)
    }

    func testUnmatchedCacheSourceDoesNotProduceFalsePass() {
        XCTAssertEqual(LocalSelfTest.cacheVerdict(persistedDays: [], cachedDays: ["2026-10-22", "2026-10-23"],
                                                   cacheLoaded: true),
                       .inconclusive)
    }
}
