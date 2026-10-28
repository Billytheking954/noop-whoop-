import GRDB
import XCTest
import WhoopStore
@testable import Strand

/// Disposable in-memory fixture: a failed query must never erase a previously
/// published dashboard snapshot or claim that the database contains no days.
final class SavedHistoryRefreshFailureTests: XCTestCase {
    @MainActor
    func testReadFailureRetainsLastGoodSavedHistory() async throws {
        let store = try await WhoopStore.inMemory()
        let day = Repository.localDayKey(Date())
        let saved = DailyMetric(day: day, totalSleepMin: 420, efficiency: 0.9,
                                deepMin: 90, remMin: 100, lightMin: 230,
                                disturbances: 2, restingHr: 52, avgHrv: 70,
                                recovery: 75, strain: 8, exerciseCount: 1)
        _ = try await store.upsertDailyMetrics([saved], deviceId: "my-whoop")
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        await repo.refresh(days: 120)
        XCTAssertEqual(repo.days, [saved])
        let publishedSequence = repo.refreshSeq

        // Simulate a failed required read without touching any user database.
        // The previous implementation converted this error into [] and
        // published an empty dashboard despite a good cached snapshot.
        try await store.registryWriter.write { db in
            try db.execute(sql: "DROP TABLE dailyMetric")
        }
        await repo.refresh(days: 120)
        XCTAssertEqual(repo.days, [saved])
        XCTAssertTrue(repo.loaded)
        XCTAssertEqual(repo.refreshSeq, publishedSequence)
    }
}
