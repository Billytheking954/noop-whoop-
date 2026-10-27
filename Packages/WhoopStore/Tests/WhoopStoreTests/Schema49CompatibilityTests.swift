import Foundation
import GRDB
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
            try queue.write { db in
                try db.execute(sql: "INSERT INTO device (id, name) VALUES (?, ?)",
                               arguments: ["strap-keep", "WHOOP"])
            }
        }
        let upgraded = try await WhoopStore(path: path)
        let tables = try await upgraded.tableNames()
        XCTAssertTrue(tables.contains("appleHealthWorkoutIdentity"))
        XCTAssertTrue(tables.contains("appleHealthSampleIdentity"))
        let queue = try DatabaseQueue(path: path)
        try queue.read { db in
            XCTAssertEqual(try String.fetchOne(db,
                sql: "SELECT name FROM device WHERE id = 'strap-keep'"), "WHOOP")
            XCTAssertEqual(try Int.fetchOne(db,
                sql: "SELECT count(*) FROM grdb_migrations WHERE identifier IN (?, ?)",
                arguments: ["v48-apple-health-workout-identity", "v49-apple-health-sample-identity"]), 2)
        }
    }

    func testReopensV49AndPreservesBothIdentityLedgers() async throws {
        let path = tempPath()
        defer { cleanup(path) }
        do {
            let queue = try DatabaseQueue(path: path)
            try WhoopStore.makeMigrator().migrate(queue)
            try queue.write { db in
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
        try queue.read { db in
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
            try queue.write { db in
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
        try queue.read { db in
            XCTAssertEqual(try String.fetchOne(db,
                sql: "SELECT id FROM device WHERE id = 'future-keep'"), "future-keep")
            XCTAssertEqual(try String.fetchOne(db,
                sql: "SELECT identifier FROM grdb_migrations WHERE identifier = 'v50-future-schema'"),
                           "v50-future-schema")
        }
    }
}
