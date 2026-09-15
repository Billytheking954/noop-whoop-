import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class NightLabInspectionTests: XCTestCase {
    private func fixture(schema: Int = 2, sealed: Bool = true) async throws -> (URL, NightLabFileStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NightLabFileStore(rootDirectory: root)
        try await store.createNight(NightRecordManifest(schemaVersion: schema, nightID: "night", state: .recording,
            windowStartUnix: 31, windowEndUnix: 95, timezoneOffsetSeconds: 3600,
            sourceDeviceID: "device", sourceDeviceModel: "WHOOP 5", sourceFirmware: "firmware",
            sourceStoreSchemaVersion: 18, sourceStreamFingerprint: "fingerprint", noopVersion: "test", rawAssets: []))
        let hr = (31..<95).map { HRSample(ts: $0, bpm: 60) }
        try await store.appendRawAsset(nightID: "night", assetID: "hr", kind: .heartRate, fileName: "hr.json",
            data: NightLabJSON.encode(hr), startUnix: 31, endUnix: 95, sampleCount: hr.count)
        let gravity = [31, 32, 90].map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        try await store.appendRawAsset(nightID: "night", assetID: "gravity", kind: .accelerometer,
            fileName: "gravity.json", data: NightLabJSON.encode(gravity), startUnix: 31, endUnix: 95,
            sampleCount: gravity.count)
        if sealed { try await store.sealNight(nightID: "night") }
        return (root, store)
    }

    private func baseline(_ store: NightLabFileStore) async throws -> Data {
        let m = try await store.loadManifest(nightID: "night")
        // Hand-authored saved result: no stager/runner call, so inspection cannot depend on recomputation.
        let artifact = SleepStagerV2BaselineArtifact(nightID: m.nightID,
            algorithm: NightAlgorithmIdentity(id: "sleep-stager-v2", version: "2", build: "blob"),
            implementation: SleepStagerV2ImplementationIdentity(noopCommitSHA: "commit", stagerSourceBlobSHA: "blob"),
            manifestSchemaVersion: m.schemaVersion, sourceStreamFingerprint: m.sourceStreamFingerprint,
            sourceDeviceID: m.sourceDeviceID, sourceDeviceModel: m.sourceDeviceModel, sourceFirmware: m.sourceFirmware,
            sourceStoreSchemaVersion: m.sourceStoreSchemaVersion, sourceNOOPVersion: m.noopVersion,
            timezoneOffsetSeconds: m.timezoneOffsetSeconds,
            inputAssets: m.rawAssets.sorted { $0.id < $1.id }.map {
                SleepStagerV2InputAssetIdentity(assetID: $0.id, kind: $0.kind, sha256: $0.digest!,
                                                sampleCount: $0.sampleCount, usedByStager: true)
            }, windowStartUnix: 31, windowEndUnix: 95,
            productionSegments: [StageSegment(start: 31, end: 95, stage: "rem")],
            leadingBoundary: SleepStagerV2BaselineBoundary(startUnix: 31, endUnix: 60, stage: .rem),
            epochs: [SleepStagerV2BaselineEpoch(startUnix: 60, endUnix: 90, stage: .rem),
                     SleepStagerV2BaselineEpoch(startUnix: 90, endUnix: 95, stage: .rem)])
        let bytes = try NightLabJSON.encode(artifact)
        try await store.saveDeterministicDerivedArtifact(nightID: "night",
            fileName: NightLabSleepStagerV2BaselineRunner.baselineFileName, data: bytes)
        return bytes
    }

    private func snapshot(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in files {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(url.path.dropFirst(root.path.count))] = try Data(contentsOf: url)
            }
        }
        return result
    }

    func testInspectionPreservesWindowProvenanceAndCoverage() async throws {
        let (root, store) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let result = try await NightLabInspection.load(archive: store, nightID: "night")
        let manifest = try await store.loadManifest(nightID: "night")
        XCTAssertEqual(result.manifest, manifest)
        XCTAssertEqual(NightLabInspectionFormatting.interval(start: manifest.windowStartUnix, end: manifest.windowEndUnix), "[31,95)")
        let hr = try XCTUnwrap(result.coverage.first { $0.kind == .heartRate })
        XCTAssertEqual(hr.sampleCount, 64)
        XCTAssertEqual(NightLabInspectionFormatting.percentage(hr.coverageFraction), "100.0%")
        let motion = try XCTUnwrap(result.coverage.first { $0.kind == .accelerometer })
        XCTAssertEqual(motion.sampleCount, 3)
        XCTAssertEqual(motion.gapCount, 2)
        XCTAssertEqual(motion.largestGapSeconds, 58)
        XCTAssertEqual(motion.coverageFraction, 3.0 / 64)
        for kind in [NightSignalKind.rrIntervals, .wristStatus] {
            let row = try XCTUnwrap(result.coverage.first { $0.kind == kind })
            XCTAssertNil(row.coverageFraction)
            XCTAssertEqual(NightLabInspectionFormatting.percentage(row.coverageFraction), "Unavailable")
        }
        XCTAssertEqual(result.coverage.first { $0.kind == .respiration }?.sampleCount, 0)
        XCTAssertNil(result.baseline)
        XCTAssertNil(result.baselineError)
    }

    func testSavedBaselineExactEpochsSHAReceiptsAndReadOnlyDeterminism() async throws {
        let (root, store) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try await baseline(store)
        let receipt = SleepStagerV2ExecutionReceipt(nightID: "night", executedAtUnix: 123,
            durationNanoseconds: 456, baselineSHA256: NightLabFileStore.sha256Hex(bytes), noopCommitSHA: "commit")
        try await store.saveExecutionDerivedArtifact(nightID: "night", fileName: "receipt.json", data: NightLabJSON.encode(receipt))
        let before = try snapshot(root)
        let a = try await NightLabInspection.load(archive: store, nightID: "night")
        let b = try await NightLabInspection.load(archive: store, nightID: "night")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.baselineSHA256, NightLabFileStore.sha256Hex(bytes))
        XCTAssertEqual(a.baseline?.leadingBoundary?.startUnix, 31)
        XCTAssertEqual(a.baseline?.leadingBoundary?.endUnix, 60)
        XCTAssertEqual(a.baseline?.epochs.map(\.startUnix), [60, 90])
        XCTAssertEqual(a.baseline?.epochs.map(\.endUnix), [90, 95])
        XCTAssertEqual(a.baseline?.epochs.map(\.stage), [.rem, .rem])
        XCTAssertEqual(a.receipts.first?.receipt, receipt)
        XCTAssertNil(a.receipts.first?.error)
        XCTAssertEqual(try snapshot(root), before)
        // Even malformed reference bytes are outside this read path.
        try Data("not replay input".utf8).write(to: root.appendingPathComponent("NightLab/night/references/labels.json"))
        let c = try await NightLabInspection.load(archive: store, nightID: "night")
        XCTAssertEqual(a, c)
    }

    func testCorruptRawFailsExplicitly() async throws {
        let (root, store) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("corrupt".utf8).write(to: root.appendingPathComponent("NightLab/night/raw/hr.json"))
        do { _ = try await NightLabInspection.load(archive: store, nightID: "night"); XCTFail("Must reject corruption") }
        catch { XCTAssertEqual(error as? NightLabFileStoreError, .corruptRawAsset("hr")) }
    }

    func testMalformedBaselineAndReceiptAreSeparateFailures() async throws {
        let (root, store) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await store.saveDeterministicDerivedArtifact(nightID: "night", fileName: "sleep_stager_v2_baseline.json", data: Data("bad".utf8))
        try await store.saveExecutionDerivedArtifact(nightID: "night", fileName: "bad.json", data: Data("bad".utf8))
        let result = try await NightLabInspection.load(archive: store, nightID: "night")
        XCTAssertNotNil(result.baselineError)
        XCTAssertNotNil(result.receipts.first?.error)
        XCTAssertEqual(result.coverage.first?.sampleCount, 64)
    }

    func testUnsupportedSchemaAndRecordingState() async throws {
        let (root, store) = try await fixture(schema: 999); defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await NightLabInspection.load(archive: store, nightID: "night"); XCTFail("Unsupported schema") }
        catch { XCTAssertEqual(error as? NightLabInspectionError, .unsupportedSchema(999)) }
        let entries = try await store.inspectionNights()
        XCTAssertNotNil(entries.first?.error)
        let (otherRoot, other) = try await fixture(sealed: false)
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        let result = try await NightLabInspection.load(archive: other, nightID: "night")
        XCTAssertEqual(result.manifest.state, .recording)
        XCTAssertTrue(result.coverage.isEmpty)
    }

    func testEmptyRootIsNotCreatedAndUnsafeIDRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = NightLabFileStore(rootDirectory: root)
        let entries = try await store.inspectionNights()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        do { _ = try await NightLabInspection.load(archive: store, nightID: "../escape"); XCTFail("Unsafe path") }
        catch { XCTAssertEqual(error as? NightLabFileStoreError, .unsafeFileName("../escape")) }
    }

    func testWrongBaselineWindowAndEpochsRejectedWithoutWrites() async throws {
        let (root, store) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try await baseline(store)
        let url = root.appendingPathComponent("NightLab/night/derived/sleep_stager_v2_baseline.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["windowEndUnix"] = 96
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let before = try snapshot(root)
        let result = try await NightLabInspection.load(archive: store, nightID: "night")
        XCTAssertNotNil(result.baselineError)
        XCTAssertNil(result.baseline)
        XCTAssertEqual(try snapshot(root), before)
    }
}
