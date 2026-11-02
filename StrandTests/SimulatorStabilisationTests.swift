import GRDB
import XCTest
import WhoopStore
@testable import Strand

/// Synthetic stores only: no app database, HealthKit, pairing or BLE is accessed.
@MainActor
final class SimulatorStabilisationTests: XCTestCase {
    func testHistoricalSleepAndActivityUseTheSelectedDay() async throws {
        let store = try await WhoopStore.inMemory()
        try await AppleDemoSeeder.seed(into: store, days: 400)
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        await repo.refresh()
        let date = Calendar.current.date(byAdding: .day, value: -365, to: Date())!
        let day = Repository.localDayKey(date)
        let sessions = await repo.allSleepSessions()
        let inputs = SleepModelInputs(days: repo.days, sleeps: repo.sleeps,
                                      allSessions: sessions, importedSleep: repo.importedSleep,
                                      habitualMidsleepSec: nil, motionByStart: [:])
        let selected = try XCTUnwrap(SleepView.routedInputs(inputs, day: day))
        let night = try XCTUnwrap(SleepModel.build(selected)?.night)
        XCTAssertEqual(Repository.localDayKey(Date(timeIntervalSince1970: Double(night.session.endTs))), day)
        XCTAssertLessThan(night.session.effectiveStartTs, night.session.endTs)
        XCTAssertTrue(selected.days.allSatisfy { $0.day <= day })
        XCTAssertEqual(SleepView.routedInputs(inputs, day: nil)?.days, inputs.days)
        XCTAssertNil(SleepView.routedInputs(inputs, day: "1900-01-01"), "A missing date must never fall through to the latest night")

        func workout(_ date: Date) -> WorkoutRow {
            let start = Int(date.timeIntervalSince1970)
            return WorkoutRow(startTs: start, endTs: start + 1800, sport: "Running", source: "whoop",
                              durationS: 1800, energyKcal: nil, avgHr: nil, maxHr: nil,
                              strain: nil, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
        }
        let historical = workout(date)
        let recent = workout(Date())
        XCTAssertEqual(TodayView.workouts(on: day, from: [recent, historical]), [historical])
        XCTAssertTrue(TodayView.workouts(on: "1900-01-01", from: [recent, historical]).isEmpty)
    }

    func testFourHundredDayFixtureIsDeterministic() async throws {
        let now = Date(timeIntervalSince1970: 1_793_534_400) // Fixed reference, including older history.
        let first = try await WhoopStore.inMemory()
        let second = try await WhoopStore.inMemory()
        try await AppleDemoSeeder.seed(into: first, days: 400, now: now)
        try await AppleDemoSeeder.seed(into: second, days: 400, now: now)
        let a = try await first.dailyMetrics(deviceId: "my-whoop", from: "0000-00-00", to: "9999-99-99")
        let b = try await second.dailyMetrics(deviceId: "my-whoop", from: "0000-00-00", to: "9999-99-99")
        XCTAssertEqual(a.count, 400)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.allSatisfy { $0.recovery != nil && $0.avgHrv != nil && $0.spo2Pct == nil })
        let workoutsA = try await first.workouts(deviceId: "my-whoop", from: 0, to: Int.max, limit: 2000)
        let workoutsB = try await second.workouts(deviceId: "my-whoop", from: 0, to: Int.max, limit: 2000)
        XCTAssertFalse(workoutsA.isEmpty)
        XCTAssertEqual(workoutsA, workoutsB)
        // Replaying a completed synthetic import must not duplicate persisted workouts.
        _ = try await first.upsertWorkouts(workoutsA, deviceId: "my-whoop")
        let replayed = try await first.workouts(deviceId: "my-whoop", from: 0, to: Int.max, limit: 2000)
        XCTAssertEqual(replayed, workoutsA)
    }

    func testFileStoreSurvivesInterruptedRefreshTransactionAndReopen() async throws {
        enum Interrupted: Error { case refresh }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("synthetic.sqlite").path
        let store = try await WhoopStore(path: path)
        try await AppleDemoSeeder.seed(into: store, days: 400)
        let before = try await store.dailyMetrics(deviceId: "my-whoop", from: "0000-00-00", to: "9999-99-99")
        do {
            try await store.registryWriter.write { db in
                try db.execute(sql: "UPDATE dailyMetric SET recovery = 1 WHERE deviceId = 'my-whoop'")
                throw Interrupted.refresh
            }
            XCTFail("Interrupted transaction must throw")
        } catch Interrupted.refresh { }
        // A fresh pool reads durable committed WAL state, without checkpoint/reset/copying live files.
        let reopened = try await WhoopStore(path: path)
        let after = try await reopened.dailyMetrics(deviceId: "my-whoop", from: "0000-00-00", to: "9999-99-99")
        XCTAssertEqual(after, before)
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 49)
        let integrity = try await reopened.registryWriter.read { db in
            try String.fetchOne(db, sql: "PRAGMA integrity_check")
        }
        XCTAssertEqual(integrity, "ok")
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(reopened)
        await repo.refresh(days: 120)
        XCTAssertTrue(repo.loaded)
        XCTAssertGreaterThanOrEqual(repo.days.count, 120)
        XCTAssertLessThan(repo.days.count, 400)
        await repo.refresh()
        XCTAssertEqual(repo.days.count, 400)
    }

    func testCancellingOneWaiterDoesNotPoisonSharedRefresh() async throws {
        let store = try await WhoopStore.inMemory()
        try await AppleDemoSeeder.seed(into: store, days: 400)
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        let entered = expectation(description: "suspended before read")
        var resume: CheckedContinuation<Void, Never>?
        repo.beforeRefreshReadForTesting = {
            repo.beforeRefreshReadForTesting = nil
            await withCheckedContinuation { continuation in
                resume = continuation
                entered.fulfill()
            }
        }
        let cancelled = Task { await repo.refresh(days: 120) }
        await fulfillment(of: [entered], timeout: 10)
        cancelled.cancel()
        let joined = expectation(description: "surviving waiter joined")
        repo.onRefreshRequestForTesting = { joined.fulfill() }
        let survivor = Task { await repo.refresh() }
        await fulfillment(of: [joined], timeout: 10)
        repo.onRefreshRequestForTesting = nil
        resume?.resume()
        await cancelled.value
        await survivor.value
        XCTAssertEqual(repo.days.count, 400)
        XCTAssertEqual(repo.refreshSeq, 1)
        XCTAssertEqual(repo.refreshReadPassesForTesting, 2)
        XCTAssertFalse(repo.savedCacheUnavailable)
        await repo.refresh(days: 120)
        XCTAssertEqual(repo.refreshSeq, 1)
    }
}
