import XCTest
import SQLite3
@testable import WhoopStore

final class CheckpointBusyTests: XCTestCase {
    func testPinnedReaderCannotBeReportedAsSuccessfulCheckpoint() async throws {
        let path = NSTemporaryDirectory() + "checkpoint-busy-\(UUID().uuidString).sqlite"
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let store = try await WhoopStore(path: path)
        try await store.checkpointWAL()
        var reader: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &reader), SQLITE_OK)
        defer { sqlite3_close(reader) }
        XCTAssertEqual(sqlite3_exec(reader, "BEGIN; SELECT count(*) FROM device", nil, nil, nil), SQLITE_OK)
        try await store.upsertDevice(id: "committed-after-reader", mac: nil, name: nil)
        do {
            try await store.checkpointWAL()
            XCTFail("A busy result row must fail the checkpoint gate")
        } catch {}
        XCTAssertEqual(sqlite3_exec(reader, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        try await store.checkpointWAL()
    }
}
