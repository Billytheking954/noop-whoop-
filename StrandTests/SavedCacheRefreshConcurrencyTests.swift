import XCTest
import WhoopStore
@testable import Strand

@MainActor
final class SavedCacheRefreshConcurrencyTests: XCTestCase {
    private func metric(_ day: String, recovery: Double) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil,
                    remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil,
                    avgHrv: nil, recovery: recovery, strain: nil, exerciseCount: nil)
    }

    func testOverlappingRequestsShareAReaderAndRetainFullHistory() async throws {
        let store = try await WhoopStore.inMemory()
        let recent = metric(Repository.localDayKey(Date()), recovery: 70)
        let oldDate = Calendar.current.date(byAdding: .day, value: -365, to: Date())!
        let old = metric(Repository.localDayKey(oldDate), recovery: 65)
        _ = try await store.upsertDailyMetrics([recent, old], deviceId: "my-whoop")
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        var resumeRead: CheckedContinuation<Void, Never>?
        let entered = expectation(description: "first reader suspended")
        repo.beforeRefreshReadForTesting = {
            repo.beforeRefreshReadForTesting = nil
            await withCheckedContinuation { continuation in
                resumeRead = continuation
                entered.fulfill()
            }
        }
        let first = Task { await repo.refresh(days: 120) }
        await fulfillment(of: [entered], timeout: 5)
        // Queue all requests while the reader is suspended. They must neither
        // publish a partial snapshot nor start another set of SQL reads.
        let joined = expectation(description: "all trailing requests joined")
        joined.expectedFulfillmentCount = 8
        repo.onRefreshRequestForTesting = { joined.fulfill() }
        let followers = (0..<8).map { index in
            Task { await repo.refresh(days: index == 0 ? 4000 : 120) }
        }
        await fulfillment(of: [joined], timeout: 5)
        repo.onRefreshRequestForTesting = nil
        XCTAssertEqual(repo.refreshReadPassesForTesting, 1)
        resumeRead?.resume()
        await first.value
        for follower in followers { await follower.value }
        XCTAssertEqual(Set(repo.days.map(\.day)), Set([recent.day, old.day]))
        XCTAssertEqual(repo.refreshReadPassesForTesting, 2)
        XCTAssertEqual(repo.refreshSeq, 1, "Only the complete trailing snapshot publishes")
    }

    func testDeviceChangeInvalidatesSuspendedRead() async throws {
        let store = try await WhoopStore.inMemory()
        let day = Repository.localDayKey(Date())
        let previous = metric(day, recovery: 30)
        let current = metric(day, recovery: 80)
        _ = try await store.upsertDailyMetrics([previous], deviceId: "whoop-old")
        _ = try await store.upsertDailyMetrics([current], deviceId: "whoop-new")
        let repo = Repository(deviceId: "whoop-old")
        repo.setStoreForTesting(store)
        repo.beforeRefreshReadForTesting = {
            repo.beforeRefreshReadForTesting = nil
            repo.adoptActiveDeviceId("whoop-new")
        }
        await repo.refresh(days: 120)
        XCTAssertEqual(repo.days, [current])
        XCTAssertEqual(repo.refreshSeq, 1)
        XCTAssertEqual(repo.refreshReadPassesForTesting, 2)
    }
}
