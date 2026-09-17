import XCTest
@testable import StrandAnalytics

final class NightLabFileStoreTests: XCTestCase {

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NightLabTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func recordingManifest(id: String = "night-1") -> NightRecordManifest {
        NightRecordManifest(
            nightID: id,
            state: .recording,
            windowStartUnix: 1_000,
            windowEndUnix: 2_000,
            timezoneOffsetSeconds: 0,
            sourceDeviceModel: "test-device",
            sourceFirmware: "test-firmware",
            noopVersion: "test-build",
            rawAssets: []
        )
    }

    func testCreateAppendSealAndReadVerifiedRawAsset() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NightLabFileStore(rootDirectory: root)

        try await store.createNight(recordingManifest())
        let bytes = Data("heart-rate-evidence".utf8)
        let asset = try await store.appendRawAsset(
            nightID: "night-1",
            assetID: "hr",
            kind: .heartRate,
            fileName: "hr.bin",
            data: bytes,
            startUnix: 1_000,
            endUnix: 2_000,
            sampleCount: 1_000,
            expectedCadenceHz: 1
        )

        XCTAssertEqual(asset.digestAlgorithm, "sha256")
        XCTAssertEqual(asset.digest, NightLabFileStore.sha256Hex(bytes))

        let sealed = try await store.sealNight(nightID: "night-1")
        XCTAssertEqual(sealed.state, .sealed)
        let readBack = try await store.rawData(nightID: "night-1", assetID: "hr")
        XCTAssertEqual(readBack, bytes)
    }

    func testRawAssetCannotBeReplaced() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NightLabFileStore(rootDirectory: root)
        try await store.createNight(recordingManifest())

        _ = try await store.appendRawAsset(
            nightID: "night-1", assetID: "hr", kind: .heartRate,
            fileName: "hr.bin", data: Data([1, 2, 3]),
            startUnix: 1_000, endUnix: 2_000, sampleCount: 3
        )

        do {
            _ = try await store.appendRawAsset(
                nightID: "night-1", assetID: "hr", kind: .heartRate,
                fileName: "hr-2.bin", data: Data([9]),
                startUnix: 1_000, endUnix: 2_000, sampleCount: 1
            )
            XCTFail("expected duplicate asset ID rejection")
        } catch let error as NightLabFileStoreError {
            XCTAssertEqual(error, .rawAssetAlreadyExists("hr"))
        }
    }

    func testSealedNightRejectsNewRawEvidence() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NightLabFileStore(rootDirectory: root)
        try await store.createNight(recordingManifest())
        _ = try await store.appendRawAsset(
            nightID: "night-1", assetID: "hr", kind: .heartRate,
            fileName: "hr.bin", data: Data([1]),
            startUnix: 1_000, endUnix: 2_000, sampleCount: 1
        )
        _ = try await store.sealNight(nightID: "night-1")

        do {
            _ = try await store.appendRawAsset(
                nightID: "night-1", assetID: "rr", kind: .rrIntervals,
                fileName: "rr.bin", data: Data([2]),
                startUnix: 1_000, endUnix: 2_000, sampleCount: 1
            )
            XCTFail("expected sealed-night rejection")
        } catch let error as NightLabFileStoreError {
            XCTAssertEqual(error, .nightNotRecording("night-1"))
        }
    }

    func testTamperedRawAssetFailsIntegrityCheck() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NightLabFileStore(rootDirectory: root)
        try await store.createNight(recordingManifest())
        _ = try await store.appendRawAsset(
            nightID: "night-1", assetID: "hr", kind: .heartRate,
            fileName: "hr.bin", data: Data([1, 2, 3]),
            startUnix: 1_000, endUnix: 2_000, sampleCount: 3
        )

        let rawURL = root
            .appendingPathComponent("NightLab/night-1/raw/hr.bin")
        try Data([9, 9, 9]).write(to: rawURL, options: [.atomic])

        do {
            _ = try await store.rawData(nightID: "night-1", assetID: "hr")
            XCTFail("expected integrity failure")
        } catch let error as NightLabFileStoreError {
            XCTAssertEqual(error, .corruptRawAsset("hr"))
        }
    }

    func testReferenceLivesOutsideReplayInputAndRequiresMatchingNight() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NightLabFileStore(rootDirectory: root)
        try await store.createNight(recordingManifest())

        let wrong = NightReferenceLabels(
            nightID: "other-night",
            provider: "whoop",
            importedAtUnix: 3_000,
            summary: ["remMinutes": 90]
        )

        do {
            try await store.saveReference(wrong, for: "night-1")
            XCTFail("expected reference night mismatch")
        } catch let error as NightLabFileStoreError {
            XCTAssertEqual(error,
                           .referenceNightMismatch(expected: "night-1", actual: "other-night"))
        }

        let replay = try await store.makeReplayInput(nightID: "night-1", coverage: [])
        let encoded = String(decoding: try NightLabJSON.encode(replay), as: UTF8.self)
        XCTAssertFalse(encoded.contains("remMinutes"))
        XCTAssertFalse(encoded.contains("whoop"))
    }

    func testDerivedRunCanBeAddedAfterSealWithoutChangingManifest() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NightLabFileStore(rootDirectory: root)
        try await store.createNight(recordingManifest())
        _ = try await store.appendRawAsset(
            nightID: "night-1", assetID: "hr", kind: .heartRate,
            fileName: "hr.bin", data: Data([1]),
            startUnix: 1_000, endUnix: 2_000, sampleCount: 1
        )
        let before = try await store.sealNight(nightID: "night-1")

        let run = NightAlgorithmRun(
            nightID: "night-1",
            algorithm: NightAlgorithmIdentity(id: "sleep-v2", version: "2.0.0"),
            inputSchemaVersion: before.schemaVersion,
            runAtUnix: 5_000,
            outputJSON: "{}"
        )
        try await store.saveRun(run)

        let after = try await store.loadManifest(nightID: "night-1")
        XCTAssertEqual(after, before)
    }

    /// Regression for the macOS Foundation crash:
    /// `Data.write(options: [.atomic, .withoutOverwriting])` is unsupported. Every Night Lab write-once
    /// namespace must use the safe create-if-absent publisher instead.
    func testWriteOncePublishingWorksAcrossRawDerivedExecutionAndReferenceNamespaces() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NightLabFileStore(rootDirectory: root)
        try await store.createNight(recordingManifest(id: "write-once-night"))

        let raw = Data("raw-evidence".utf8)
        _ = try await store.appendRawAsset(
            nightID: "write-once-night",
            assetID: "hr",
            kind: .heartRate,
            fileName: "hr.bin",
            data: raw,
            startUnix: 1_000,
            endUnix: 2_000,
            sampleCount: 1
        )
        let readRaw = try await store.rawData(nightID: "write-once-night", assetID: "hr")
        XCTAssertEqual(readRaw, raw)

        _ = try await store.sealNight(nightID: "write-once-night")

        let canonical = Data("canonical-baseline".utf8)
        let baseline = try await store.saveDeterministicDerivedArtifact(
            nightID: "write-once-night",
            fileName: "baseline.json",
            data: canonical
        )
        XCTAssertEqual(baseline.sha256, NightLabFileStore.sha256Hex(canonical))

        let receipt = Data("execution-receipt".utf8)
        let execution = try await store.saveExecutionDerivedArtifact(
            nightID: "write-once-night",
            fileName: "receipt.json",
            data: receipt
        )
        XCTAssertEqual(execution.sha256, NightLabFileStore.sha256Hex(receipt))

        let reference = NightReferenceLabels(
            nightID: "write-once-night",
            provider: "whoop",
            importedAtUnix: 6_000,
            summary: ["sleepMinutes": 420]
        )
        try await store.saveReference(reference, for: "write-once-night")

        let derived = try await store.derivedArtifactData(
            nightID: "write-once-night",
            fileName: "baseline.json"
        )
        XCTAssertEqual(derived, canonical)
    }

    func testConcurrentIdenticalDeterministicPublishIsIdempotent() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstStore = NightLabFileStore(rootDirectory: root)
        try await firstStore.createNight(recordingManifest(id: "race-night"))
        _ = try await firstStore.sealNight(nightID: "race-night")

        // A second actor represents another writer that is not serialized by the first actor's boundary.
        let secondStore = NightLabFileStore(rootDirectory: root)
        let bytes = Data("same-race-baseline".utf8)

        async let first = firstStore.saveDeterministicDerivedArtifact(
            nightID: "race-night",
            fileName: "baseline.json",
            data: bytes
        )
        async let second = secondStore.saveDeterministicDerivedArtifact(
            nightID: "race-night",
            fileName: "baseline.json",
            data: bytes
        )

        let (firstIdentity, secondIdentity) = try await (first, second)
        XCTAssertEqual(firstIdentity, secondIdentity)
        XCTAssertEqual(firstIdentity.sha256, NightLabFileStore.sha256Hex(bytes))

        let stored = try await firstStore.derivedArtifactData(
            nightID: "race-night",
            fileName: "baseline.json"
        )
        XCTAssertEqual(stored, bytes)

        let derivedDirectory = root.appendingPathComponent("NightLab/race-night/derived", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: derivedDirectory.path)
        XCTAssertFalse(names.contains(where: { $0.hasSuffix(".nightlab-tmp") }))
    }
}