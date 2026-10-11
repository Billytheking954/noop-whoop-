import XCTest
import SQLite3
import ZIPFoundation
import WhoopStore
@testable import Strand

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    init(_ value: Value? = nil) { self.value = value }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard var current = value else { return }
        body(&current)
        value = current
    }

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Real file-I/O tests for the Backup & Sync restore path - not string logic (must-fix #5).
///
/// These exercise the SAME hardened core the picker import uses, via the injectable
/// `DataBackup.restore(from:toDatabaseAt:)` seam (a throwaway DB path, never the user's live store):
///  - a `.noopbak` ZIP backup round-trips: `writeBackupForTesting` then `restore` returns the same rows;
///  - a foreign-but-valid SQLite (Room / no `grdb_migrations`) is REJECTED and the live DB is intact;
///  - a corrupt (non-SQLite) file is REJECTED and the live DB is intact;
///  - a folder prune actually deletes the oldest files past keep-N (pure selection, applied to real files).
final class BackupSyncRoundTripTests: XCTestCase {

    private var tmp: URL!
    private var suites: [String] = []

    override func setUpWithError() throws {
        StoreWriteBarrier.resumeAfterFailedRestore()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("backupsync-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites = []
        StoreWriteBarrier.resumeAfterFailedRestore()
    }

    /// A suite-scoped UserDefaults for the settings half of a restore, so these tests NEVER write into
    /// the test runner's `.standard` domain (which on a dev Mac is the developer's real NOOP profile).
    private func freshDefaults() throws -> UserDefaults {
        let name = "backupsync-test-\(UUID().uuidString)"
        guard let d = UserDefaults(suiteName: name) else { throw TestError("no suite defaults") }
        suites.append(name)
        return d
    }

    // MARK: - Round trip: backupNow → restore returns the same rows

    func testBackupThenRestoreReturnsTheSameRows() throws {
        // A valid GRDB-origin source DB (carries `grdb_migrations`) with one data table + known rows.
        let sourceDB = tmp.appendingPathComponent("source.sqlite")
        try makeNoopDatabase(at: sourceDB, deviceRows: ["my-whoop", "watch"])

        // Write it into a `.noopbak` ZIP exactly as the folder/auto path does.
        let backup = tmp.appendingPathComponent(BackupSync.snapshotName(1_782_000_000_000))
        try DataBackup.writeBackupForTesting(databaseAt: sourceDB, to: backup)
        XCTAssertTrue(isZip(backup), "Backup should be a ZIP container (.noopbak)")

        // Restore into a DIFFERENT, throwaway live-DB path (so the user's real store is never touched).
        let liveDB = tmp.appendingPathComponent("live.sqlite")
        let result = DataBackup.restore(from: backup, toDatabaseAt: liveDB.path)

        guard case .imported = result else {
            return XCTFail("Restore should succeed for a valid NOOP backup, got \(result)")
        }
        XCTAssertEqual(try deviceRows(in: liveDB), ["my-whoop", "watch"],
                       "Restored DB should hold exactly the backed-up rows")
        XCTAssertTrue(StoreWriteBarrier.isSuspended,
                      "Old pools must remain blocked after a successful restore")
    }

    func testSnapshotFailureResumesDatabaseWrites() throws {
        let sourceDB = tmp.appendingPathComponent("source-failure.sqlite")
        try makeNoopDatabase(at: sourceDB, deviceRows: ["original"])
        let backup = tmp.appendingPathComponent("source-failure.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: sourceDB, to: backup)

        // A directory cannot be opened as the existing SQLite DB. This forces the
        // rollback snapshot to fail after the restore write barrier has been engaged.
        let invalidLivePath = tmp.appendingPathComponent("directory-not-sqlite.sqlite", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidLivePath, withIntermediateDirectories: true)
        let result = DataBackup.restore(from: backup, toDatabaseAt: invalidLivePath.path)
        guard case .failure = result else {
            return XCTFail("Snapshot should fail for a directory, got \(result)")
        }
        XCTAssertFalse(StoreWriteBarrier.isSuspended,
                       "Failed restores must reopen the write gate")

        // After failure, a subsequent valid restore should still be possible.
        let retryPath = tmp.appendingPathComponent("retry-live.sqlite")
        let retry = DataBackup.restore(from: backup, toDatabaseAt: retryPath.path)
        guard case .imported = retry else {
            return XCTFail("A valid retry should succeed after gate recovery, got \(retry)")
        }
        XCTAssertTrue(StoreWriteBarrier.isSuspended,
                      "A successful retry must close the gate until relaunch")
    }

    func testFailedReplacementRollsBackButKeepsStalePoolsBlocked() throws {
        let sourceDB = tmp.appendingPathComponent("replacement-source.sqlite")
        try makeNoopDatabase(at: sourceDB, deviceRows: ["replacement"])
        let backup = tmp.appendingPathComponent("replacement.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: sourceDB, to: backup)

        let liveDB = tmp.appendingPathComponent("live-copy-failure.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        var copyCalls = 0
        let result = DataBackup.restore(from: backup, toDatabaseAt: liveDB.path) { source, destination in
            copyCalls += 1
            if copyCalls == 1 { throw TestError("injected replacement-copy failure") }
            try FileManager.default.copyItem(at: source, to: destination)
        }

        guard case .failure(let message) = result else {
            return XCTFail("Injected replacement-copy failure must fail restore, got \(result)")
        }
        XCTAssertEqual(copyCalls, 2, "The second copy must restore the rollback snapshot")
        XCTAssertEqual(try deviceRows(in: liveDB), ["original"])
        XCTAssertTrue(message.contains("existing data was kept"))
        XCTAssertTrue(StoreWriteBarrier.isSuspended,
                      "Unlinking the pathname makes old pools stale even when rollback succeeds")
    }

    func testRollbackCopyFailureIsReportedHonestlyAndPreservesRecoverySnapshot() throws {
        let sourceDB = tmp.appendingPathComponent("rollback-failure-source.sqlite")
        try makeNoopDatabase(at: sourceDB, deviceRows: ["replacement"])
        let backup = tmp.appendingPathComponent("rollback-failure.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: sourceDB, to: backup)

        let liveDB = tmp.appendingPathComponent("live-rollback-failure.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        let result = DataBackup.restore(from: backup, toDatabaseAt: liveDB.path) { _, _ in
            throw TestError("injected copy failure")
        }

        guard case .failure(let message) = result else {
            return XCTFail("A failed replacement and failed rollback must fail restore, got \(result)")
        }
        XCTAssertFalse(message.contains("existing data was kept"),
                       "The UI must not claim preservation when rollback failed")
        XCTAssertTrue(message.contains("Recovery snapshot:"),
                      "The user must be told where the preserved recovery database is")
        XCTAssertTrue(message.contains("Fully quit and reopen NOOP"))
        XCTAssertTrue(StoreWriteBarrier.isSuspended,
                      "An unverified live pathname must never reopen stale database pools")

        let snapshots = try FileManager.default.contentsOfDirectory(at: tmp,
            includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("whoop-replaced-") }
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(try deviceRows(in: try XCTUnwrap(snapshots.first)), ["original"],
                       "The self-contained recovery sidecar must remain readable")
    }

    func testPostSwapFailureDoesNotHideFailedRollbackVerification() throws {
        let sourceDB = tmp.appendingPathComponent("post-swap-source.sqlite")
        try makeNoopDatabase(at: sourceDB, deviceRows: ["replacement"])
        let backup = tmp.appendingPathComponent("post-swap.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: sourceDB, to: backup)

        let liveDB = tmp.appendingPathComponent("live-post-swap.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        var copyCalls = 0
        let result = DataBackup.restore(from: backup, toDatabaseAt: liveDB.path) { source, destination in
            copyCalls += 1
            try FileManager.default.copyItem(at: source, to: destination)
            // Simulate a torn filesystem copy after both the replacement and rollback operations claim
            // success. The rollback helper must independently verify what landed.
            try Data(repeating: 0x41, count: 4096).write(to: destination)
        }

        guard case .failure(let message) = result else {
            return XCTFail("A torn landed database must fail restore, got \(result)")
        }
        XCTAssertEqual(copyCalls, 2)
        XCTAssertFalse(message.contains("rolled back automatically and is unchanged"),
                       "A corrupt rollback copy must never be reported as successful")
        XCTAssertTrue(message.contains("Recovery snapshot:"))
        XCTAssertTrue(StoreWriteBarrier.isSuspended)

        let snapshots = try FileManager.default.contentsOfDirectory(at: tmp,
            includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("whoop-replaced-") }
        XCTAssertEqual(try deviceRows(in: try XCTUnwrap(snapshots.first)), ["original"])
    }

    func testSecondRestoreIsRejectedUntilRelaunchWithoutReopeningOldPools() throws {
        let firstSource = tmp.appendingPathComponent("first-source.sqlite")
        try makeNoopDatabase(at: firstSource, deviceRows: ["first-backup"])
        let firstBackup = tmp.appendingPathComponent("first.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: firstSource, to: firstBackup)

        let secondSource = tmp.appendingPathComponent("second-source.sqlite")
        try makeNoopDatabase(at: secondSource, deviceRows: ["second-backup"])
        let secondBackup = tmp.appendingPathComponent("second.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: secondSource, to: secondBackup)

        let liveDB = tmp.appendingPathComponent("live-repeated.sqlite")
        guard case .imported = DataBackup.restore(from: firstBackup, toDatabaseAt: liveDB.path) else {
            return XCTFail("First valid restore must succeed")
        }
        XCTAssertTrue(StoreWriteBarrier.isSuspended)
        XCTAssertEqual(try deviceRows(in: liveDB), ["first-backup"])

        // Every pool opened before the first restore still refers to its old SQLite inode.
        // Even a valid second archive must not be allowed to replace the path in this process.
        guard case .failure = DataBackup.restore(from: secondBackup, toDatabaseAt: liveDB.path) else {
            return XCTFail("A second restore must require a full app relaunch")
        }
        XCTAssertTrue(StoreWriteBarrier.isSuspended,
                      "Rejected second restore must never reopen write permits to stale pools")
        XCTAssertEqual(try deviceRows(in: liveDB), ["first-backup"],
                       "Rejected attempt must not change the first restored database")
    }

    func testConcurrentFullRestoreRejectsLoserBeforeItTouchesDatabasePath() throws {
        let winnerSource = tmp.appendingPathComponent("concurrent-winner-source.sqlite")
        try makeNoopDatabase(at: winnerSource, deviceRows: ["winner"])
        let winnerBackup = tmp.appendingPathComponent("concurrent-winner.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: winnerSource, to: winnerBackup)

        let loserSource = tmp.appendingPathComponent("concurrent-loser-source.sqlite")
        try makeNoopDatabase(at: loserSource, deviceRows: ["loser"])
        let loserBackup = tmp.appendingPathComponent("concurrent-loser.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: loserSource, to: loserBackup)

        let liveDB = tmp.appendingPathComponent("live-concurrent.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        let winnerAtCopy = DispatchSemaphore(value: 0)
        let releaseWinner = DispatchSemaphore(value: 0)
        let winnerDone = expectation(description: "winning restore completed")
        let loserDone = expectation(description: "losing restore completed")
        let winnerResult = LockedValue<DataBackup.BackupResult>()
        let loserResult = LockedValue<DataBackup.BackupResult>()
        let loserCopyCount = LockedValue<Int>(0)

        DispatchQueue.global().async {
            let result = DataBackup.restore(from: winnerBackup, toDatabaseAt: liveDB.path) { source, destination in
                winnerAtCopy.signal()
                releaseWinner.wait()
                try FileManager.default.copyItem(at: source, to: destination)
            }
            winnerResult.set(result)
            winnerDone.fulfill()
        }

        XCTAssertEqual(winnerAtCopy.wait(timeout: .now() + 2), .success,
                       "The winner must reserve and reach replacement without hanging")
        DispatchQueue.global().async {
            let result = DataBackup.restore(from: loserBackup, toDatabaseAt: liveDB.path) { source, destination in
                loserCopyCount.mutate { $0 += 1 }
                try FileManager.default.copyItem(at: source, to: destination)
            }
            loserResult.set(result)
            loserDone.fulfill()
        }

        wait(for: [loserDone], timeout: 2)
        releaseWinner.signal()
        wait(for: [winnerDone], timeout: 2)

        guard case .imported? = winnerResult.get() else {
            return XCTFail("The reserved restore must complete, got \(String(describing: winnerResult.get()))")
        }
        guard case .failure? = loserResult.get() else {
            return XCTFail("The overlapping restore must be rejected, got \(String(describing: loserResult.get()))")
        }
        XCTAssertEqual(loserCopyCount.get(), 0, "The losing restore must never touch the database pathname")
        XCTAssertEqual(try deviceRows(in: liveDB), ["winner"])
        XCTAssertTrue(StoreWriteBarrier.isSuspended,
                      "A losing attempt must not reopen the winner's barrier")
    }

    // MARK: - Settings round trip (#1000: restore brings back weight/height/settings)

    func testBackupWithSettingsRestoresSettingsAfterDbSwap() throws {
        let sourceDB = tmp.appendingPathComponent("source.sqlite")
        try makeNoopDatabase(at: sourceDB, deviceRows: ["my-whoop"])

        // Export with the whitelisted settings payload (what a real device writes from its defaults).
        let backup = tmp.appendingPathComponent("with-settings.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: sourceDB, to: backup, settings: [
            "profile.age": 34,
            "profile.sex": "female",
            "profile.weightKg": 62.5,
            "profile.heightCm": 168.0,
            "profile.hrMax": 191,
            "units.system": "imperial",
            "units.distance": "metric",
        ])

        // Restore into a throwaway DB path AND a suite-scoped defaults (never the runner's real domain).
        let defaults = try freshDefaults()
        let liveDB = tmp.appendingPathComponent("live.sqlite")
        let result = DataBackup.restore(from: backup, toDatabaseAt: liveDB.path, settingsDefaults: defaults)

        guard case .imported = result else {
            return XCTFail("Restore should succeed, got \(result)")
        }
        XCTAssertEqual(try deviceRows(in: liveDB), ["my-whoop"], "DB half still round-trips")
        XCTAssertEqual(defaults.object(forKey: "profile.age") as? Int, 34)
        XCTAssertEqual(defaults.string(forKey: "profile.sex"), "female")
        XCTAssertEqual(defaults.object(forKey: "profile.weightKg") as? Double, 62.5)
        XCTAssertEqual(defaults.object(forKey: "profile.heightCm") as? Double, 168.0)
        XCTAssertEqual(defaults.object(forKey: "profile.hrMaxOverride") as? Int, 191,
                       "Canonical profile.hrMax lands on ProfileStore's profile.hrMaxOverride key")
        XCTAssertEqual(defaults.string(forKey: "units.system"), "imperial")
        XCTAssertEqual(defaults.string(forKey: "units.distance"), "metric")
    }

    func testLegacySingleEntryZipStillRestoresAndAppliesNoSettings() throws {
        // A pre-#1000 backup: DB entry only (writeBackupForTesting with settings nil).
        let sourceDB = tmp.appendingPathComponent("source.sqlite")
        try makeNoopDatabase(at: sourceDB, deviceRows: ["legacy-strap"])
        let backup = tmp.appendingPathComponent("legacy.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: sourceDB, to: backup)

        let defaults = try freshDefaults()
        let liveDB = tmp.appendingPathComponent("live.sqlite")
        let result = DataBackup.restore(from: backup, toDatabaseAt: liveDB.path, settingsDefaults: defaults)

        guard case .imported = result else {
            return XCTFail("A legacy single-entry ZIP must restore exactly as today, got \(result)")
        }
        XCTAssertEqual(try deviceRows(in: liveDB), ["legacy-strap"])
        XCTAssertNil(defaults.object(forKey: "profile.age"), "No settings entry → defaults untouched")
        XCTAssertNil(defaults.object(forKey: "units.system"))
    }

    func testSettingsAreNotAppliedWhenTheRestoreIsRejected() throws {
        // A foreign (Room) DB zipped together WITH a settings payload: the origin gate refuses the
        // restore, so the settings must not leak through either ("apply AFTER the DB swap succeeds").
        let foreign = tmp.appendingPathComponent("foreign.sqlite")
        try makeForeignDatabase(at: foreign)
        let backup = tmp.appendingPathComponent("foreign.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: foreign, to: backup,
                                             settings: ["profile.age": 99, "profile.weightKg": 40.0])

        let defaults = try freshDefaults()
        let liveDB = tmp.appendingPathComponent("live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])

        let result = DataBackup.restore(from: backup, toDatabaseAt: liveDB.path, settingsDefaults: defaults)
        guard case .failure = result else {
            return XCTFail("Foreign backup must still be rejected, got \(result)")
        }
        XCTAssertNil(defaults.object(forKey: "profile.age"),
                     "A rejected restore must never apply the backup's settings")
        XCTAssertEqual(try deviceRows(in: liveDB), ["original"], "Live DB untouched")
    }

    // MARK: - Foreign SQLite is rejected, live DB untouched

    func testForeignSqliteIsRejectedAndLiveDbIntact() throws {
        // A Room/Android-flavoured DB: valid SQLite, but no `grdb_migrations`. It DOES hold a `device`
        // table, so the origin gate must refuse it (would otherwise strand the GRDB migrator).
        let foreign = tmp.appendingPathComponent("foreign.sqlite")
        try makeForeignDatabase(at: foreign)

        // Seed an existing live DB so we can prove it survives a rejected restore.
        let liveDB = tmp.appendingPathComponent("live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        let before = try Data(contentsOf: liveDB)

        let result = DataBackup.restore(from: foreign, toDatabaseAt: liveDB.path)
        guard case .failure = result else {
            return XCTFail("A foreign SQLite must be rejected, got \(result)")
        }
        XCTAssertEqual(try Data(contentsOf: liveDB), before,
                       "The live DB must be byte-for-byte unchanged after a rejected restore")
        XCTAssertEqual(try deviceRows(in: liveDB), ["original"])
    }

    // MARK: - Corrupt file is rejected, live DB untouched

    func testCorruptFileIsRejectedAndLiveDbIntact() throws {
        let corrupt = tmp.appendingPathComponent("corrupt.noopbak")
        try Data("this is not a database or a zip".utf8).write(to: corrupt)

        let liveDB = tmp.appendingPathComponent("live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        let before = try Data(contentsOf: liveDB)

        let result = DataBackup.restore(from: corrupt, toDatabaseAt: liveDB.path)
        guard case .failure = result else {
            return XCTFail("A corrupt file must be rejected, got \(result)")
        }
        XCTAssertEqual(try Data(contentsOf: liveDB), before,
                       "The live DB must be unchanged after a rejected restore")
    }

    func testZipWithNonCanonicalSqliteEntryIsRejectedAndLiveDbIntact() throws {
        let wrong = tmp.appendingPathComponent("wrong-entry.noopbak")
        let fake = tmp.appendingPathComponent("evil.sqlite")
        var bytes = Data("SQLite format 3".utf8)
        bytes.append(0)
        bytes.append(Data("junk".utf8))
        try bytes.write(to: fake)
        let archive = try XCTUnwrap(Archive(url: wrong, accessMode: .create))
        try archive.addEntry(with: "evil.sqlite", fileURL: fake)

        let liveDB = tmp.appendingPathComponent("live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        let before = try Data(contentsOf: liveDB)

        let result = DataBackup.restore(from: wrong, toDatabaseAt: liveDB.path)
        guard case .failure = result else {
            return XCTFail("A zip without noop-backup.sqlite must be rejected, got \(result)")
        }
        XCTAssertEqual(try Data(contentsOf: liveDB), before,
                       "The live DB must be unchanged after a rejected restore")
    }

    // MARK: - #1014: damaged-but-plausible backups are refused by the quick_check gate

    func testGarbageBehindSqliteMagicInsideZipIsRejectedAndLiveDbIntact() throws {
        // 16 valid magic bytes + junk, zipped as a real `.noopbak`: passes the container check AND
        // the magic check AND the origin gate (no readable sqlite_master → `.unknown`, holds no
        // data) — before #1014 this sailed all the way through to the swap. Only SQLite's own
        // `PRAGMA quick_check` sees it for what it is.
        let fake = tmp.appendingPathComponent("fake.sqlite")
        var bytes = Data("SQLite format 3".utf8)
        bytes.append(0x00)
        bytes.append(Data(repeating: 0x5A, count: 8192))
        try bytes.write(to: fake)
        let backup = tmp.appendingPathComponent("damaged.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: fake, to: backup)
        XCTAssertTrue(isZip(backup), "precondition: the damaged payload rides in a real ZIP")

        let liveDB = tmp.appendingPathComponent("live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        let before = try Data(contentsOf: liveDB)

        let result = DataBackup.restore(from: backup, toDatabaseAt: liveDB.path)
        guard case .failure = result else {
            return XCTFail("A structurally damaged backup must be rejected, got \(result)")
        }
        XCTAssertEqual(try Data(contentsOf: liveDB), before,
                       "The live DB must be byte-for-byte unchanged after the integrity rejection")
        XCTAssertEqual(try deviceRows(in: liveDB), ["original"])
    }

    func testTruncatedNoopBackupIsRejectedAndLiveDbIntact() throws {
        // A REAL NOOP database grown past one page, then truncated to its first page (the #1014
        // shape: a backup clipped mid-upload/mid-copy). Page 1 still reads perfectly — magic bytes
        // intact, `grdb_migrations` visible in sqlite_master — so the header and origin gates both
        // PASS. Only quick_check notices the file no longer holds the pages its header promises.
        let sourceDB = tmp.appendingPathComponent("big.sqlite")
        try makeMultiPageNoopDatabase(at: sourceDB)
        let fullSize = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: sourceDB.path))[.size] as? NSNumber
        ).int64Value
        XCTAssertGreaterThan(fullSize, 4096, "precondition: fixture spans multiple pages")

        let handle = try FileHandle(forWritingTo: sourceDB)
        try handle.truncate(atOffset: 4096)
        try handle.close()

        // Feed it through the legacy plain-SQLite path (truncation hits both container shapes the
        // same way; the ZIP shape is covered by the garbage test above).
        let liveDB = tmp.appendingPathComponent("live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        let before = try Data(contentsOf: liveDB)

        let result = DataBackup.restore(from: sourceDB, toDatabaseAt: liveDB.path)
        guard case .failure = result else {
            return XCTFail("A truncated backup must be rejected, got \(result)")
        }
        XCTAssertEqual(try Data(contentsOf: liveDB), before,
                       "The live DB must be unchanged after the integrity rejection")
    }

    // MARK: - Restore safety: pre-import snapshot must include committed WAL pages

    func testRestoreSidecarIncludesCommittedWalPages() throws {
        // The live app uses WAL. A committed row may therefore exist only in -wal while the main
        // sqlite file is still stale. The pre-restore sidecar promises to preserve the current store,
        // so it must represent the logical SQLite database, not merely memcpy the main file.
        let liveDB = tmp.appendingPathComponent("live-wal.sqlite")
        var live: OpaquePointer?
        guard sqlite3_open(liveDB.path, &live) == SQLITE_OK else { throw TestError("open live WAL DB failed") }
        defer { sqlite3_close(live) }
        try exec(live, "PRAGMA journal_mode=WAL")
        try exec(live, "PRAGMA wal_autocheckpoint=0")
        try exec(live, "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        try exec(live, "INSERT INTO grdb_migrations (identifier) VALUES ('v1')")
        try exec(live, "CREATE TABLE device (id TEXT NOT NULL PRIMARY KEY)")
        // Flush the schema, then add a row that stays committed in WAL.
        var checkpointLog: Int32 = 0
        var checkpointed: Int32 = 0
        XCTAssertEqual(sqlite3_wal_checkpoint_v2(live, nil, SQLITE_CHECKPOINT_TRUNCATE,
                                                  &checkpointLog, &checkpointed), SQLITE_OK)
        try exec(live, "INSERT INTO device (id) VALUES ('latest-live-row')")
        XCTAssertTrue(FileManager.default.fileExists(atPath: liveDB.path + "-wal"),
                      "precondition: latest committed row should be represented by WAL state")

        let replacement = tmp.appendingPathComponent("replacement.sqlite")
        try makeNoopDatabase(at: replacement, deviceRows: ["replacement"])
        let backup = tmp.appendingPathComponent("replacement.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: replacement, to: backup)

        let result = DataBackup.restore(from: backup, toDatabaseAt: liveDB.path)
        guard case .imported(let sidecar) = result else {
            return XCTFail("Restore should succeed, got \(result)")
        }
        XCTAssertEqual(try deviceRows(in: sidecar), ["latest-live-row"],
                       "Pre-restore sidecar must include committed rows that had not checkpointed out of WAL")
    }

    // MARK: - Prune deletes the oldest files past keep-N (real files)

    func testPruneDeletesOldestRealFilesPastKeepN() throws {
        let folder = tmp.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Five real snapshot files + one unrelated file.
        var names: [String] = []
        for i in 0..<5 {
            let name = BackupSync.snapshotName(1_782_000_000_000 + i * 60_000)
            names.append(name)
            try Data("backup \(i)".utf8).write(to: folder.appendingPathComponent(name))
        }
        try Data("keep".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        // Apply the pure prune selection to the real directory listing, then delete (the same two
        // steps `FolderBackup.prune` performs internally).
        let listing = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let toDelete = Set(BackupSync.snapshotsToPrune(listing, keep: 2))
        for name in listing where toDelete.contains(name) {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }

        let after = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        XCTAssertTrue(after.contains(names[4]), "Newest snapshot kept")
        XCTAssertTrue(after.contains(names[3]), "2nd-newest snapshot kept")
        XCTAssertFalse(after.contains(names[0]), "Oldest snapshot pruned")
        XCTAssertFalse(after.contains(names[1]))
        XCTAssertFalse(after.contains(names[2]))
        XCTAssertTrue(after.contains("notes.txt"), "Non-snapshot files are never pruned")
    }

    // MARK: - SQLite fixtures (system SQLite3)

    /// Build a minimal valid GRDB-origin NOOP DB: a `grdb_migrations` bookkeeping table (so the origin
    /// gate accepts it as this app's backup) plus a `device` table holding the given identifiers.
    private func makeNoopDatabase(at url: URL, deviceRows: [String]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw TestError("open failed: \(url.path)")
        }
        defer { sqlite3_close(db) }
        try exec(db, "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        try exec(db, "INSERT INTO grdb_migrations (identifier) VALUES ('v1')")
        try exec(db, "CREATE TABLE device (id TEXT NOT NULL PRIMARY KEY)")
        for id in deviceRows {
            try exec(db, "INSERT INTO device (id) VALUES ('\(id)')")
        }
    }

    /// Build a valid GRDB-origin NOOP DB that spans MULTIPLE pages, so a truncation fixture can cut
    /// real pages off while page 1 (magic + sqlite_master) stays perfectly readable (#1014).
    private func makeMultiPageNoopDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw TestError("open failed: \(url.path)")
        }
        defer { sqlite3_close(db) }
        try exec(db, "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        try exec(db, "INSERT INTO grdb_migrations (identifier) VALUES ('v1')")
        try exec(db, "CREATE TABLE device (id TEXT NOT NULL PRIMARY KEY, blob TEXT NOT NULL)")
        let filler = String(repeating: "x", count: 200)
        for i in 0..<200 {
            try exec(db, "INSERT INTO device (id, blob) VALUES ('row-\(i)', '\(filler)')")
        }
    }

    /// Build a valid SQLite file that is NOT a NOOP/GRDB backup: it carries the Room marker and a
    /// `device` table but no `grdb_migrations`, so the origin gate must reject it.
    private func makeForeignDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw TestError("open failed: \(url.path)")
        }
        defer { sqlite3_close(db) }
        try exec(db, "CREATE TABLE room_master_table (id INTEGER PRIMARY KEY, identity_hash TEXT)")
        try exec(db, "CREATE TABLE device (id TEXT NOT NULL PRIMARY KEY)")
        try exec(db, "INSERT INTO device (id) VALUES ('android-strap')")
    }

    private func deviceRows(in url: URL) throws -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw TestError("open (read) failed: \(url.path)")
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM device ORDER BY id", -1, &stmt, nil) == SQLITE_OK else {
            throw TestError("prepare failed")
        }
        defer { sqlite3_finalize(stmt) }
        var rows: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { rows.append(String(cString: c)) }
        }
        return rows.sorted()
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw TestError("exec failed (\(message)): \(sql)")
        }
    }

    private func isZip(_ url: URL) -> Bool {
        guard let head = try? FileHandle(forReadingFrom: url).read(upToCount: 4), head.count >= 4 else { return false }
        return Array(head).prefix(4) == [0x50, 0x4B, 0x03, 0x04]
    }

    private struct TestError: Error { let message: String; init(_ m: String) { message = m } }
}
