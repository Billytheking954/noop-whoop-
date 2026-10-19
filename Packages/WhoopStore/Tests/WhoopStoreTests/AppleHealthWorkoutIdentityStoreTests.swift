import XCTest
import GRDB
@testable import WhoopStore

final class AppleHealthWorkoutIdentityStoreTests: XCTestCase {
    private func seedWorkout(_ db: Database, deviceId: String, startTs: Int,
                             sport: String, source: String) throws {
        try db.execute(
            sql: """
                INSERT INTO workout (deviceId, startTs, endTs, sport, source)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [deviceId, startTs, startTs + 600, sport, source]
        )
    }

    private func countWorkout(_ db: Database, deviceId: String, startTs: Int,
                              sport: String, source: String) throws -> Int {
        try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM workout
                WHERE deviceId = ? AND startTs = ? AND sport = ? AND source = ?
                """,
            arguments: [deviceId, startTs, sport, source]
        ) ?? 0
    }

    func testDeletedUUIDRemovesOnlyExactAppleHealthWorkoutRow() async throws {
        let store = try await WhoopStore.inMemory()
        let db = store.registryWriter
        try await db.write { db in
            try self.seedWorkout(db, deviceId: "apple-health", startTs: 1_000,
                                 sport: "Running", source: "apple-health")
            // Same timestamp, different sport must survive an exact-identity tombstone.
            try self.seedWorkout(db, deviceId: "apple-health", startTs: 1_000,
                                 sport: "Cycling", source: "apple-health")
            // A matching natural key from another device/source must survive too.
            try self.seedWorkout(db, deviceId: "my-whoop", startTs: 1_000,
                                 sport: "Running", source: "whoop")
        }

        _ = try await store.reconcileAppleHealthWorkoutIdentityDelta(
            added: [AppleHealthWorkoutIdentity(uuid: "workout-uuid-1", startTs: 1_000,
                                               sport: "Running", day: "1970-01-01")],
            deletedUUIDs: [], deviceId: "apple-health", workoutSource: "apple-health")

        let removed = try await store.reconcileAppleHealthWorkoutIdentityDelta(
            added: [], deletedUUIDs: ["workout-uuid-1"],
            deviceId: "apple-health", workoutSource: "apple-health")
        XCTAssertEqual(removed, 1)

        let counts = try await db.read { db in
            (
                try self.countWorkout(db, deviceId: "apple-health", startTs: 1_000,
                                      sport: "Running", source: "apple-health"),
                try self.countWorkout(db, deviceId: "apple-health", startTs: 1_000,
                                      sport: "Cycling", source: "apple-health"),
                try self.countWorkout(db, deviceId: "my-whoop", startTs: 1_000,
                                      sport: "Running", source: "whoop")
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(counts.2, 1)
    }

    func testRepeatedDeletionTombstoneIsIdempotent() async throws {
        let store = try await WhoopStore.inMemory()
        let db = store.registryWriter
        try await db.write { db in
            try self.seedWorkout(db, deviceId: "apple-health", startTs: 2_000,
                                 sport: "Hiking", source: "apple-health")
        }
        _ = try await store.reconcileAppleHealthWorkoutIdentityDelta(
            added: [AppleHealthWorkoutIdentity(uuid: "workout-uuid-2", startTs: 2_000,
                                               sport: "Hiking", day: "1970-01-01")],
            deletedUUIDs: [], deviceId: "apple-health", workoutSource: "apple-health")

        let first = try await store.reconcileAppleHealthWorkoutIdentityDelta(
            added: [], deletedUUIDs: ["workout-uuid-2"],
            deviceId: "apple-health", workoutSource: "apple-health")
        let replayed = try await store.reconcileAppleHealthWorkoutIdentityDelta(
            added: [], deletedUUIDs: ["workout-uuid-2"],
            deviceId: "apple-health", workoutSource: "apple-health")
        XCTAssertEqual(first, 1)
        XCTAssertEqual(replayed, 0)

        let remains = try await db.read {
            try self.countWorkout($0, deviceId: "apple-health", startTs: 2_000,
                                  sport: "Hiking", source: "apple-health")
        }
        XCTAssertEqual(remains, 0)
    }

    func testCorrectedIdentityRetainsSharedOldKeyUntilLastOwnerIsRemoved() async throws {
        let store = try await WhoopStore.inMemory()
        let db = store.registryWriter
        try await db.write { db in
            try self.seedWorkout(db, deviceId: "apple-health", startTs: 3_000,
                                 sport: "Running", source: "apple-health")
            try self.seedWorkout(db, deviceId: "apple-health", startTs: 3_100,
                                 sport: "Running", source: "apple-health")
        }

        let first = AppleHealthWorkoutIdentity(uuid: "workout-uuid-3", startTs: 3_000,
                                               sport: "Running", day: "1970-01-01")
        let shared = AppleHealthWorkoutIdentity(uuid: "workout-uuid-4", startTs: 3_000,
                                                sport: "Running", day: "1970-01-01")
        let corrected = AppleHealthWorkoutIdentity(uuid: "workout-uuid-3", startTs: 3_100,
                                                   sport: "Running", day: "1970-01-01")
        _ = try await store.reconcileAppleHealthWorkoutIdentityDelta(
            added: [first, shared], deletedUUIDs: [],
            deviceId: "apple-health", workoutSource: "apple-health")

        // A HealthKit correction changes the UUID's natural key. It must not strand the old row if
        // another UUID still maps to that row.
        let moved = try await store.reconcileAppleHealthWorkoutIdentityDelta(
            added: [corrected, corrected], deletedUUIDs: [],
            deviceId: "apple-health", workoutSource: "apple-health")
        XCTAssertEqual(moved, 0)
        var counts = try await db.read { db in
            (
                try self.countWorkout(db, deviceId: "apple-health", startTs: 3_000,
                                      sport: "Running", source: "apple-health"),
                try self.countWorkout(db, deviceId: "apple-health", startTs: 3_100,
                                      sport: "Running", source: "apple-health")
            )
        }
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)

        let removedOld = try await store.reconcileAppleHealthWorkoutIdentityDelta(
            added: [], deletedUUIDs: ["workout-uuid-4"],
            deviceId: "apple-health", workoutSource: "apple-health")
        XCTAssertEqual(removedOld, 1)

        let removedNew = try await store.reconcileAppleHealthWorkoutIdentityDelta(
            added: [], deletedUUIDs: ["workout-uuid-3"],
            deviceId: "apple-health", workoutSource: "apple-health")
        XCTAssertEqual(removedNew, 1)
        counts = try await db.read { db in
            (
                try self.countWorkout(db, deviceId: "apple-health", startTs: 3_000,
                                      sport: "Running", source: "apple-health"),
                try self.countWorkout(db, deviceId: "apple-health", startTs: 3_100,
                                      sport: "Running", source: "apple-health")
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
    }
}
