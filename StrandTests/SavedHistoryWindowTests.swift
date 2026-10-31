import GRDB
import XCTest
import WhoopStore
@testable import Strand

/// Real disposable SQLite reads through Repository, with no BLE or HealthKit dependency.
final class SavedHistoryWindowTests: XCTestCase {
    private func row(daysAgo: Int, recovery: Double = 75) -> DailyMetric {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return DailyMetric(day: Repository.localDayKey(date), totalSleepMin: 420,
                           efficiency: 0.9, deepMin: 90, remMin: 100, lightMin: 230,
                           disturbances: 2, restingHr: 52, avgHrv: 70,
                           recovery: recovery, strain: 8, exerciseCount: 1)
    }

    @MainActor
    func testRecentStartupThenFullHistorySurvivesSyncRefresh() async throws {
        let store = try await WhoopStore.inMemory()
        let recent = row(daysAgo: 1)
        let old = row(daysAgo: 365)
        _ = try await store.upsertDailyMetrics([recent, old], deviceId: "my-whoop")
        let repo = Repository(deviceId: "whoop-readded")
        repo.setStoreForTesting(store)
        XCTAssertFalse(repo.loaded)
        XCTAssertEqual(repo.refreshSeq, 0)

        await repo.refresh(days: 120)
        XCTAssertTrue(repo.loaded)
        XCTAssertEqual(repo.days, [recent], "First publication remains bounded")
        XCTAssertEqual(repo.refreshSeq, 1, "First publication wakes deferred cards")

        await repo.refresh()
        XCTAssertEqual(Set(repo.days.map(\.day)), Set([recent.day, old.day]))
        let fullSequence = repo.refreshSeq
        await repo.refresh(days: 120)
        XCTAssertEqual(Set(repo.days.map(\.day)), Set([recent.day, old.day]))
        XCTAssertEqual(repo.refreshSeq, fullSequence, "Unchanged sync must not restart cards")

        let updated = row(daysAgo: 1, recovery: 82)
        _ = try await store.upsertDailyMetrics([updated], deviceId: "my-whoop")
        await repo.refresh(days: 120)
        XCTAssertEqual(repo.days.first(where: { $0.day == updated.day }), updated)
        XCTAssertTrue(repo.days.contains(old))
        XCTAssertEqual(repo.refreshSeq, fullSequence + 1, "Changed data must still refresh cards")
    }

    @MainActor
    func testFirstReadFailureIsNotAnEmptyPublicationAndCanRetry() async throws {
        let store = try await WhoopStore.inMemory()
        let saved = row(daysAgo: 1)
        _ = try await store.upsertDailyMetrics([saved], deviceId: "my-whoop-noop")
        let repo = Repository(deviceId: "whoop-readded")
        repo.setStoreForTesting(store)
        // Rename only this disposable fixture's table to force a real query failure.
        try await store.registryWriter.write { db in
            try db.execute(sql: "ALTER TABLE dailyMetric RENAME TO unavailableDailyMetric")
        }
        await repo.refresh(days: 120)
        XCTAssertFalse(repo.loaded)
        XCTAssertTrue(repo.savedCacheUnavailable)
        XCTAssertEqual(repo.refreshSeq, 0)
        try await store.registryWriter.write { db in
            try db.execute(sql: "ALTER TABLE unavailableDailyMetric RENAME TO dailyMetric")
        }
        await repo.refresh(days: 120)
        XCTAssertTrue(repo.loaded)
        XCTAssertFalse(repo.savedCacheUnavailable)
        XCTAssertEqual(repo.days, [saved])
        XCTAssertEqual(repo.refreshSeq, 1)
    }

    @MainActor
    func testSuccessfulEmptyStorePublishesOnce() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        await repo.refresh(days: 120)
        XCTAssertTrue(repo.loaded)
        XCTAssertTrue(repo.days.isEmpty)
        XCTAssertEqual(repo.refreshSeq, 1)
        await repo.refresh(days: 120)
        XCTAssertEqual(repo.refreshSeq, 1)
    }
}
