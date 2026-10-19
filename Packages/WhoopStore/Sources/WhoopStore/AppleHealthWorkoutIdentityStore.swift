import Foundation
import GRDB

/// Durable mapping from a HealthKit workout UUID to the exact row key used by NOOP.
/// The mapping lets a confirmed deletion remove only the row owned by that HealthKit object.
public struct AppleHealthWorkoutIdentity: Equatable, Sendable {
    public let uuid: String
    public let startTs: Int
    public let sport: String
    public let day: String

    public init(uuid: String, startTs: Int, sport: String, day: String) {
        self.uuid = uuid
        self.startTs = startTs
        self.sport = sport
        self.day = day
    }
}

extension WhoopStore {
    /// Applies one successful anchored-query delta atomically to the identity ledger and canonical workout
    /// rows. The caller advances the HealthKit anchor only after this transaction succeeds.
    ///
    /// A workout row's natural key is not one-to-one with a HealthKit UUID: two source workouts can share
    /// the same device/start/sport key. Therefore a correction or tombstone may remove an old canonical
    /// row only after no other UUID mapping still references that key. Replaying a delta is idempotent.
    @discardableResult
    public func reconcileAppleHealthWorkoutIdentityDelta(
        added: [AppleHealthWorkoutIdentity],
        deletedUUIDs: [String],
        deviceId: String,
        workoutSource: String
    ) async throws -> Int {
        try syncWrite { db in
            var deletedWorkoutRows = 0

            for identity in added {
                let previous = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT startTs, sport
                        FROM appleHealthWorkoutIdentity
                        WHERE deviceId = ? AND uuid = ?
                        """,
                    arguments: [deviceId, identity.uuid]
                )
                let previousStart = previous?["startTs"] as Int?
                let previousSport = previous?["sport"] as String?
                let keyChanged = previousStart != nil &&
                    (previousStart != identity.startTs || previousSport != identity.sport)

                try db.execute(sql: """
                    INSERT INTO appleHealthWorkoutIdentity (deviceId, uuid, startTs, sport, day)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, uuid) DO UPDATE SET
                        startTs = excluded.startTs,
                        sport   = excluded.sport,
                        day     = excluded.day
                    """, arguments: [deviceId, identity.uuid, identity.startTs,
                                     identity.sport, identity.day])

                // The new mapping is now in place inside this same transaction. Only delete the old
                // canonical row if another HealthKit UUID does not still own its natural key.
                if keyChanged, let previousStart, let previousSport {
                    let owners = try identityOwnerCount(
                        db, deviceId: deviceId, startTs: previousStart, sport: previousSport)
                    if owners == 0 {
                        try db.execute(
                            sql: """
                                DELETE FROM workout
                                WHERE deviceId = ? AND startTs = ? AND sport = ? AND source = ?
                                """,
                            arguments: [deviceId, previousStart, previousSport, workoutSource]
                        )
                        deletedWorkoutRows += db.changesCount
                    }
                }
            }

            for uuid in Set(deletedUUIDs).sorted() {
                let identity = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT startTs, sport
                        FROM appleHealthWorkoutIdentity
                        WHERE deviceId = ? AND uuid = ?
                        """,
                    arguments: [deviceId, uuid]
                )
                // A missing identity is not authority to delete a guessed row.
                try db.execute(
                    sql: "DELETE FROM appleHealthWorkoutIdentity WHERE deviceId = ? AND uuid = ?",
                    arguments: [deviceId, uuid]
                )

                if let identity {
                    let startTs = identity["startTs"] as Int
                    let sport = identity["sport"] as String
                    let owners = try identityOwnerCount(db, deviceId: deviceId,
                                                        startTs: startTs, sport: sport)
                    if owners == 0 {
                        try db.execute(
                            sql: """
                                DELETE FROM workout
                                WHERE deviceId = ? AND startTs = ? AND sport = ? AND source = ?
                                """,
                            arguments: [deviceId, startTs, sport, workoutSource]
                        )
                        deletedWorkoutRows += db.changesCount
                    }
                }
            }
            return deletedWorkoutRows
        }
    }

    private func identityOwnerCount(_ db: Database, deviceId: String,
                                    startTs: Int, sport: String) throws -> Int {
        try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM appleHealthWorkoutIdentity
                WHERE deviceId = ? AND startTs = ? AND sport = ?
                """,
            arguments: [deviceId, startTs, sport]
        ) ?? 0
    }
}
