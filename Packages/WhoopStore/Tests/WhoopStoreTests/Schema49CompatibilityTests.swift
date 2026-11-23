import Foundation
import GRDB
import SQLite3
import XCTest
@testable import WhoopStore

/// Disposable database fixtures only. Never points to the installed iPhone's data.
final class Schema49CompatibilityTests: XCTestCase {
    private func tempPath() -> String {
        NSTemporaryDirectory() + "noop-schema49-\(UUID().uuidString).sqlite"
    }

    private func cleanup(_ path: String) {
        for ext in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + ext)
        }
    }

    func testUpgradesV47FileToV49WithoutDeletingExistingRows() async throws {
        let path = tempPath()
        defer { cleanup(path) }
        do {
            let queue = try DatabaseQueue(path: path)
            // Construct an actual v47 fixture with GRDB's own migration history,
            // then put a WHOOP device in it before the new app opens the file.
            try WhoopStore.makeMigrator().migrate(queue, upTo: "v47-rr-whoop5-fill")
            try await queue.write { db in
                try db.execute(sql: "INSERT INTO device (id, name) VALUES (?, ?)",
                               arguments: ["strap-keep", "WHOOP"])
                try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('strap-keep', 1000, 65)")
                try db.execute(sql: "INSERT INTO rrInterval (deviceId, ts, rrMs, seq) VALUES ('strap-keep', 1000, 900, 0)")
            }
        }
        let upgraded = try await WhoopStore(path: path)
        let tables = try await upgraded.tableNames()
        XCTAssertTrue(tables.contains("appleHealthWorkoutIdentity"))
        XCTAssertTrue(tables.contains("appleHealthSampleIdentity"))
        let queue = try DatabaseQueue(path: path)
        try await queue.read { db in
            XCTAssertEqual(try String.fetchOne(db,
                sql: "SELECT name FROM device WHERE id = 'strap-keep'"), "WHOOP")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT bpm FROM hrSample WHERE deviceId = 'strap-keep'"), 65)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT rrMs FROM rrInterval WHERE deviceId = 'strap-keep'"), 900)
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA quick_check"), "ok")
            XCTAssertEqual(try Int.fetchOne(db,
                sql: "SELECT count(*) FROM grdb_migrations WHERE identifier IN (?, ?)",
                arguments: ["v48-apple-health-workout-identity", "v49-apple-health-sample-identity"]), 2)
        }
    }

    func testUpgradeRetainsCommittedWALPairingWorkoutsAndSpO2AcrossConcurrentOpens() async throws {
        let path = tempPath()
        defer { cleanup(path) }
        let legacy = try DatabaseQueue(path: path)
        _ = try await legacy.writeWithoutTransaction { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode=WAL")
        }
        try WhoopStore.makeMigrator().migrate(legacy, upTo: "v47-rr-whoop5-fill")
        try await legacy.write { db in
            try db.execute(sql: "PRAGMA wal_autocheckpoint=0")
            try db.execute(sql: "INSERT INTO device (id, name, mac) VALUES ('upgrade-strap', 'WHOOP', 'synthetic-peripheral')")
            try db.execute(sql: "UPDATE pairedDevice SET nickname = 'Retain pairing', model = '5.0' WHERE id = 'my-whoop'")
            try db.execute(sql: "INSERT INTO cursors (name, value) VALUES ('upgrade-sync', 123456)")
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES ('upgrade-strap', 1000, 65)")
            try db.execute(sql: "INSERT INTO spo2Sample (deviceId, ts, red, ir) VALUES ('upgrade-strap', 1000, 123, 456)")
            try db.execute(sql: """
                INSERT INTO workout (deviceId, startTs, endTs, sport, source, durationS, notes)
                VALUES ('upgrade-strap', 1000, 1600, 'running', 'manual', 600, 'Keep original workout')
                """)
            try db.execute(sql: "INSERT INTO journal (deviceId, day, question, answeredYes, notes) VALUES ('upgrade-strap', '2026-11-23', 'test', 1, 'Keep note')")
        }
        let walSize = try FileManager.default.attributesOfItem(atPath: path + "-wal")[.size] as? NSNumber
        XCTAssertGreaterThan(try XCTUnwrap(walSize).intValue, 32)
        let before = try await legacy.read { db -> [String: [Row]] in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations' ORDER BY name")
            return try Dictionary(uniqueKeysWithValues: tables.map { table in
                (table, try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\""))
            })
        }
        // Both launch-time clients may open the same old store (repository + BLE).
        async let first = WhoopStore(path: path)
        async let second = WhoopStore(path: path)
        let stores = try await (first, second)
        _ = stores
        try await legacy.read { db in
            for (table, rows) in before {
                XCTAssertEqual(try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\""), rows,
                               "Upgrade changed existing table \(table)")
            }
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA integrity_check"), "ok")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM grdb_migrations WHERE identifier LIKE 'v48-%' OR identifier LIKE 'v49-%'"), 2)
        }
    }

    func testReopensV49AndPreservesBothIdentityLedgers() async throws {
        let path = tempPath()
        defer { cleanup(path) }
        do {
            let queue = try DatabaseQueue(path: path)
            try WhoopStore.makeMigrator().migrate(queue)
            try await queue.write { db in
                try db.execute(sql: """
                    INSERT INTO appleHealthWorkoutIdentity (deviceId, uuid, startTs, sport, day)
                    VALUES ('apple-health', 'workout-uuid', 1000, 'walking', '2026-10-25')
                    """)
                try db.execute(sql: """
                    INSERT INTO appleHealthSampleIdentity (deviceId, typeIdentifier, uuid, day, startTs, value)
                    VALUES ('apple-health', 'dietaryWater', 'water-uuid', '2026-10-25', 1100, 250.0)
                    """)
            }
        }
        _ = try await WhoopStore(path: path)
        let queue = try DatabaseQueue(path: path)
        try await queue.read { db in
            XCTAssertEqual(try String.fetchOne(db,
                sql: "SELECT uuid FROM appleHealthWorkoutIdentity WHERE deviceId = 'apple-health'"), "workout-uuid")
            XCTAssertEqual(try String.fetchOne(db,
                sql: "SELECT uuid FROM appleHealthSampleIdentity WHERE deviceId = 'apple-health'"), "water-uuid")
            XCTAssertEqual(try Double.fetchOne(db,
                sql: "SELECT value FROM appleHealthSampleIdentity WHERE uuid = 'water-uuid'"), 250.0)
        }
    }

    func testRefusesAValidDatabaseWithUnknownFutureMigrationWithoutErasingIt() async throws {
        let path = tempPath()
        defer { cleanup(path) }
        do {
            let queue = try DatabaseQueue(path: path)
            try WhoopStore.makeMigrator().migrate(queue)
            try await queue.write { db in
                try db.execute(sql: "INSERT INTO device (id, name) VALUES ('future-keep', 'WHOOP')")
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v50-future-schema')")
            }
        }
        do {
            _ = try await WhoopStore(path: path)
            XCTFail("Unknown future migration should block opening the older app")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unsafe downgrade"),
                          "Unexpected error: \(error)")
        }
        let queue = try DatabaseQueue(path: path)
        try await queue.read { db in
            XCTAssertEqual(try String.fetchOne(db,
                sql: "SELECT id FROM device WHERE id = 'future-keep'"), "future-keep")
            XCTAssertEqual(try String.fetchOne(db,
                sql: "SELECT identifier FROM grdb_migrations WHERE identifier = 'v50-future-schema'"),
                           "v50-future-schema")
        }
    }
    func testV49SnapshotRoundTripKeepsWALCommittedIdentityHistory() async throws {
        let sourcePath = tempPath()
        let copyPath = tempPath()
        defer { cleanup(sourcePath); cleanup(copyPath) }
        do {
            let source = try DatabaseQueue(path: sourcePath)
            _ = try await source.writeWithoutTransaction { db in
                try String.fetchOne(db, sql: "PRAGMA journal_mode=WAL")
            }
            try WhoopStore.makeMigrator().migrate(source)
            try await source.write { db in
                try db.execute(sql: "INSERT INTO device (id, name) VALUES ('snapshot-device', 'WHOOP')")
                try db.execute(sql: """
                    INSERT INTO appleHealthWorkoutIdentity (deviceId, uuid, startTs, sport, day)
                    VALUES ('apple-health', 'snapshot-workout', 2000, 'walking', '2026-10-26')
                    """)
                try db.execute(sql: """
                    INSERT INTO appleHealthSampleIdentity (deviceId, typeIdentifier, uuid, day, startTs, value)
                    VALUES ('apple-health', 'dietaryWater', 'snapshot-water', '2026-10-26', 2100, 300)
                    """)
            }
            let journalMode = try await source.read { db in
                try String.fetchOne(db, sql: "PRAGMA journal_mode")
            }
            XCTAssertEqual(journalMode, "wal")
            let walSize = try FileManager.default.attributesOfItem(atPath: sourcePath + "-wal")[.size] as? NSNumber
            XCTAssertGreaterThan(try XCTUnwrap(walSize).intValue, 32,
                                 "Snapshot fixture must contain committed WAL pages")
            // Match production's sqlite3_backup snapshot. Opening a second GRDB
            // writer for the destination while the WAL fixture is live can race
            // its -shm cleanup and fail before the snapshot is even checked.
            try snapshotWithSQLite(from: sourcePath, to: copyPath)
        }
        let copy = try DatabaseQueue(path: copyPath)
        try await copy.read { db in
            XCTAssertEqual(try String.fetchOne(db,
                sql: "SELECT name FROM device WHERE id = 'snapshot-device'"), "WHOOP")
            XCTAssertEqual(try String.fetchOne(db,
                sql: "SELECT uuid FROM appleHealthWorkoutIdentity WHERE uuid = 'snapshot-workout'"),
                "snapshot-workout")
            XCTAssertEqual(try Double.fetchOne(db,
                sql: "SELECT value FROM appleHealthSampleIdentity WHERE uuid = 'snapshot-water'"), 300)
        }
    }

    private func snapshotWithSQLite(from sourcePath: String, to copyPath: String) throws {
        var source: OpaquePointer?
        var destination: OpaquePointer?
        guard sqlite3_open_v2(sourcePath, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let source else { throw NSError(domain: "Schema49CompatibilityTests", code: 1) }
        defer { sqlite3_close(source) }
        guard sqlite3_open_v2(copyPath, &destination,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let destination else { throw NSError(domain: "Schema49CompatibilityTests", code: 2) }
        defer { sqlite3_close(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw NSError(domain: "Schema49CompatibilityTests", code: 3)
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        XCTAssertEqual(step, SQLITE_DONE)
        XCTAssertEqual(finish, SQLITE_OK)
    }

}
