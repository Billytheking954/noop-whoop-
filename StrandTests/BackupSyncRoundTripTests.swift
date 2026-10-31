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
        let result = DataBackup.restore(from: backup, toDatabaseAt: liveDB.path, copyItem: { source, destination in
            copyCalls += 1
            if copyCalls == 1 { throw TestError("injected replacement-copy failure") }
            try FileManager.default.copyItem(at: source, to: destination)
        })

        guard case .failure(let message) = result else {
            return XCTFail("Injected replacement-copy failure must fail restore, got \(result)")
        }
        XCTAssertEqual(copyCalls, 2, "The second copy must restore the rollback snapshot")
        XCTAssertEqual(try deviceRows(in: liveDB), ["original"])
        XCTAssertTrue(message.contains("existing data was kept"))
        XCTAssertTrue(StoreWriteBarrier.isSuspended,
                      "Unlinking the pathname makes old pools stale even when rollback succeeds")
    }

    func testFailedCopyToFreshDestinationRemovesPartialDatabaseBeforeRelaunch() throws {
        let source = tmp.appendingPathComponent("fresh-failed-copy-source.sqlite")
        try makeNoopDatabase(at: source, deviceRows: ["replacement"])
        let liveDB = tmp.appendingPathComponent("fresh-partial-live.sqlite")
        let result = DataBackup.restore(from: source, toDatabaseAt: liveDB.path,
            copyItem: { _, destination in
                try Data("incomplete database".utf8).write(to: destination)
                throw TestError("injected partial-copy failure")
            })
        guard case .failure = result else { return XCTFail("A partial copy must fail restore") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveDB.path),
                       "A corrupt partial file must not block database creation on the next launch")
        XCTAssertTrue(StoreWriteBarrier.isSuspended)
        StoreWriteBarrier.resumeAfterFailedRestore() // Model a new process with no stale pools.
        guard case .imported = DataBackup.restore(from: source, toDatabaseAt: liveDB.path) else {
            return XCTFail("A clean retry after relaunch must succeed")
        }
        XCTAssertEqual(try deviceRows(in: liveDB), ["replacement"])
    }

    func testRollbackCopyFailureIsReportedHonestlyAndPreservesRecoverySnapshot() throws {
        let sourceDB = tmp.appendingPathComponent("rollback-failure-source.sqlite")
        try makeNoopDatabase(at: sourceDB, deviceRows: ["replacement"])
        let backup = tmp.appendingPathComponent("rollback-failure.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: sourceDB, to: backup)

        let liveDB = tmp.appendingPathComponent("live-rollback-failure.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        let result = DataBackup.restore(from: backup, toDatabaseAt: liveDB.path, copyItem: { _, _ in
            throw TestError("injected copy failure")
        })

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
            includingPropertiesForKeys: nil).filter {
                $0.lastPathComponent.hasPrefix("whoop-replaced-") && $0.pathExtension == "sqlite"
            }
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
        let result = DataBackup.restore(from: backup, toDatabaseAt: liveDB.path, copyItem: { source, destination in
            copyCalls += 1
            try FileManager.default.copyItem(at: source, to: destination)
            // Simulate a torn filesystem copy after both the replacement and rollback operations claim
            // success. The rollback helper must independently verify what landed.
            try Data(repeating: 0x41, count: 4096).write(to: destination)
        })

        guard case .failure(let message) = result else {
            return XCTFail("A torn landed database must fail restore, got \(result)")
        }
        XCTAssertEqual(copyCalls, 2)
        XCTAssertFalse(message.contains("rolled back automatically and is unchanged"),
                       "A corrupt rollback copy must never be reported as successful")
        XCTAssertTrue(message.contains("Recovery snapshot:"))
        XCTAssertTrue(StoreWriteBarrier.isSuspended)

        let snapshots = try FileManager.default.contentsOfDirectory(at: tmp,
            includingPropertiesForKeys: nil).filter {
                $0.lastPathComponent.hasPrefix("whoop-replaced-") && $0.pathExtension == "sqlite"
            }
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
            let result = DataBackup.restore(from: winnerBackup, toDatabaseAt: liveDB.path, copyItem: { source, destination in
                winnerAtCopy.signal()
                releaseWinner.wait()
                try FileManager.default.copyItem(at: source, to: destination)
            })
            winnerResult.set(result)
            winnerDone.fulfill()
        }

        XCTAssertEqual(winnerAtCopy.wait(timeout: .now() + 2), .success,
                       "The winner must reserve and reach replacement without hanging")
        DispatchQueue.global().async {
            let result = DataBackup.restore(from: loserBackup, toDatabaseAt: liveDB.path, copyItem: { source, destination in
                loserCopyCount.mutate { $0 += 1 }
                try FileManager.default.copyItem(at: source, to: destination)
            })
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

    func testFutureSchemaBackupLeavesDestinationAndWriteGateUntouched() throws {
        let source = tmp.appendingPathComponent("future.sqlite")
        try makeNoopDatabase(at: source, deviceRows: ["future"])
        var db: OpaquePointer?
        guard sqlite3_open(source.path, &db) == SQLITE_OK else { throw TestError("open future fixture") }
        defer { sqlite3_close(db) }
        try exec(db, "INSERT INTO grdb_migrations VALUES ('v50-future-schema')")
        let backup = tmp.appendingPathComponent("future.noopbak")
        try DataBackup.writeBackupForTesting(databaseAt: source, to: backup, verifiedSnapshot: true)
        let destination = tmp.appendingPathComponent("destination.sqlite")
        try makeNoopDatabase(at: destination, deviceRows: ["preserved"])
        let before = try Data(contentsOf: destination)
        guard case .failure(let message) = DataBackup.restore(from: backup, toDatabaseAt: destination.path) else {
            return XCTFail("Future-schema restore must be refused")
        }
        XCTAssertTrue(message.contains("unsafe downgrade"))
        XCTAssertEqual(try Data(contentsOf: destination), before)
        XCTAssertFalse(StoreWriteBarrier.isSuspended)
    }

    func testV49IdentityLedgersSurviveNoopbakRestore() throws {
        // Regression for clean-branch compatibility with a database that Aura
        // already upgraded. All file paths below are disposable test fixtures.
        let sourceDB = tmp.appendingPathComponent("v49-source.sqlite")
        try makeNoopDatabase(at: sourceDB, deviceRows: ["my-whoop"])
        var db: OpaquePointer?
        guard sqlite3_open(sourceDB.path, &db) == SQLITE_OK else { throw TestError("open v49 fixture") }
        defer { sqlite3_close(db) }
        do {
            try exec(db, "PRAGMA journal_mode=WAL")
            try exec(db, "PRAGMA wal_autocheckpoint=0")
            try exec(db, "INSERT INTO grdb_migrations (identifier) VALUES ('v48-apple-health-workout-identity')")
            try exec(db, "INSERT INTO grdb_migrations (identifier) VALUES ('v49-apple-health-sample-identity')")
            try exec(db, """
                CREATE TABLE appleHealthWorkoutIdentity (
                  deviceId TEXT NOT NULL, uuid TEXT NOT NULL, startTs INTEGER NOT NULL,
                  sport TEXT NOT NULL, day TEXT NOT NULL
                )
                """)
            try exec(db, """
                CREATE TABLE appleHealthSampleIdentity (
                  deviceId TEXT NOT NULL, typeIdentifier TEXT NOT NULL, uuid TEXT NOT NULL,
                  day TEXT NOT NULL, startTs INTEGER NOT NULL, value DOUBLE,
                  PRIMARY KEY (deviceId, typeIdentifier, uuid)
                )
                """)
            try exec(db, """
                INSERT INTO appleHealthWorkoutIdentity (deviceId, uuid, startTs, sport, day)
                VALUES ('apple-health', 'v49-workout', 1000, 'walking', '2026-10-25')
                """)
            try exec(db, """
                INSERT INTO appleHealthSampleIdentity (deviceId, typeIdentifier, uuid, day, startTs, value)
                VALUES ('apple-health', 'dietaryWater', 'v49-water', '2026-10-25', 1100, 250)
                """)
        } catch {
            throw error
        }
        let backup = tmp.appendingPathComponent("v49-backup.noopbak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceDB.path + "-wal"))
        try DataBackup.writeBackupForTesting(databaseAt: sourceDB, to: backup, verifiedSnapshot: true)
        let restoredDB = tmp.appendingPathComponent("v49-restored.sqlite")
        guard case .imported = DataBackup.restore(from: backup, toDatabaseAt: restoredDB.path) else {
            return XCTFail("v49 snapshot must restore to an isolated location")
        }
        XCTAssertEqual(try deviceRows(in: restoredDB), ["my-whoop"])
        XCTAssertEqual(try singleText(in: restoredDB,
            query: "SELECT uuid FROM appleHealthWorkoutIdentity"), "v49-workout")
        XCTAssertEqual(try singleText(in: restoredDB,
            query: "SELECT uuid FROM appleHealthSampleIdentity"), "v49-water")
        XCTAssertEqual(try singleText(in: restoredDB,
            query: "SELECT identifier FROM grdb_migrations WHERE identifier = 'v49-apple-health-sample-identity'"),
                           "v49-apple-health-sample-identity")
    }

    private func singleText(in url: URL, query: String) throws -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw TestError("read failed: \(url.path)")
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            throw TestError("prepare failed: \(query)")
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else {
            return nil
        }
        return String(cString: text)
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

    func testForeignSchemaWithoutDeviceOrHrTablesIsAlsoRejected() throws {
        let foreign = tmp.appendingPathComponent("unmarked-foreign.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(foreign.path, &db) == SQLITE_OK else { throw TestError("open foreign failed") }
        defer { sqlite3_close(db) }
        try exec(db, "CREATE TABLE externalHistory (id TEXT)")
        try exec(db, "INSERT INTO externalHistory VALUES ('another-app')")
        let liveDB = tmp.appendingPathComponent("unmarked-foreign-live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        let before = try Data(contentsOf: liveDB)

        guard case .failure = DataBackup.restore(from: foreign, toDatabaseAt: liveDB.path) else {
            return XCTFail("An unmarked non-empty foreign schema must never replace NOOP history")
        }
        XCTAssertEqual(try Data(contentsOf: liveDB), before)
        XCTAssertEqual(try deviceRows(in: liveDB), ["original"])
        XCTAssertFalse(StoreWriteBarrier.isSuspended)
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

    func testLegacyWalRestoreLandsSelfContainedDatabaseWithoutMutatingSelectedBackup() throws {
        let source = try makeDetachedWalBackup()
        let wal = URL(fileURLWithPath: source.path + "-wal")
        let originalMain = try Data(contentsOf: source)
        let originalWal = try Data(contentsOf: wal)
        let liveDB = tmp.appendingPathComponent("legacy-wal-restored.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])

        let result = DataBackup.restore(from: source, toDatabaseAt: liveDB.path)
        guard case .imported = result else {
            return XCTFail("A legacy backup with committed WAL must restore, got \(result)")
        }
        // Check before querying: opening a WAL-mode database can create these files itself.
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveDB.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveDB.path + "-shm"))
        XCTAssertEqual(try deviceRows(in: liveDB), ["wal-only-row"])
        XCTAssertEqual(try Data(contentsOf: source), originalMain)
        XCTAssertEqual(try Data(contentsOf: wal), originalWal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path + "-shm"),
                       "All SQLite probing must happen on private staged files")
        XCTAssertTrue(StoreWriteBarrier.isSuspended)
    }

    func testFailedWalRemovalAbortsReplacementAndRecoversLogicalLiveRows() throws {
        let source = tmp.appendingPathComponent("removal-source.sqlite")
        try makeNoopDatabase(at: source, deviceRows: ["replacement"])
        let liveDB = try makeDetachedWalBackup()
        var walRemovals = 0
        var copiedDestinations: [URL] = []
        let result = DataBackup.restore(from: source, toDatabaseAt: liveDB.path,
            removeItem: { url in
                if url.path == liveDB.path + "-wal" {
                    walRemovals += 1
                    if walRemovals == 1 { throw TestError("injected WAL removal failure") }
                }
                try FileManager.default.removeItem(at: url)
            }, copyItem: { source, destination in
                copiedDestinations.append(destination)
                try FileManager.default.copyItem(at: source, to: destination)
            })

        guard case .failure(let message) = result else {
            return XCTFail("Failed WAL removal must fail restore even when rollback succeeds, got \(result)")
        }
        XCTAssertEqual(walRemovals, 2, "Rollback must retry removal before copying the recovery database")
        XCTAssertEqual(copiedDestinations, [liveDB], "Only the recovery copy may land at the live path")
        XCTAssertTrue(message.contains("existing data was kept"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveDB.path + "-wal"))
        XCTAssertEqual(try deviceRows(in: liveDB), ["wal-only-row"])
        XCTAssertTrue(StoreWriteBarrier.isSuspended)
    }

    func testPersistentWalRemovalFailureReportsRecoverySnapshotWithoutClaimingRollback() throws {
        let source = tmp.appendingPathComponent("persistent-removal-source.sqlite")
        try makeNoopDatabase(at: source, deviceRows: ["replacement"])
        let liveDB = try makeDetachedWalBackup()
        var liveCopies = 0
        // The directory can contain derived SQLite files as well as the actual recovery main file.
        let derived = tmp.appendingPathComponent("whoop-replaced-decoy.sqlite-shm")
        try Data("derived index; not a SQLite main database".utf8).write(to: derived)
        let result = DataBackup.restore(from: source, toDatabaseAt: liveDB.path,
            removeItem: { url in
                if url.path == liveDB.path + "-wal" { throw TestError("persistent WAL removal failure") }
                try FileManager.default.removeItem(at: url)
            }, copyItem: { source, destination in
                liveCopies += 1
                try FileManager.default.copyItem(at: source, to: destination)
            })

        guard case .failure(let message) = result else {
            return XCTFail("Persistent cleanup failure must be disclosed, got \(result)")
        }
        XCTAssertEqual(liveCopies, 0, "Neither replacement nor recovery may land beside an uncleared WAL")
        XCTAssertFalse(message.contains("existing data was kept"))
        XCTAssertTrue(message.contains("Recovery snapshot:"))
        let snapshots = try FileManager.default.contentsOfDirectory(at: tmp,
            includingPropertiesForKeys: nil).filter {
                $0.lastPathComponent.hasPrefix("whoop-replaced-") && $0.pathExtension == "sqlite"
            }
        XCTAssertEqual(snapshots.count, 1, "Recovery verification must select only the main SQLite snapshot")
        let recovery = try XCTUnwrap(snapshots.first)
        XCTAssertTrue(message.contains(recovery.path), "The verified file must be the recovery snapshot named in the error")
        XCTAssertEqual(try deviceRows(in: recovery), ["wal-only-row"])
        XCTAssertTrue(StoreWriteBarrier.isSuspended)
    }

    func testLegacyWalCopyFailureLeavesLiveDatabaseAndSettingsUntouched() throws {
        let source = try makeDetachedWalBackup()
        let liveDB = tmp.appendingPathComponent("legacy-wal-copy-failure.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        let before = try Data(contentsOf: liveDB)
        let defaults = try freshDefaults()
        defaults.set(24, forKey: "profile.age")
        var replacementCopies = 0

        let result = DataBackup.restore(from: source, toDatabaseAt: liveDB.path,
            settingsDefaults: defaults, stageCopyItem: { source, destination in
                if source.path.hasSuffix("-wal") { throw TestError("injected WAL copy failure") }
                try FileManager.default.copyItem(at: source, to: destination)
            }, copyItem: { source, destination in
                replacementCopies += 1
                try FileManager.default.copyItem(at: source, to: destination)
            })

        guard case .failure = result else {
            return XCTFail("A failed WAL copy must abort before replacement, got \(result)")
        }
        XCTAssertEqual(replacementCopies, 0)
        XCTAssertEqual(try Data(contentsOf: liveDB), before)
        XCTAssertEqual(try deviceRows(in: liveDB), ["original"])
        XCTAssertEqual(defaults.integer(forKey: "profile.age"), 24)
        XCTAssertFalse(StoreWriteBarrier.isSuspended)
    }

    func testCorruptLegacyWalIsRejectedBeforeHealthyButStaleMainCanReplaceLiveData() throws {
        for offset in [0, 32 + 24 + 100] {
            let source = try makeDetachedWalBackup()
            let wal = URL(fileURLWithPath: source.path + "-wal")
            var bytes = try Data(contentsOf: wal)
            bytes[offset] ^= 1
            try bytes.write(to: wal)
            let liveDB = tmp.appendingPathComponent("corrupt-wal-live-\(offset).sqlite")
            try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
            let before = try Data(contentsOf: liveDB)

            guard case .failure = DataBackup.restore(from: source, toDatabaseAt: liveDB.path) else {
                return XCTFail("Corrupt WAL must not become an apparently healthy, incomplete restore")
            }
            XCTAssertEqual(try Data(contentsOf: liveDB), before)
            XCTAssertFalse(StoreWriteBarrier.isSuspended)
        }
    }

    func testTornLegacyStagingCopyIsRejectedBeforeLivePathOrBarrierChanges() throws {
        let source = tmp.appendingPathComponent("legacy-torn-source.sqlite")
        try makeNoopDatabase(at: source, deviceRows: ["replacement"])
        let liveDB = tmp.appendingPathComponent("legacy-torn-live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        let before = try Data(contentsOf: liveDB)

        let result = DataBackup.restore(from: source, toDatabaseAt: liveDB.path,
            stageCopyItem: { source, destination in
                try FileManager.default.copyItem(at: source, to: destination)
                let handle = try FileHandle(forWritingTo: destination)
                try handle.truncate(atOffset: 100)
                try handle.close()
            })

        guard case .failure = result else {
            return XCTFail("A torn staging copy must fail before replacement, got \(result)")
        }
        XCTAssertEqual(try Data(contentsOf: liveDB), before)
        XCTAssertFalse(StoreWriteBarrier.isSuspended)
    }

    func testShmSiblingCannotBypassPreSwapIntegrityCheck() throws {
        let source = tmp.appendingPathComponent("damaged-with-shm.sqlite")
        try makeMultiPageNoopDatabase(at: source)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 4096)
        try handle.close()
        try Data(repeating: 0, count: 32).write(to: URL(fileURLWithPath: source.path + "-shm"))
        let liveDB = tmp.appendingPathComponent("shm-live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        let before = try Data(contentsOf: liveDB)

        guard case .failure = DataBackup.restore(from: source, toDatabaseAt: liveDB.path) else {
            return XCTFail("A derived SHM sibling must not disable the integrity gate")
        }
        XCTAssertEqual(try Data(contentsOf: liveDB), before)
        XCTAssertFalse(StoreWriteBarrier.isSuspended,
                       "A damaged backup must be rejected before any live-path replacement")
    }

    func testRecoverySnapshotHasUniqueSuffixAndEarlierSnapshotsSurvive() throws {
        let source = tmp.appendingPathComponent("unique-snapshot-source.sqlite")
        try makeNoopDatabase(at: source, deviceRows: ["replacement"])
        let liveDB = tmp.appendingPathComponent("unique-snapshot-live.sqlite")
        try makeNoopDatabase(at: liveDB, deviceRows: ["original"])
        let earlierSnapshot = tmp.appendingPathComponent("whoop-replaced-earlier.sqlite")
        try makeNoopDatabase(at: earlierSnapshot, deviceRows: ["earlier"])

        guard case .imported(let snapshot) = DataBackup.restore(from: source, toDatabaseAt: liveDB.path) else {
            return XCTFail("Restore must succeed")
        }
        let name = snapshot.deletingPathExtension().lastPathComponent
        XCTAssertNotNil(UUID(uuidString: String(name.suffix(36))),
                        "Timestamp alone cannot uniquely identify preserved recovery copies")
        XCTAssertEqual(try deviceRows(in: snapshot), ["original"])
        XCTAssertEqual(try deviceRows(in: earlierSnapshot), ["earlier"])
    }

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

    /// Copy a main/WAL pair while its writer is open, without SHM. Even the schema remains in WAL,
    /// so inspecting the main file alone yields a healthy empty database and misses every row.
    private func makeDetachedWalBackup() throws -> URL {
        let writerURL = tmp.appendingPathComponent("wal-writer-\(UUID().uuidString).sqlite")
        var writer: OpaquePointer?
        guard sqlite3_open(writerURL.path, &writer) == SQLITE_OK else { throw TestError("open WAL writer failed") }
        defer { sqlite3_close(writer) }
        try exec(writer, "PRAGMA journal_mode=WAL")
        try exec(writer, "PRAGMA wal_autocheckpoint=0")
        try exec(writer, "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        try exec(writer, "INSERT INTO grdb_migrations VALUES ('v1')")
        try exec(writer, "CREATE TABLE device (id TEXT NOT NULL PRIMARY KEY)")
        try exec(writer, "INSERT INTO device VALUES ('wal-only-row')")
        let source = tmp.appendingPathComponent("detached-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: writerURL, to: source)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: writerURL.path + "-wal"),
                                        to: URL(fileURLWithPath: source.path + "-wal"))
        return source
    }

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
            throw TestError("prepare failed: \(url.path)")
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
