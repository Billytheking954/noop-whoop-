import Foundation
import GRDB

/// Durable mapping from a HealthKit workout UUID to the exact row key used by NOOP.
/// Unlike daily aggregates, a deleted workout's identity can be reconciled precisely and safely.
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
    /// Applies one successful anchored-query delta atomically with respect to the identity ledger and
    /// the canonical workout rows. Replaying the same delta is safe: inserts are idempotent, deletes
    /// are idempotent, and the HealthKit anchor is advanced by the caller only after this transaction
    /// succeeds. A failed transaction leaves the previous identity mapping intact for retry.
    @discardableResult
    public func reconcileAppleHealthWorkoutIdentityDelta(
        added: [AppleHealthWorkoutIdentity],
        deletedUUIDs: [String],
        deviceId: String,
        workoutSource: String
    ) async throws -> Int {
        try syncWrite { db in
            for identity in added {
                try db.execute(sql: """
                    INSERT INTO appleHealthWorkoutIdentity (deviceId, uuid, startTs, sport, day)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, uuid) DO UPDATE SET
                        startTs = excluded.startTs,
                        sport   = excluded.sport,
                        day     = excluded.day
                    """, arguments: [deviceId, identity.uuid, identity.startTs,
                                     identity.sport, identity.day])
            }

            let uuids = Array(Set(deletedUUIDs)).sorted()
            guard !uuids.isEmpty else { return 0 }

            var deletedWorkoutRows = 0
            for uuid in uuids {
                let identity = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT startTs, sport
                        FROM appleHealthWorkoutIdentity
                        WHERE deviceId = ? AND uuid = ?
                        """,
                    arguments: [deviceId, uuid]
                )
                if let identity {
                    try db.execute(
                        sql: """
                            DELETE FROM workout
                            WHERE deviceId = ? AND startTs = ? AND sport = ? AND source = ?
                            """,
                        arguments: [deviceId, identity["startTs"] as Int,
                                    identity["sport"] as String, workoutSource]
                    )
                    deletedWorkoutRows += db.changesCount
                }

                // Only remove the mapping corresponding to this confirmed UUID tombstone.
                try db.execute(
                    sql: "DELETE FROM appleHealthWorkoutIdentity WHERE deviceId = ? AND uuid = ?",
                    arguments: [deviceId, uuid]
                )
            }
            return deletedWorkoutRows
        }
    }
}
