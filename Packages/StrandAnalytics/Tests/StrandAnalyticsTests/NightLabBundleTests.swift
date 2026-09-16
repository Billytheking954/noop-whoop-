import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class NightLabBundleTests: XCTestCase {
    private func tempRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NightLabBundleTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func manifest(_ id: String) -> NightRecordManifest {
        NightRecordManifest(nightID: id,
                            state: .recording,
                            windowStartUnix: 1_000,
                            windowEndUnix: 1_100,
                            timezoneOffsetSeconds: 0,
                            sourceDeviceID: "bundle-test-device",
                            sourceDeviceModel: "WHOOP 5.0",
                            sourceFirmware: "test",
                            sourceStoreSchemaVersion: 18,
                            sourceStreamFingerprint: "bundle-source-witness",
                            noopVersion: "test",
                            rawAssets: [])
    }

    private func makeArchive(root: URL, nightID: String, bpm: Int = 60) async throws -> NightLabFileStore {
        let store = NightLabFileStore(rootDirectory: root)
        try await store.createNight(manifest(nightID))
        let rows = [HRSample(ts: 1_000, bpm: bpm), HRSample(ts: 1_001, bpm: bpm + 1)]
        _ = try await store.appendRawAsset(nightID: nightID,
                                           assetID: "hr",
                                           kind: .heartRate,
                                           fileName: "hr.json",
                                           data: try NightLabJSON.encode(rows),
                                           startUnix: 1_000,
                                           endUnix: 1_002,
                                           sampleCount: rows.count,
                                           expectedCadenceHz: 1)
        _ = try await store.sealNight(nightID: nightID)
        return store
    }

    func testExportIsDeterministicAndRoundTripPreservesAllNamespaces() async throws {
        let sourceRoot = try tempRoot("source")
        let targetRoot = try tempRoot("target")
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: targetRoot)
        }
        let source = try await makeArchive(root: sourceRoot, nightID: "portable-night")
        let reference = NightReferenceLabels(nightID: "portable-night", provider: "whoop",
                                             importedAtUnix: 2_000,
                                             summary: ["recovery": 73, "sleepMinutes": 421])
        try await source.saveReference(reference, for: "portable-night")
        let run = NightAlgorithmRun(nightID: "portable-night",
                                    algorithm: NightAlgorithmIdentity(id: "audit", version: "1"),
                                    inputSchemaVersion: NightRecordManifest.currentSchemaVersion,
                                    runAtUnix: 2_100,
                                    outputJSON: "{\"ok\":true}")
        try await source.saveRun(run)

        let first = try await source.exportBundle(nightID: "portable-night")
        let second = try await source.exportBundle(nightID: "portable-night")
        XCTAssertEqual(first, second)

        let target = NightLabFileStore(rootDirectory: targetRoot)
        let imported = try await target.importBundle(first)
        XCTAssertEqual(imported.disposition, .imported)
        XCTAssertEqual(imported.bundleSHA256, NightLabFileStore.sha256Hex(first))
        let roundTripped = try await target.exportBundle(nightID: "portable-night")
        XCTAssertEqual(roundTripped, first)

        let streams = try await NightLabArchiveLoader.load(archive: target, nightID: "portable-night")
        XCTAssertEqual(streams.hr.map(\.bpm), [60, 61])
        let referenceURL = targetRoot.appendingPathComponent(
            "NightLab/portable-night/references/whoop_2000.json"
        )
        XCTAssertEqual(try NightLabJSON.decode(NightReferenceLabels.self,
                                               from: Data(contentsOf: referenceURL)), reference)

        let repeated = try await target.importBundle(first)
        XCTAssertEqual(repeated.disposition, .alreadyPresent)
    }

    func testCorruptEntryIsRejectedBeforeAnythingIsPublished() async throws {
        let sourceRoot = try tempRoot("corrupt-source")
        let targetRoot = try tempRoot("corrupt-target")
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: targetRoot)
        }
        let source = try await makeArchive(root: sourceRoot, nightID: "corrupt-night")
        let data = try await source.exportBundle(nightID: "corrupt-night")
        let decoded = try NightLabJSON.decode(NightLabBundle.self, from: data)
        let entries = decoded.files.map { entry in
            entry.relativePath == "raw/hr.json"
                ? NightLabBundleEntry(relativePath: entry.relativePath, sha256: entry.sha256,
                                      byteCount: entry.byteCount, data: Data("tampered".utf8))
                : entry
        }
        let corrupt = try NightLabJSON.encode(NightLabBundle(nightID: decoded.nightID, files: entries))
        let target = NightLabFileStore(rootDirectory: targetRoot)

        do {
            _ = try await target.importBundle(corrupt)
            XCTFail("entry hash mismatch must reject the entire bundle")
        } catch let error as NightLabBundleError {
            XCTAssertEqual(error, .corruptEntry("raw/hr.json"))
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: targetRoot.appendingPathComponent("NightLab/corrupt-night").path
        ))
    }

    func testSemanticallyInvalidRawDataRollsBackStagingArchive() async throws {
        let sourceRoot = try tempRoot("semantic-source")
        let targetRoot = try tempRoot("semantic-target")
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: targetRoot)
        }
        let source = try await makeArchive(root: sourceRoot, nightID: "semantic-night")
        let data = try await source.exportBundle(nightID: "semantic-night")
        let decoded = try NightLabJSON.decode(NightLabBundle.self, from: data)
        let invalidBytes = Data("not-json".utf8)
        let entries = decoded.files.map { entry in
            entry.relativePath == "raw/hr.json"
                ? NightLabBundleEntry(relativePath: entry.relativePath,
                                      sha256: NightLabFileStore.sha256Hex(invalidBytes),
                                      byteCount: invalidBytes.count,
                                      data: invalidBytes)
                : entry
        }
        let invalid = try NightLabJSON.encode(NightLabBundle(nightID: decoded.nightID, files: entries))
        let target = NightLabFileStore(rootDirectory: targetRoot)

        do {
            _ = try await target.importBundle(invalid)
            XCTFail("typed replay validation must reject invalid raw rows")
        } catch {
            // The exact decoder error is intentionally not part of the bundle API.
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: targetRoot.appendingPathComponent("NightLab/semantic-night").path
        ))
    }

    func testUnsafeAndDuplicatePathsAreRejected() async throws {
        let sourceRoot = try tempRoot("path-source")
        let targetRoot = try tempRoot("path-target")
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: targetRoot)
        }
        let source = try await makeArchive(root: sourceRoot, nightID: "path-night")
        let data = try await source.exportBundle(nightID: "path-night")
        let decoded = try NightLabJSON.decode(NightLabBundle.self, from: data)
        let bad = NightLabBundleEntry(relativePath: "raw/../escape.json",
                                      sha256: NightLabFileStore.sha256Hex(Data()),
                                      byteCount: 0,
                                      data: Data())
        let unsafeFiles = (decoded.files + [bad]).sorted { $0.relativePath < $1.relativePath }
        let unsafe = try NightLabJSON.encode(NightLabBundle(nightID: decoded.nightID, files: unsafeFiles))
        let target = NightLabFileStore(rootDirectory: targetRoot)
        do {
            _ = try await target.importBundle(unsafe)
            XCTFail("path traversal must be rejected")
        } catch let error as NightLabBundleError {
            XCTAssertEqual(error, .unsafePath("raw/../escape.json"))
        }

        let duplicateFiles = (decoded.files + [decoded.files[0]]).sorted { $0.relativePath < $1.relativePath }
        let duplicate = try NightLabJSON.encode(
            NightLabBundle(nightID: decoded.nightID, files: duplicateFiles)
        )
        do {
            _ = try await target.importBundle(duplicate)
            XCTFail("duplicate members must be rejected")
        } catch let error as NightLabBundleError {
            XCTAssertEqual(error, .duplicatePath(decoded.files[0].relativePath))
        }
    }

    func testExistingDifferentNightIsNeverOverwritten() async throws {
        let sourceRoot = try tempRoot("conflict-source")
        let targetRoot = try tempRoot("conflict-target")
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: targetRoot)
        }
        let source = try await makeArchive(root: sourceRoot, nightID: "same-id", bpm: 60)
        let incoming = try await source.exportBundle(nightID: "same-id")
        let target = try await makeArchive(root: targetRoot, nightID: "same-id", bpm: 90)
        let before = try await target.exportBundle(nightID: "same-id")

        do {
            _ = try await target.importBundle(incoming)
            XCTFail("different evidence must never replace an existing night")
        } catch let error as NightLabBundleError {
            XCTAssertEqual(error, .targetConflict("same-id"))
        }
        let after = try await target.exportBundle(nightID: "same-id")
        XCTAssertEqual(after, before)
    }
}
