import GRDB
import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

@MainActor
final class SuggestedWorkoutPersistenceTests: XCTestCase {
    func testWriteFailureDoesNotClaimSuccessAndRetryPreservesExactEnd() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        let start = Int(Date().timeIntervalSince1970) - 7_200
        let candidate = DetectedWorkout(startSec: start, endSec: start + 917,
                                        avgBpm: 130, peakBpm: 160, durationMin: 15)
        try await store.registryWriter.write { db in
            try db.execute(sql: "ALTER TABLE workout RENAME TO unavailableWorkout")
        }
        let failed = await repo.saveDetectedWorkout(candidate)
        XCTAssertFalse(failed, "The card must remain retryable on a failed SQLite write")
        try await store.registryWriter.write { db in
            try db.execute(sql: "ALTER TABLE unavailableWorkout RENAME TO workout")
        }
        let retried = await repo.saveDetectedWorkout(candidate)
        XCTAssertTrue(retried)
        let rows = try await store.workouts(deviceId: "my-whoop", from: start, to: start + 2_000, limit: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.endTs, candidate.endSec)
        XCTAssertEqual(rows.first?.durationS, 917)
        let repeated = await repo.saveDetectedWorkout(candidate)
        XCTAssertTrue(repeated, "A previously committed confirmation is already satisfied")
        let repeatedRows = try await store.workouts(deviceId: "my-whoop", from: start, to: start + 2_000, limit: 10)
        XCTAssertEqual(repeatedRows, rows)
    }

    func testFutureCandidateIsNotPersisted() async throws {
        let store = try await WhoopStore.inMemory()
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        let now = Int(Date().timeIntervalSince1970)
        let candidate = DetectedWorkout(startSec: now + 3_600, endSec: now + 4_517,
                                        avgBpm: 130, peakBpm: 160, durationMin: 15)
        let result = await repo.saveDetectedWorkout(candidate)
        XCTAssertFalse(result)
        let rows = try await store.workouts(deviceId: "my-whoop", from: 0, to: now + 10_000, limit: 10)
        XCTAssertTrue(rows.isEmpty)
    }

    func testDSTRepeatedHourUsesElapsedSecondsAndExactEndpoints() throws {
        let iso = ISO8601DateFormatter()
        let start = try XCTUnwrap(iso.date(from: "2026-10-25T00:50:00Z"))
        let end = try XCTUnwrap(iso.date(from: "2026-10-25T01:20:17Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        XCTAssertEqual(calendar.component(.hour, from: start), 1)
        XCTAssertEqual(calendar.component(.hour, from: end), 1)
        let row = try XCTUnwrap(WorkoutSource.buildManualRowFromSpan(
            start: start, end: end, sport: "Workout", avgHr: 130, energyKcal: nil,
            now: end.addingTimeInterval(1)))
        XCTAssertEqual(row.durationS, 1_817)
        XCTAssertEqual(row.startTs, Int(start.timeIntervalSince1970))
        XCTAssertEqual(row.endTs, Int(end.timeIntervalSince1970))
    }
}
