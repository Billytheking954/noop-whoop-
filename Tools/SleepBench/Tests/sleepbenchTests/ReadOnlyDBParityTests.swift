import XCTest
import SQLite3
@testable import sleepbench

final class ReadOnlyDBParityTests: XCTestCase {
    func testMeasuredHRWinsAndPPGFillsOnlyMissingSeconds() throws {
        let fixture = try Fixture()
        try fixture.exec("""
            INSERT INTO hrSample VALUES ('band', 100, 60);
            INSERT INTO ppgHrSample VALUES ('band', 100, 99.0, 0.8);
            INSERT INTO ppgHrSample VALUES ('band', 101, 71.6, 0.9);
            """)
        let streams = try fixture.reader().streams(device: "band", from: 100, to: 101)
        XCTAssertEqual(streams.hr.map(\.ts), [100, 101])
        XCTAssertEqual(streams.hr.map(\.bpm), [60, 72])
    }

    func testWhoop5RRUsesOneVerifiedTransportAndRejectsSuspectRows() throws {
        let fixture = try Fixture()
        try fixture.exec("""
            INSERT INTO pairedDevice VALUES ('band', 'WHOOP', '5.0');
            INSERT INTO rrInterval VALUES ('band', 100, 800, 0, 5, 0, 0);
            INSERT INTO rrInterval VALUES ('band', 100, 801, 1, 7, 0, 0);
            INSERT INTO rrInterval VALUES ('band', 101, 802, 0, 5, 1, 1);
            INSERT INTO rrInterval VALUES ('band', 102, 803, 0, 2, 0, 0);
            """)
        let rr = try fixture.reader().streams(device: "band", from: 100, to: 102).rr
        XCTAssertEqual(rr.map(\.rrMs), [800])
        XCTAssertEqual(rr.map(\.srcChannel), [.whoop5Historical])
    }

    func testBoundDeviceIdentifierMayContainAQuote() throws {
        let fixture = try Fixture()
        try fixture.exec("INSERT INTO hrSample VALUES ('band''one', 100, 64);")
        let hr = try fixture.reader().streams(device: "band'one", from: 100, to: 100).hr
        XCTAssertEqual(hr.map(\.bpm), [64])
    }
}

private final class Fixture {
    let url: URL
    private var handle: OpaquePointer?

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleepbench-\(UUID().uuidString).sqlite")
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            throw NSError(domain: "ReadOnlyDBParityTests", code: 1)
        }
        try exec("""
            CREATE TABLE hrSample (deviceId TEXT, ts INTEGER, bpm INTEGER);
            CREATE TABLE ppgHrSample (deviceId TEXT, ts INTEGER, bpm REAL, conf REAL);
            CREATE TABLE rrInterval (deviceId TEXT, ts INTEGER, rrMs INTEGER, seq INTEGER,
                                     srcChannel INTEGER, ord INTEGER, tsSuspect INTEGER);
            CREATE TABLE gravitySample (deviceId TEXT, ts INTEGER, x REAL, y REAL, z REAL, dynAccel REAL);
            CREATE TABLE respSample (deviceId TEXT, ts INTEGER, raw INTEGER);
            CREATE TABLE stepSample (deviceId TEXT, ts INTEGER, counter INTEGER, activityClass INTEGER);
            CREATE TABLE sleepStateSample (deviceId TEXT, ts INTEGER, state INTEGER);
            CREATE TABLE pairedDevice (id TEXT, brand TEXT, model TEXT);
            """)
    }

    deinit {
        if let handle { sqlite3_close(handle) }
        try? FileManager.default.removeItem(at: url)
    }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "ReadOnlyDBParityTests", code: 2)
        }
    }

    func reader() throws -> ReadOnlyDB {
        if let handle { sqlite3_close(handle); self.handle = nil }
        return try ReadOnlyDB(path: url.path)
    }
}
