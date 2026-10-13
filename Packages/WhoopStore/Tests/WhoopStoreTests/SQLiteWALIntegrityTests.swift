import XCTest
import GRDB
@testable import WhoopStore

final class SQLiteWALIntegrityTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wal-integrity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testNativeCommittedWalPassesWithoutChangingEitherFile() throws {
        let main = try fixture()
        let wal = URL(fileURLWithPath: main.path + "-wal")
        let beforeMain = try Data(contentsOf: main)
        let beforeWal = try Data(contentsOf: wal)
        XCTAssertNil(SQLiteWALIntegrity.failure(atPath: wal.path, databaseAtPath: main.path))
        XCTAssertEqual(try Data(contentsOf: main), beforeMain)
        XCTAssertEqual(try Data(contentsOf: wal), beforeWal)
    }

    func testDamagedMagicAndHeaderChecksumAreRejected() throws {
        for offset in [0, 12, 24] {
            let main = try fixture()
            let wal = URL(fileURLWithPath: main.path + "-wal")
            var bytes = try Data(contentsOf: wal)
            bytes[offset] ^= 1
            try bytes.write(to: wal)
            XCTAssertNotNil(SQLiteWALIntegrity.failure(atPath: wal.path, databaseAtPath: main.path))
        }
    }

    func testCorruptCurrentEpochPageIsRejected() throws {
        let main = try fixture()
        let wal = URL(fileURLWithPath: main.path + "-wal")
        var bytes = try Data(contentsOf: wal)
        bytes[32 + 24 + 100] ^= 1
        try bytes.write(to: wal)
        XCTAssertNotNil(SQLiteWALIntegrity.failure(atPath: wal.path, databaseAtPath: main.path))
    }

    func testTruncatedHeaderAndPageAreRejected() throws {
        for length in [16, 32 + 24 + 100] {
            let main = try fixture()
            let wal = URL(fileURLWithPath: main.path + "-wal")
            let bytes = try Data(contentsOf: wal)
            try Data(bytes.prefix(length)).write(to: wal)
            XCTAssertNotNil(SQLiteWALIntegrity.failure(atPath: wal.path, databaseAtPath: main.path))
        }
    }

    func testWalResetTailIsAcceptedAndNativeReaderRetainsAllCommittedRows() throws {
        let main = try fixture(reset: true)
        let wal = URL(fileURLWithPath: main.path + "-wal")
        XCTAssertNil(SQLiteWALIntegrity.failure(atPath: wal.path, databaseAtPath: main.path),
                     "Checkpoint reset leftovers must not be mistaken for corrupt current frames")
        var config = Configuration()
        config.readonly = true
        let reader = try DatabaseQueue(path: main.path, configuration: config)
        XCTAssertEqual(try reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM device") }, 101)
    }

    func testDifferentMainPageSizeIsRejected() throws {
        let main = try fixture()
        let wal = URL(fileURLWithPath: main.path + "-wal")
        var header = try Data(contentsOf: main)
        let encodedSize = Int(header[16]) << 8 | Int(header[17])
        let differentSize = encodedSize == 4096 ? 8192 : 4096
        header[16] = UInt8(differentSize >> 8)
        header[17] = UInt8(differentSize & 255)
        try header.write(to: main)
        XCTAssertNotNil(SQLiteWALIntegrity.failure(atPath: wal.path, databaseAtPath: main.path))
    }

    func testEmptyCheckpointWalIsAcceptedAndMissingWalFails() throws {
        let main = try fixture(truncate: true)
        let wal = URL(fileURLWithPath: main.path + "-wal")
        XCTAssertEqual(try Data(contentsOf: wal).count, 0)
        XCTAssertNil(SQLiteWALIntegrity.failure(atPath: wal.path, databaseAtPath: main.path))
        try FileManager.default.removeItem(at: wal)
        XCTAssertNotNil(SQLiteWALIntegrity.failure(atPath: wal.path, databaseAtPath: main.path))
    }

    /// Native SQLite produces the checksum oracle. Copies are detached before the writer closes.
    private func fixture(reset: Bool = false, truncate: Bool = false) throws -> URL {
        let original = tmp.appendingPathComponent("writer-\(UUID().uuidString).sqlite")
        var config = Configuration()
        config.prepareDatabase { db in
            _ = try String.fetchOne(db, sql: "PRAGMA journal_mode=WAL")
            _ = try Int.fetchOne(db, sql: "PRAGMA wal_autocheckpoint=0")
        }
        let queue = try DatabaseQueue(path: original.path, configuration: config)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT)")
            try db.execute(sql: "CREATE TABLE device (id TEXT)")
            for index in 0..<(reset ? 100 : 1) {
                try db.execute(sql: "INSERT INTO device VALUES (?)", arguments: ["row-\(index)"])
            }
            if reset {
                _ = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(RESTART)")
                try db.execute(sql: "INSERT INTO device VALUES ('after-reset')")
            }
            if truncate { _ = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        }
        return try withExtendedLifetime(queue) {
            let main = tmp.appendingPathComponent("copy-\(UUID().uuidString).sqlite")
            try FileManager.default.copyItem(at: original, to: main)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: original.path + "-wal"),
                                            to: URL(fileURLWithPath: main.path + "-wal"))
            return main
        }
    }
}
