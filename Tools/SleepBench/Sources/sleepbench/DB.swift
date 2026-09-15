import Foundation
import SQLite3
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Minimal read-only SQLite reader. Deliberately not GRDB: this tool must be able to open a COPY of a
/// device database taken at any schema version, including one older or newer than `WhoopStore`'s current
/// migration set, without running migrations against it. Opened `immutable=1` so it can never write.
final class ReadOnlyDB {
    private var handle: OpaquePointer?

    enum Binding {
        case integer(Int)
        case text(String)
    }

    init(path: String) throws {
        // `immutable=1` promises the file will not change under us and suppresses any journal/WAL
        // recovery write — the reason a plain read-only open is not enough for a pulled device DB.
        let uri = "file:\(path)?immutable=1"
        let rc = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK else {
            throw Err("cannot open \(path): \(String(cString: sqlite3_errstr(rc)))")
        }
    }
    deinit { if let handle { sqlite3_close(handle) } }

    struct Err: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    /// Run a bound query and hand each row to `each` as a statement cursor. A terminal SQLite error is
    /// reported rather than being mistaken for an ordinary end-of-results condition.
    func query(_ sql: String, bindings: [Binding] = [], _ each: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw Err("prepare failed: \(String(cString: sqlite3_errmsg(handle))) [\(sql)]")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .integer(let number):
                rc = sqlite3_bind_int64(stmt, index, sqlite3_int64(number))
            case .text(let string):
                rc = string.withCString { sqlite3_bind_text(stmt, index, $0, -1, transient) }
            }
            guard rc == SQLITE_OK else {
                throw Err("bind failed: \(String(cString: sqlite3_errmsg(handle))) [parameter \(index)]")
            }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { each(stmt!); continue }
            if rc == SQLITE_DONE { return }
            throw Err("step failed: \(String(cString: sqlite3_errmsg(handle))) [\(sql)]")
        }
    }

    static func int(_ s: OpaquePointer, _ i: Int32) -> Int { Int(sqlite3_column_int64(s, i)) }
    static func dbl(_ s: OpaquePointer, _ i: Int32) -> Double { sqlite3_column_double(s, i) }
    static func isNull(_ s: OpaquePointer, _ i: Int32) -> Bool {
        sqlite3_column_type(s, i) == SQLITE_NULL
    }
    static func str(_ s: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }

    func hasTable(_ table: String) throws -> Bool {
        var found = false
        try query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
                  bindings: [.text(table)]) { _ in found = true }
        return found
    }

    func hasColumn(_ column: String, in table: String) throws -> Bool {
        // Both identifiers are compile-time names supplied by this tool, never user input.
        var found = false
        try query("PRAGMA table_info(\(table))") { statement in
            if ReadOnlyDB.str(statement, 1) == column { found = true }
        }
        return found
    }
}

// MARK: - Rows

/// One persisted night. `stagesJSON` is the hypnogram CURRENTLY stored; on a `userEdited` row that is the
/// wearer's manual restage, and `efficiency` is then the STALE pre-edit machine value (the edit path
/// rewrites the stages but not the summary column) — which is exactly what makes the machine's original
/// wake total recoverable. See `MachineRecall` in main.swift for the check that establishes this.
struct SessionRow {
    let deviceId: String
    let startTs: Int
    let endTs: Int
    let efficiency: Double?
    let userEdited: Bool
    let startTsAdjusted: Int?
    let stages: [StageSegment]
    let bandStates: [Int]        // persisted per-epoch sleepStateJSON, [] when absent
    var durMin: Double { Double(endTs - startTs) / 60.0 }
}

struct Streams {
    var hr: [HRSample] = []
    var rr: [RRInterval] = []
    var grav: [GravitySample] = []
    var resp: [RespSample] = []
    var steps: [StepSample] = []
    var band: [(ts: Int, state: Int)] = []
}

extension ReadOnlyDB {
    func sessions(device: String) throws -> [SessionRow] {
        var out: [SessionRow] = []
        let sql = """
        SELECT startTs, endTs, efficiency, userEdited, startTsAdjusted, stagesJSON, sleepStateJSON
        FROM sleepSession WHERE deviceId = ? ORDER BY startTs
        """
        try query(sql, bindings: [.text(device)]) { s in
            let stagesJSON = ReadOnlyDB.str(s, 5) ?? "[]"
            let stages = (try? JSONDecoder().decode([StageSegment].self,
                                                    from: Data(stagesJSON.utf8))) ?? []
            var band: [Int] = []
            if let bj = ReadOnlyDB.str(s, 6) {
                band = (try? JSONDecoder().decode([Int].self, from: Data(bj.utf8))) ?? []
            }
            out.append(SessionRow(
                deviceId: device,
                startTs: ReadOnlyDB.int(s, 0),
                endTs: ReadOnlyDB.int(s, 1),
                efficiency: ReadOnlyDB.isNull(s, 2) ? nil : ReadOnlyDB.dbl(s, 2),
                userEdited: ReadOnlyDB.int(s, 3) != 0,
                startTsAdjusted: ReadOnlyDB.isNull(s, 4) ? nil : ReadOnlyDB.int(s, 4),
                stages: stages,
                bandStates: band))
        }
        return out
    }

    /// Every stream the stagers read, over `[from, to]`. The stagers themselves clip to the window they
    /// need, but detection wants a wider span than the session, hence the caller-chosen padding.
    func streams(device: String, from: Int, to: Int) throws -> Streams {
        var st = Streams()
        st.hr = try scoringHR(device: device, from: from, to: to)
        st.rr = try scoringRR(device: device, from: from, to: to)
        let window: [Binding] = [.text(device), .integer(from), .integer(to)]
        try query("SELECT ts, x, y, z, dynAccel FROM gravitySample WHERE deviceId = ? AND ts >= ? AND ts <= ? ORDER BY ts",
                  bindings: window) { s in
            st.grav.append(GravitySample(
                ts: ReadOnlyDB.int(s, 0), x: ReadOnlyDB.dbl(s, 1), y: ReadOnlyDB.dbl(s, 2),
                z: ReadOnlyDB.dbl(s, 3), unit: "g",
                dynAccel: ReadOnlyDB.isNull(s, 4) ? nil : ReadOnlyDB.dbl(s, 4)))
        }
        // An Oura ring's respiration rows are its OWN per-window rate (0x6A, milli-bpm), stored as
        // instrumentation; the stagers read this stream as a ~1 Hz raw ADC waveform. The app refuses
        // them by provenance at every scoring read, so the bench must refuse them the same way or it
        // would score a night the app cannot produce. Same seam, one line: `OuraRespScale.forScoring`.
        if !OuraRespScale.isRingRateStream(deviceId: device) {
            try query("SELECT ts, raw FROM respSample WHERE deviceId = ? AND ts >= ? AND ts <= ? ORDER BY ts",
                      bindings: window) { s in
                st.resp.append(RespSample(ts: ReadOnlyDB.int(s, 0), raw: ReadOnlyDB.int(s, 1)))
            }
        }
        try query("SELECT ts, counter, activityClass FROM stepSample WHERE deviceId = ? AND ts >= ? AND ts <= ? ORDER BY ts",
                  bindings: window) { s in
            st.steps.append(StepSample(
                ts: ReadOnlyDB.int(s, 0), counter: ReadOnlyDB.int(s, 1),
                activityClass: ReadOnlyDB.isNull(s, 2) ? nil : ReadOnlyDB.int(s, 2)))
        }
        try query("SELECT ts, state FROM sleepStateSample WHERE deviceId = ? AND ts >= ? AND ts <= ? ORDER BY ts",
                  bindings: window) { s in
            st.band.append((ts: ReadOnlyDB.int(s, 0), state: ReadOnlyDB.int(s, 1)))
        }
        return st
    }

    /// The app's measured-first HR union: a PPG estimate fills only seconds with no measured row.
    private func scoringHR(device: String, from: Int, to: Int) throws -> [HRSample] {
        var out: [HRSample] = []
        let values: [Binding] = [.text(device), .integer(from), .integer(to)]
        if try hasTable("ppgHrSample") {
            try query("""
                SELECT ts, bpm FROM (
                    SELECT ts, bpm FROM hrSample
                    WHERE deviceId = ? AND ts >= ? AND ts <= ?
                    UNION ALL
                    SELECT p.ts, CAST(ROUND(p.bpm) AS INTEGER) FROM ppgHrSample p
                    WHERE p.deviceId = ? AND p.ts >= ? AND p.ts <= ?
                      AND NOT EXISTS (SELECT 1 FROM hrSample h
                                      WHERE h.deviceId = p.deviceId AND h.ts = p.ts)
                ) ORDER BY ts ASC
                """, bindings: values + values) { statement in
                out.append(HRSample(ts: ReadOnlyDB.int(statement, 0), bpm: ReadOnlyDB.int(statement, 1)))
            }
        } else {
            try query("SELECT ts, bpm FROM hrSample WHERE deviceId = ? AND ts >= ? AND ts <= ? ORDER BY ts ASC",
                      bindings: values) { statement in
                out.append(HRSample(ts: ReadOnlyDB.int(statement, 0), bpm: ReadOnlyDB.int(statement, 1)))
            }
        }
        return out
    }

    /// Mirror the current store R-R policy without opening the snapshot through migrations: reject suspect
    /// timestamps, exclude Oura's duplicate SpO2 IBI channel, and pin a WHOOP 5 window to one verified
    /// transport. Missing legacy columns stay explicit rather than being guessed into a modern source.
    private func scoringRR(device: String, from: Int, to: Int) throws -> [RRInterval] {
        let hasSource = try hasColumn("srcChannel", in: "rrInterval")
        let hasOrder = try hasColumn("ord", in: "rrInterval")
        let hasSequence = try hasColumn("seq", in: "rrInterval")
        let hasSuspect = try hasColumn("tsSuspect", in: "rrInterval")
        let strictWhoop5 = try usesCanonicalWhoop5RR(device: device, hasSource: hasSource)

        let sourceSelect = hasSource ? "srcChannel" : "NULL AS srcChannel"
        let orderSelect = hasOrder ? "ord" : "NULL AS ord"
        let sequenceSelect = hasSequence ? "seq" : "0 AS seq"
        let suspectPredicate = hasSuspect ? "AND (tsSuspect IS NULL OR tsSuspect <> 1)" : ""
        let duplicatePredicate = hasSource ? "AND (srcChannel IS NULL OR srcChannel <> 2)" : ""
        let sourcePredicate: String
        if strictWhoop5 && hasSource {
            sourcePredicate = """
                AND srcChannel = (SELECT MIN(srcChannel) FROM rrInterval
                    WHERE deviceId = ? AND ts >= ? AND ts <= ? AND srcChannel IN (5, 7)
                    \(hasSuspect ? "AND (tsSuspect IS NULL OR tsSuspect <> 1)" : ""))
                """
        } else if strictWhoop5 {
            // A current migrated store would add the source column as NULL and withhold these unverified
            // WHOOP 5 rows. The immutable historical snapshot cannot be mutated just to demonstrate that.
            sourcePredicate = "AND 0"
        } else {
            sourcePredicate = ""
        }

        var out: [RRInterval] = []
        var bindings: [Binding] = [.text(device), .integer(from), .integer(to)]
        if strictWhoop5 && hasSource { bindings += [.text(device), .integer(from), .integer(to)] }
        try query("""
            SELECT ts, rrMs, \(sourceSelect), \(orderSelect), \(sequenceSelect) FROM rrInterval
            WHERE deviceId = ? AND ts >= ? AND ts <= ?
            \(duplicatePredicate)
            \(sourcePredicate)
            \(suspectPredicate)
            ORDER BY ts ASC, ord ASC, rrMs ASC, seq ASC
            """, bindings: bindings) { statement in
            let rawSource = ReadOnlyDB.isNull(statement, 2) ? nil : ReadOnlyDB.int(statement, 2)
            out.append(RRInterval(
                ts: ReadOnlyDB.int(statement, 0), rrMs: ReadOnlyDB.int(statement, 1),
                srcChannel: rawSource.flatMap(RRSourceChannel.init(rawValue:)),
                ord: ReadOnlyDB.isNull(statement, 3) ? nil : ReadOnlyDB.int(statement, 3),
                seq: ReadOnlyDB.int(statement, 4)))
        }
        return out
    }

    private func usesCanonicalWhoop5RR(device: String, hasSource: Bool) throws -> Bool {
        guard try hasTable("pairedDevice"),
              try hasColumn("model", in: "pairedDevice"),
              try hasColumn("brand", in: "pairedDevice") else { return false }
        var model: String?, brand: String?
        try query("SELECT model, brand FROM pairedDevice WHERE id = ? LIMIT 1",
                  bindings: [.text(device)]) { statement in
            model = ReadOnlyDB.str(statement, 0)
            brand = ReadOnlyDB.str(statement, 1)
        }
        var tagged = false
        if hasSource {
            try query("SELECT 1 FROM rrInterval WHERE deviceId = ? AND srcChannel IN (5, 6, 7) LIMIT 1",
                      bindings: [.text(device)]) { _ in tagged = true }
        }
        return Whoop5RR.usesCanonicalSource(model: model, brand: brand, hasTaggedIntervals: tagged)
    }

    /// The `stagelock:<deviceId>:<startTs>` cursors. A lock is written ONLY by `CloudEditApplier` when an
    /// `edit_sleep_stages` payload lands — i.e. only when a human authored the hypnogram itself, as opposed
    /// to correcting the bed/wake bounds (which re-derives stages from raw and is therefore machine output
    /// over a human-chosen window). This distinction decides whether a `userEdited` row is usable as a
    /// stage-level reference at all, so the harness reads it rather than assuming.
    func stageLockedStarts(device: String) throws -> Set<Int> {
        var out: Set<Int> = []
        let prefix = "stagelock:\(device):"
        try query("SELECT name FROM cursors WHERE value = 1 AND name LIKE ?",
                  bindings: [.text(prefix + "%")]) { s in
            if let n = ReadOnlyDB.str(s, 0), let ts = Int(n.dropFirst(prefix.count)) { out.insert(ts) }
        }
        return out
    }

    /// Mean / min HR over a window — the stratifier for the supplement-HR hypothesis.
    func hrStats(device: String, from: Int, to: Int) throws -> (mean: Double, n: Int, p10: Double)? {
        var v = try scoringHR(device: device, from: from, to: to).map { Double($0.bpm) }
        guard !v.isEmpty else { return nil }
        v.sort()
        return (v.reduce(0, +) / Double(v.count), v.count, v[max(0, Int(Double(v.count) * 0.10) - 1)])
    }
}
