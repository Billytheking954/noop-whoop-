import XCTest
import GRDB
@testable import WhoopStore

/// #222: a foreign (Android/Room) database dropped over ours by a bad cross-platform restore has our
/// table names but NO `grdb_migrations` bookkeeping, so the migrator re-runs v1 and crashes forever
/// with `table "device" already exists`. Refuse it in place instead of resetting stored data.
final class ForeignDatabaseQuarantineTests: XCTestCase {

    private func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-quarantine-\(UUID().uuidString).sqlite").path
    }

    private func tableNames(at path: String) throws -> Set<String> {
        let q = try DatabaseQueue(path: path)
        return try q.read { db in
            try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
    }

    private func cleanup(_ path: String) {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        let base = (path as NSString).lastPathComponent
        for s in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where s.hasPrefix(base) {
            try? fm.removeItem(atPath: (dir as NSString).appendingPathComponent(s))
        }
    }

    func testForeignDatabaseIsRefusedWithoutMovingOrResettingData() async throws {
        let path = tempPath()
        defer { cleanup(path) }

        // Simulate the foreign DB: our table names + a row, but NO grdb_migrations bookkeeping.
        let raw = try DatabaseQueue(path: path)
        try await raw.write { db in
            try db.execute(sql: "CREATE TABLE device (id TEXT PRIMARY KEY, mac TEXT, name TEXT, firstSeen INTEGER, lastSeen INTEGER)")
            try db.execute(sql: "CREATE TABLE hrSample (deviceId TEXT, ts INTEGER, bpm INTEGER)")
            try db.execute(sql: "INSERT INTO device (id, name) VALUES ('foreign', 'WHOOP')")
        }
        // Release the probe handle before opening the store.
        _ = raw
        XCTAssertFalse(try tableNames(at: path).contains("grdb_migrations"),
                       "precondition: a foreign DB has no grdb_migrations")

        do {
            _ = try await WhoopStore(path: path)
            XCTFail("Missing migration metadata must fail closed")
        } catch {
            XCTAssertEqual((error as NSError).code, 48)
        }
        XCTAssertFalse(try tableNames(at: path).contains("grdb_migrations"))
        let preserved = try await raw.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM device WHERE id = 'foreign'")
        }
        XCTAssertEqual(preserved, "WHOOP")

        let dir = (path as NSString).deletingLastPathComponent
        let base = (path as NSString).lastPathComponent
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir)
        XCTAssertFalse(siblings.contains { $0.hasPrefix(base + ".incompatible-") },
                       "The original database must remain at its original path")
    }

    func testValidGrdbBackupIsNotQuarantined() async throws {
        let path = tempPath()
        defer { cleanup(path) }

        // A real GRDB store (migrations applied), then reopened.
        do {
            let store = try await WhoopStore(path: path)
            try await store.upsertDevice(id: "mine", mac: nil, name: "WHOOP")
        }
        let store = try await WhoopStore(path: path)
        let reopenedTables = try await store.tableNames()
        XCTAssertTrue(reopenedTables.contains("grdb_migrations"))

        let dir = (path as NSString).deletingLastPathComponent
        let base = (path as NSString).lastPathComponent
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir)
        XCTAssertFalse(siblings.contains { $0.hasPrefix(base + ".incompatible-") },
                       "a valid GRDB DB must never be quarantined")
    }
}
