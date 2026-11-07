import XCTest
@testable import StrandAnalytics

final class NightLabFoundationTests: XCTestCase {

    func testOverflowingManifestWindowIsRejected() {
        let manifest = NightRecordManifest(nightID: "overflow", state: .recording,
            windowStartUnix: Int.min, windowEndUnix: Int.max,
            timezoneOffsetSeconds: 0, rawAssets: [])
        XCTAssertThrowsError(try NightManifestValidator.validate(manifest)) { error in
            XCTAssertEqual(error as? NightLabValidationError, .invalidWindow)
        }
    }

    func testCoverageRejectsUnrepresentableWindowsWithoutTrapping() {
        for (start, end) in [(Int.min, Int.max), (Int.max, Int.min), (10, 10)] {
            let report = NightSignalCoverage.analyze(kind: .heartRate, timestamps: [0],
                windowStartUnix: start, windowEndUnix: end, expectedCadenceHz: 1)
            XCTAssertEqual(report.windowSeconds, 0)
            XCTAssertEqual(report.sampleCount, 0)
            XCTAssertNil(report.coverageFraction)
            XCTAssertNil(report.largestGapSeconds)
        }
    }

    func testUnrepresentableExpectedCountKeepsGeometryButNotCoverage() {
        for cadence in [Double.greatestFiniteMagnitude, Double(Int.max), Double.infinity, Double.nan] {
            let report = NightSignalCoverage.analyze(kind: .heartRate, timestamps: [0, 1],
                windowStartUnix: 0, windowEndUnix: 2, expectedCadenceHz: cadence)
            XCTAssertEqual(report.sampleCount, 2)
            XCTAssertEqual(report.largestGapSeconds, 1)
            XCTAssertNil(report.expectedSamples)
            XCTAssertNil(report.coverageFraction)
        }
    }

    private func sealedManifest() -> NightRecordManifest {
        NightRecordManifest(
            nightID: "2026-09-13",
            state: .sealed,
            windowStartUnix: 1_000,
            windowEndUnix: 4_600,
            timezoneOffsetSeconds: 3_600,
            sourceDeviceModel: "WHOOP 5.0",
            sourceFirmware: "test",
            noopVersion: "test",
            rawAssets: [
                NightRawAsset(
                    id: "hr",
                    kind: .heartRate,
                    relativePath: "raw/hr.jsonl",
                    startUnix: 1_000,
                    endUnix: 4_600,
                    sampleCount: 3_600,
                    expectedCadenceHz: 1,
                    digestAlgorithm: "sha256",
                    digest: "abc123"
                )
            ]
        )
    }

    func testSealedManifestAcceptsSafeRawAssetWithDigest() throws {
        XCTAssertNoThrow(try NightManifestValidator.validate(sealedManifest()))
    }

    func testSealedManifestRejectsMissingDigest() {
        let manifest = NightRecordManifest(
            nightID: "night-1",
            state: .sealed,
            windowStartUnix: 100,
            windowEndUnix: 200,
            timezoneOffsetSeconds: 0,
            rawAssets: [
                NightRawAsset(
                    id: "rr",
                    kind: .rrIntervals,
                    relativePath: "raw/rr.jsonl",
                    startUnix: 100,
                    endUnix: 200,
                    sampleCount: 20
                )
            ]
        )

        XCTAssertThrowsError(try NightManifestValidator.validate(manifest)) { error in
            XCTAssertEqual(error as? NightLabValidationError, .missingIntegrityDigest("rr"))
        }
    }

    func testUnsafeTraversalPathIsRejected() {
        let manifest = NightRecordManifest(
            nightID: "night-1",
            state: .recording,
            windowStartUnix: 100,
            windowEndUnix: 200,
            timezoneOffsetSeconds: 0,
            rawAssets: [
                NightRawAsset(
                    id: "hr",
                    kind: .heartRate,
                    relativePath: "raw/../reference.json",
                    startUnix: 100,
                    endUnix: 200,
                    sampleCount: 20
                )
            ]
        )

        XCTAssertThrowsError(try NightManifestValidator.validate(manifest)) { error in
            XCTAssertEqual(error as? NightLabValidationError,
                           .unsafeRawPath("raw/../reference.json"))
        }
    }

    func testDuplicateAssetIDsAreRejected() {
        let asset = NightRawAsset(
            id: "hr",
            kind: .heartRate,
            relativePath: "raw/hr.jsonl",
            startUnix: 100,
            endUnix: 200,
            sampleCount: 20
        )
        let manifest = NightRecordManifest(
            nightID: "night-1",
            state: .recording,
            windowStartUnix: 100,
            windowEndUnix: 200,
            timezoneOffsetSeconds: 0,
            rawAssets: [asset, asset]
        )

        XCTAssertThrowsError(try NightManifestValidator.validate(manifest)) { error in
            XCTAssertEqual(error as? NightLabValidationError, .duplicateAssetID("hr"))
        }
    }

    func testCoverageReportsPerfectOneHertzWindow() {
        let report = NightSignalCoverage.analyze(
            kind: .heartRate,
            timestamps: Array(100..<160),
            windowStartUnix: 100,
            windowEndUnix: 160,
            expectedCadenceHz: 1
        )

        XCTAssertEqual(report.sampleCount, 60)
        XCTAssertEqual(report.expectedSamples, 60)
        XCTAssertEqual(report.coverageFraction ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(report.gapCount, 0)
    }

    func testCoverageDoesNotInventPercentageWhenCadenceUnknown() {
        let report = NightSignalCoverage.analyze(
            kind: .wristStatus,
            timestamps: [100, 130, 150],
            windowStartUnix: 100,
            windowEndUnix: 160
        )

        XCTAssertNil(report.expectedSamples)
        XCTAssertNil(report.coverageFraction)
        XCTAssertNil(report.gapCount)
    }

    func testCoverageCountsMissingSpanAsGap() {
        let report = NightSignalCoverage.analyze(
            kind: .heartRate,
            timestamps: [100, 101, 102, 110, 111],
            windowStartUnix: 100,
            windowEndUnix: 112,
            expectedCadenceHz: 1
        )

        XCTAssertEqual(report.gapCount, 1)
        XCTAssertEqual(report.largestGapSeconds, 8)
        XCTAssertLessThan(report.coverageFraction ?? 1, 1)
    }

    func testStableJSONEncodingIsDeterministic() throws {
        let manifest = sealedManifest()
        let first = try NightLabJSON.encode(manifest)
        let second = try NightLabJSON.encode(manifest)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try NightLabJSON.decode(NightRecordManifest.self, from: first), manifest)
    }

    func testArchiveNamespacesKeepRawDerivedAndReferencesSeparate() {
        let nightID = "night-1"
        XCTAssertEqual(NightLabArchiveLayout.rawDirectory(nightID), "NightLab/night-1/raw")
        XCTAssertEqual(NightLabArchiveLayout.derivedDirectory(nightID), "NightLab/night-1/derived")
        XCTAssertEqual(NightLabArchiveLayout.referencesDirectory(nightID), "NightLab/night-1/references")
    }

    func testReplayRecordsExactAlgorithmIdentity() throws {
        struct EchoAlgorithm: NightReplayAlgorithm {
            let identity = NightAlgorithmIdentity(id: "sleep-v2", version: "2.1.0", build: "abc")
            func run(input: NightReplayInput) throws -> String {
                "{\"night\":\"\(input.manifest.nightID)\"}"
            }
        }

        let input = NightReplayInput(manifest: sealedManifest(), coverage: [])
        let run = try NightReplayRunner.run(algorithm: EchoAlgorithm(), input: input, runAtUnix: 9_999)

        XCTAssertEqual(run.nightID, "2026-09-13")
        XCTAssertEqual(run.algorithm.id, "sleep-v2")
        XCTAssertEqual(run.algorithm.version, "2.1.0")
        XCTAssertEqual(run.algorithm.build, "abc")
        XCTAssertEqual(run.inputSchemaVersion, NightRecordManifest.currentSchemaVersion)
        XCTAssertEqual(run.runAtUnix, 9_999)
    }

    func testReferenceLabelsAreNotPartOfReplayInputEncoding() throws {
        let input = NightReplayInput(manifest: sealedManifest(), coverage: [])
        let encoded = String(decoding: try NightLabJSON.encode(input), as: UTF8.self)

        XCTAssertFalse(encoded.contains("provider"))
        XCTAssertFalse(encoded.contains("epochs"))
        XCTAssertFalse(encoded.contains("reference"))
    }
}
