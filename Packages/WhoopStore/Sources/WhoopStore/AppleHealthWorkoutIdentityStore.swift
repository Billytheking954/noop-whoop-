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

/// Durable identity for a low-volume HealthKit sample whose deletion must be reconciled to a day.
/// The day is assigned when the sample is observed, so a future HKDeletedObject (which contains only
/// UUID/type, not the original timestamp) can still target the exact cached day.
public struct AppleHealthSampleIdentity: Equatable, Sendable {
    public let typeIdentifier: String
    public let uuid: String
    public let day: String
    public let startTs: Int
    /// Sample value in canonical importer units (ml for water, mg for caffeine).
    public let value: Double?

    public init(typeIdentifier: String, uuid: String, day: String, startTs: Int, value: Double? = nil) {
        self.typeIdentifier = typeIdentifier
        self.uuid = uuid
        self.day = day
        self.startTs = startTs
        self.value = value
    }
}

extension WhoopStore {
    /// Find previously recorded day keys for confirmed tombstones before the read/sync pass runs.
    /// These days may be explicitly cleared only after the corresponding HealthKit reread succeeds.
    public func appleHealthSampleIdentityDays(
        deviceId: String,
        typeIdentifier: String,
        uuids: [String]
    ) throws -> Set<String> {
        let keys = Array(Set(uuids)).filter { !$0.isEmpty }.sorted()
        guard !keys.isEmpty else { return [] }
        return try syncRead { db in
            var days = Set<String>()
            for uuid in keys {
                if let day = try String.fetchOne(
                    db,
                    sql: """
                        SELECT day FROM appleHealthSampleIdentity
                        WHERE deviceId = ? AND typeIdentifier = ? AND uuid = ?
                        """,
                    arguments: [deviceId, typeIdentifier, uuid]
                ) {
                    days.insert(day)
                }
            }
            return days
        }
    }

    /// Read existing identity rows in bounded chunks, avoiding one SQLite query per sample on the
    /// first unbounded anchor backfill. Prior values let deletion reconciliation apply an exact delta
    /// when HealthKit no longer returns a daily aggregate.
    public func appleHealthSampleIdentities(
        deviceId: String,
        typeIdentifier: String,
        uuids: [String]
    ) throws -> [String: AppleHealthSampleIdentity] {
        let keys = Array(Set(uuids)).filter { !$0.isEmpty }.sorted()
        guard !keys.isEmpty else { return [:] }
        return try syncRead { db in
            var result: [String: AppleHealthSampleIdentity] = [:]
            for offset in stride(from: 0, to: keys.count, by: 400) {
                let chunk = Array(keys[offset..<min(offset + 400, keys.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                var arguments: [DatabaseValueConvertible?] = [deviceId, typeIdentifier]
                arguments.append(contentsOf: chunk)
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT uuid, day, startTs, value FROM appleHealthSampleIdentity
                        WHERE deviceId = ? AND typeIdentifier = ? AND uuid IN (\(placeholders))
                        """,
                    arguments: StatementArguments(arguments)
                )
                for row in rows {
                    let uuid: String = row["uuid"]
                    result[uuid] = AppleHealthSampleIdentity(
                        typeIdentifier: typeIdentifier, uuid: uuid,
                        day: row["day"], startTs: row["startTs"], value: row["value"])
                }
            }
            return result
        }
    }

    /// Reconcile one anchored-query delta atomically. UUIDs present in added win over a duplicate
    /// tombstone in the same batch. Replaying a delta is safe, and the caller advances its HealthKit
    /// anchor only after this transaction succeeds.
    @discardableResult
    public func reconcileAppleHealthSampleIdentityDelta(
        added: [AppleHealthSampleIdentity],
        deletedUUIDs: [String],
        deviceId: String,
        typeIdentifier: String
    ) async throws -> Set<String> {
        try syncWrite { db in
            for identity in added {
                guard !identity.typeIdentifier.isEmpty, !identity.uuid.isEmpty,
                      !identity.day.isEmpty,
                      identity.value?.isFinite != false,
                      identity.value.map({ $0 >= 0 }) != false else {
                    throw NSError(domain: "WhoopStore.AppleHealthSampleIdentity", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Invalid HealthKit sample identity."])
                }
                guard identity.typeIdentifier == typeIdentifier else {
                    throw NSError(domain: "WhoopStore.AppleHealthSampleIdentity", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "HealthKit sample type does not match its identity batch."])
                }
            }

            let addedUUIDs = Set(added.map(\.uuid))
            let tombstones = Array(Set(deletedUUIDs))
                .filter { !$0.isEmpty && !addedUUIDs.contains($0) }
                .sorted()
            var deletedDays = Set<String>()

            for uuid in tombstones {
                if let day = try String.fetchOne(
                    db,
                    sql: """
                        SELECT day FROM appleHealthSampleIdentity
                        WHERE deviceId = ? AND typeIdentifier = ? AND uuid = ?
                        """,
                    arguments: [deviceId, typeIdentifier, uuid]
                ) {
                    deletedDays.insert(day)
                }
                try db.execute(
                    sql: """
                        DELETE FROM appleHealthSampleIdentity
                        WHERE deviceId = ? AND typeIdentifier = ? AND uuid = ?
                        """,
                    arguments: [deviceId, typeIdentifier, uuid]
                )
            }

            for identity in added {
                try db.execute(sql: """
                    INSERT INTO appleHealthSampleIdentity
                        (deviceId, typeIdentifier, uuid, day, startTs, value)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, typeIdentifier, uuid) DO UPDATE SET
                        day = excluded.day,
                        startTs = excluded.startTs,
                        value = excluded.value
                    """, arguments: [deviceId, typeIdentifier, identity.uuid, identity.day,
                                     identity.startTs, identity.value])
            }
            return deletedDays
        }
    }
}
