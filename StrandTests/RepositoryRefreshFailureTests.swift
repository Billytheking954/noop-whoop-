import XCTest
import GRDB
import WhoopStore
#if os(iOS)
@testable import NOOPiOS
#else
@testable import Strand
#endif

final class RepositoryRefreshFailureTests: XCTestCase {
    @MainActor func testFailedReadKeepsLastGoodHistoryAndSuccessfulRetryClearsError() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "test", store: store)
        let day = Repository.dayString(Date())
        let row = DailyMetric(day: day, totalSleepMin: 420, efficiency: nil, deepMin: nil,
                              remMin: nil, lightMin: nil, disturbances: nil, restingHr: 54,
                              avgHrv: 61, recovery: nil, strain: nil, exerciseCount: nil)
        try await store.upsertDailyMetrics([row], deviceId: "test")
        await repo.refresh()
        XCTAssertEqual(repo.days, [row])
        let sequence = repo.refreshSeq
        // Rename a real input table to provoke an actual SQLite read failure.
        try await store.registryWriter.write { db in try db.execute(sql: "ALTER TABLE dailyMetric RENAME TO unavailableDailyMetric") }
        await repo.refresh()
        XCTAssertEqual(repo.days, [row])
        XCTAssertEqual(repo.refreshSeq, sequence)
        XCTAssertNotNil(repo.lastRefreshError)
        try await store.registryWriter.write { db in try db.execute(sql: "ALTER TABLE unavailableDailyMetric RENAME TO dailyMetric") }
        await repo.refresh()
        XCTAssertEqual(repo.days, [row])
        XCTAssertNil(repo.lastRefreshError)
    }
}
