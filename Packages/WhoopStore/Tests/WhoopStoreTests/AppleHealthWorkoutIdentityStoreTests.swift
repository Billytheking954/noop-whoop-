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
            // Same timestamp, different sport: must survive because the UUID ledger resolves the full
            // natural key rather than deleting every row that overlaps the time window.
            try self.seedWorkout(db, deviceId: "apple-health", startTs: 1_000,
                            sport: "Cycling", source: "apple-health")
            // Same natural key under another source device: must also survive.
            try self.seedWorkout(db, deviceId: "my-whoop", startTs: 1_000,
                            sport: "Running", source: "whoop")
        }

        let identity = AppleHealthWorkoutIdentity(
            uuid: "workout-uuid-1", startTs: 1_000, sport: "Running", day: "1970-01-01")
        _ = try await store.reconcileAppleHealthWorkoutIdentityDelta(
            added: [identity], deletedUUIDs: [],
            deviceId: "apple-health", workoutSource: "apple-health")

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
        _ = try await store.reconcileAppleHealthWorkoutIdentityDelta(
            added: [], deletedUUIDs: ["workout-uuid-2"],
            deviceId: "apple-health", workoutSource: "apple-health")
        let replayed = try await store.reconcileAppleHealthWorkoutIdentityDelta(
            added: [], deletedUUIDs: ["workout-uuid-2"],
            deviceId: "apple-health", workoutSource: "apple-health")
        XCTAssertEqual(replayed, 0)
        let remains = try await db.read {
            try self.countWorkout($0, deviceId: "apple-health", startTs: 2_000,
                             sport: "Hiking", source: "apple-health")
        }
        XCTAssertEqual(remains, 0)
    }

    func testIdentityUpsertIsIdempotentAndRefreshesTheNaturalKey() async throws {
        let store = try await WhoopStore.inMemory()
        let first = AppleHealthWorkoutIdentity(
            uuid: "workout-uuid-3", startTs: 3_000, sport: "Running", day: "1970-01-01")
        let corrected = AppleHealthWorkoutIdentity(
            uuid: "workout-uuid-3", startTs: 3_100, sport: "Running", day: "1970-01-01")
        _ = try await store.reconcileAppleHealthWorkoutIdentityDelta(
            added: [first], deletedUUIDs: [],
            deviceId: "apple-health", workoutSource: "apple-health")
        _ = try await store.reconcileAppleHealthWorkoutIdentityDelta(
            added: [corrected, corrected], deletedUUIDs: [],
            deviceId: "apple-health", workoutSource: "apple-health")
        let identities = try await store.registryWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT uuid, startTs, sport FROM appleHealthWorkoutIdentity
                WHERE deviceId = 'apple-health'
                """)
        }
        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities.first?["uuid"] as String?, "workout-uuid-3")
        XCTAssertEqual(identities.first?["startTs"] as Int?, 3_100)
        XCTAssertEqual(identities.first?["sport"] as String?, "Running")
    }
}
