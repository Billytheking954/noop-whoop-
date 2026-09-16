import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class SleepStagerV2ReplayAdapterTests: XCTestCase {

    private let implementation = SleepStagerV2ImplementationIdentity(
        noopCommitSHA: "test-commit-sha",
        stagerSourceBlobSHA: "test-stager-blob-sha"
    )

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NightLabV2ReplayTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func recordingManifest(id: String,
                                   start: Int,
                                   end: Int,
                                   schemaVersion: Int = NightRecordManifest.currentSchemaVersion,
                                   includeModernProvenance: Bool = true) -> NightRecordManifest {
        NightRecordManifest(
            schemaVersion: schemaVersion,
            nightID: id,
            state: .recording,
            windowStartUnix: start,
            windowEndUnix: end,
            timezoneOffsetSeconds: 3_600,
            sourceDeviceID: includeModernProvenance ? "whoop-test" : nil,
            sourceDeviceModel: includeModernProvenance ? "WHOOP 5.0" : nil,
            sourceFirmware: includeModernProvenance ? "50.test" : nil,
            sourceStoreSchemaVersion: includeModernProvenance ? 18 : nil,
            sourceStreamFingerprint: includeModernProvenance ? "source-fingerprint" : nil,
            noopVersion: includeModernProvenance ? "11.6-test" : nil,
            rawAssets: []
        )
    }

    private func heartRate(start: Int, end: Int, offset: Int = 0) -> [HRSample] {
        (start..<end).map { ts in
            // Deterministic gentle variation gives V2 enough per-second HR evidence without trying to tune it.
            HRSample(ts: ts, bpm: 56 + offset + ((ts - start) % 7))
        }
    }

    private func gravity(start: Int, end: Int) -> [GravitySample] {
        (start..<end).map { ts in
            let n = Double((ts - start) % 5) * 0.0005
            return GravitySample(ts: ts, x: n, y: 0, z: 1 - n, dynAccel: n)
        }
    }

    @discardableResult
    private func createSealedArchive(root: URL,
                                     id: String,
                                     start: Int,
                                     end: Int,
                                     schemaVersion: Int = NightRecordManifest.currentSchemaVersion,
                                     includeModernProvenance: Bool = true,
                                     hrOffset: Int = 0,
                                     includeGravity: Bool = true) async throws -> NightLabFileStore {
        let archive = NightLabFileStore(rootDirectory: root)
        try await archive.createNight(recordingManifest(id: id,
                                                        start: start,
                                                        end: end,
                                                        schemaVersion: schemaVersion,
                                                        includeModernProvenance: includeModernProvenance))

        let hr = heartRate(start: start, end: end, offset: hrOffset)
        _ = try await archive.appendRawAsset(nightID: id,
                                             assetID: "hr",
                                             kind: .heartRate,
                                             fileName: "hr.json",
                                             data: try NightLabJSON.encode(hr),
                                             startUnix: start,
                                             endUnix: end,
                                             sampleCount: hr.count,
                                             expectedCadenceHz: 1)

        if includeGravity {
            let grav = gravity(start: start, end: end)
            _ = try await archive.appendRawAsset(nightID: id,
                                                 assetID: "gravity",
                                                 kind: .accelerometer,
                                                 fileName: "gravity.json",
                                                 data: try NightLabJSON.encode(grav),
                                                 startUnix: start,
                                                 endUnix: end,
                                                 sampleCount: grav.count,
                                                 expectedCadenceHz: 1)
        }

        _ = try await archive.sealNight(nightID: id)
        return archive
    }

    private func directStreams(id: String = "direct",
                               start: Int = 990,
                               end: Int = 1_290) -> NightLabArchivedStreams {
        let manifest = NightRecordManifest(nightID: id,
                                           state: .sealed,
                                           windowStartUnix: start,
                                           windowEndUnix: end,
                                           timezoneOffsetSeconds: 0,
                                           rawAssets: [])
        return NightLabArchivedStreams(manifest: manifest,
                                       hr: heartRate(start: start, end: end),
                                       rr: [],
                                       gravity: gravity(start: start, end: end),
                                       respiration: [],
                                       wristStatus: [])
    }

    func testAdapterProductionSegmentsExactlyMatchDirectProductionCall() throws {
        let streams = directStreams()
        let expected = SleepStagerV2.stageSession(start: streams.manifest.windowStartUnix,
                                                  end: streams.manifest.windowEndUnix,
                                                  grav: streams.gravity,
                                                  hr: streams.hr,
                                                  rr: streams.rr,
                                                  resp: streams.respiration)

        let artifact = try SleepStagerV2ReplayAdapter(implementation: implementation).replay(streams: streams)
        XCTAssertEqual(artifact.productionSegments, expected)
        XCTAssertEqual(artifact.algorithm.id, SleepStagerV2ReplayAdapter.algorithmID)
        XCTAssertEqual(artifact.algorithm.version, SleepStagerV2ReplayAdapter.algorithmVersion)
        XCTAssertEqual(artifact.algorithm.build, implementation.stagerSourceBlobSHA)
    }

    func testCanonicalisationSupportsAllFourStagesOnAbsoluteThirtySecondGrid() throws {
        let segments = [
            StageSegment(start: 990, end: 1_020, stage: "wake"),
            StageSegment(start: 1_020, end: 1_050, stage: "light"),
            StageSegment(start: 1_050, end: 1_080, stage: "deep"),
            StageSegment(start: 1_080, end: 1_110, stage: "rem"),
        ]
        let result = try SleepStagerV2ReplayAdapter.canonicalize(productionSegments: segments,
                                                                 windowStartUnix: 990,
                                                                 windowEndUnix: 1_110)
        XCTAssertNil(result.leadingBoundary)
        XCTAssertEqual(result.epochs.map(\.startUnix), [990, 1_020, 1_050, 1_080])
        XCTAssertEqual(result.epochs.map(\.endUnix), [1_020, 1_050, 1_080, 1_110])
        XCTAssertEqual(result.epochs.map(\.stage), [.wake, .light, .deep, .rem])
        XCTAssertTrue(result.epochs.allSatisfy { $0.startUnix % 30 == 0 })
    }

    func testNonAlignedStartIsSeparateBoundaryAndEndIsClippedHalfOpen() throws {
        let segments = [
            StageSegment(start: 1_001, end: 1_020, stage: "light"),
            StageSegment(start: 1_020, end: 1_080, stage: "deep"),
            StageSegment(start: 1_080, end: 1_097, stage: "rem"),
        ]
        let result = try SleepStagerV2ReplayAdapter.canonicalize(productionSegments: segments,
                                                                 windowStartUnix: 1_001,
                                                                 windowEndUnix: 1_097)

        XCTAssertEqual(result.leadingBoundary,
                       SleepStagerV2BaselineBoundary(startUnix: 1_001,
                                                     endUnix: 1_020,
                                                     stage: .light))
        XCTAssertEqual(result.epochs, [
            SleepStagerV2BaselineEpoch(startUnix: 1_020, endUnix: 1_050, stage: .deep),
            SleepStagerV2BaselineEpoch(startUnix: 1_050, endUnix: 1_080, stage: .deep),
            SleepStagerV2BaselineEpoch(startUnix: 1_080, endUnix: 1_097, stage: .rem),
        ])
        XCTAssertFalse(result.epochs.contains(where: { $0.endUnix > 1_097 }))
    }

    func testShortUnalignedWindowProducesBoundaryButNoFakeEpoch() throws {
        let segments = [StageSegment(start: 1_001, end: 1_010, stage: "light")]
        let result = try SleepStagerV2ReplayAdapter.canonicalize(productionSegments: segments,
                                                                 windowStartUnix: 1_001,
                                                                 windowEndUnix: 1_010)
        XCTAssertEqual(result.leadingBoundary,
                       SleepStagerV2BaselineBoundary(startUnix: 1_001,
                                                     endUnix: 1_010,
                                                     stage: .light))
        XCTAssertTrue(result.epochs.isEmpty)
    }

    func testUnknownProductionStageIsRejected() throws {
        do {
            _ = try SleepStagerV2ReplayAdapter.canonicalize(
                productionSegments: [StageSegment(start: 990, end: 1_020, stage: "mystery")],
                windowStartUnix: 990,
                windowEndUnix: 1_020
            )
            XCTFail("unknown production stages must not be silently mapped")
        } catch let error as SleepStagerV2ReplayError {
            XCTAssertEqual(error, .unknownProductionStage("mystery"))
        }
    }

    func testUnalignedInteriorProductionTransitionIsRejected() throws {
        do {
            _ = try SleepStagerV2ReplayAdapter.canonicalize(
                productionSegments: [
                    StageSegment(start: 990, end: 1_015, stage: "light"),
                    StageSegment(start: 1_015, end: 1_050, stage: "deep"),
                ],
                windowStartUnix: 990,
                windowEndUnix: 1_050
            )
            XCTFail("interior V2 transitions must remain on the 30-second grid")
        } catch let error as SleepStagerV2ReplayError {
            XCTAssertEqual(error, .unalignedInteriorProductionBoundary(1_015))
        }
    }

    func testSealedArchiveRunsEndToEndAndPersistsDeterministicBaseline() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await createSealedArchive(root: root,
                                                    id: "baseline-night",
                                                    start: 1_000,
                                                    end: 1_301)

        let execution = try await NightLabSleepStagerV2BaselineRunner.run(archive: archive,
                                                                          nightID: "baseline-night",
                                                                          implementation: implementation)
        let bytes = try await archive.derivedArtifactData(
            nightID: "baseline-night",
            fileName: NightLabSleepStagerV2BaselineRunner.baselineFileName
        )
        let decoded = try NightLabJSON.decode(SleepStagerV2BaselineArtifact.self, from: bytes)

        XCTAssertEqual(decoded, execution.artifact)
        XCTAssertEqual(bytes, try NightLabJSON.encode(execution.artifact))
        XCTAssertEqual(execution.baselineFile.relativePath, "derived/sleep_stager_v2_baseline.json")
        XCTAssertEqual(execution.baselineFile.sha256, NightLabFileStore.sha256Hex(bytes))
        XCTAssertEqual(execution.receipt.baselineSHA256, execution.baselineFile.sha256)
        XCTAssertTrue(execution.receiptFile.relativePath.hasPrefix("derived/executions/sleep_stager_v2_"))

        XCTAssertEqual(decoded.nightID, "baseline-night")
        XCTAssertEqual(decoded.manifestSchemaVersion, NightRecordManifest.currentSchemaVersion)
        XCTAssertEqual(decoded.sourceStreamFingerprint, "source-fingerprint")
        XCTAssertEqual(decoded.sourceDeviceID, "whoop-test")
        XCTAssertEqual(decoded.sourceDeviceModel, "WHOOP 5.0")
        XCTAssertEqual(decoded.sourceFirmware, "50.test")
        XCTAssertEqual(decoded.sourceStoreSchemaVersion, 18)
        XCTAssertEqual(decoded.sourceNOOPVersion, "11.6-test")
        XCTAssertEqual(decoded.timezoneOffsetSeconds, 3_600)
        XCTAssertEqual(decoded.epochSeconds, 30)
        XCTAssertEqual(decoded.epochAnchorUnix, 0)
        XCTAssertEqual(decoded.implementation, implementation)
        XCTAssertEqual(decoded.inputAssets.map(\.assetID), ["gravity", "hr"])
        XCTAssertTrue(decoded.inputAssets.allSatisfy { !$0.sha256.isEmpty && $0.sampleCount > 0 })
        XCTAssertTrue(decoded.inputAssets.allSatisfy(\.usedByStager))
        XCTAssertTrue(decoded.epochs.allSatisfy {
            $0.startUnix >= 1_000 && $0.endUnix <= 1_301 && $0.startUnix % 30 == 0
        })
    }

    func testRepeatedReplayKeepsBaselineBytesAndHashIdenticalWhileReceiptsAreSeparate() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await createSealedArchive(root: root,
                                                    id: "repeat-night",
                                                    start: 990,
                                                    end: 1_290)

        let first = try await NightLabSleepStagerV2BaselineRunner.run(archive: archive,
                                                                      nightID: "repeat-night",
                                                                      implementation: implementation)
        let firstBytes = try await archive.derivedArtifactData(
            nightID: "repeat-night",
            fileName: NightLabSleepStagerV2BaselineRunner.baselineFileName
        )
        let second = try await NightLabSleepStagerV2BaselineRunner.run(archive: archive,
                                                                       nightID: "repeat-night",
                                                                       implementation: implementation)
        let secondBytes = try await archive.derivedArtifactData(
            nightID: "repeat-night",
            fileName: NightLabSleepStagerV2BaselineRunner.baselineFileName
        )

        XCTAssertEqual(first.artifact, second.artifact)
        XCTAssertEqual(firstBytes, secondBytes)
        XCTAssertEqual(first.baselineFile.sha256, second.baselineFile.sha256)
        XCTAssertEqual(first.baselineFile, second.baselineFile)
        XCTAssertEqual(first.receipt.baselineSHA256, second.receipt.baselineSHA256)
        XCTAssertNotEqual(first.receiptFile.relativePath, second.receiptFile.relativePath)
    }

    func testReferenceLabelsCannotAffectBlindBaseline() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await createSealedArchive(root: root,
                                                    id: "blind-night",
                                                    start: 990,
                                                    end: 1_290)

        try await archive.saveReference(
            NightReferenceLabels(nightID: "blind-night",
                                 provider: "whoop",
                                 importedAtUnix: 5_000,
                                 epochs: [NightReferenceEpoch(startUnix: 990,
                                                              endUnix: 1_290,
                                                              label: "deep")],
                                 summary: ["deepMinutes": 300]),
            for: "blind-night"
        )
        let first = try await NightLabSleepStagerV2BaselineRunner.run(archive: archive,
                                                                      nightID: "blind-night",
                                                                      implementation: implementation)
        let firstBytes = try await archive.derivedArtifactData(
            nightID: "blind-night",
            fileName: NightLabSleepStagerV2BaselineRunner.baselineFileName
        )

        // Add a completely contradictory reference. The runner has no API that reads references/.
        try await archive.saveReference(
            NightReferenceLabels(nightID: "blind-night",
                                 provider: "whoop",
                                 importedAtUnix: 5_001,
                                 epochs: [NightReferenceEpoch(startUnix: 990,
                                                              endUnix: 1_290,
                                                              label: "wake")],
                                 summary: ["deepMinutes": 0, "awakeMinutes": 300]),
            for: "blind-night"
        )
        let second = try await NightLabSleepStagerV2BaselineRunner.run(archive: archive,
                                                                       nightID: "blind-night",
                                                                       implementation: implementation)
        let secondBytes = try await archive.derivedArtifactData(
            nightID: "blind-night",
            fileName: NightLabSleepStagerV2BaselineRunner.baselineFileName
        )

        XCTAssertEqual(firstBytes, secondBytes)
        XCTAssertEqual(first.baselineFile.sha256, second.baselineFile.sha256)
        XCTAssertEqual(first.artifact, second.artifact)
    }

    func testCorruptRawAssetIsRejectedBeforeStaging() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await createSealedArchive(root: root,
                                                    id: "corrupt-night",
                                                    start: 990,
                                                    end: 1_290)
        let rawHR = root.appendingPathComponent("NightLab/corrupt-night/raw/hr.json")
        try Data("tampered".utf8).write(to: rawHR, options: [.atomic])

        do {
            _ = try await NightLabSleepStagerV2BaselineRunner.run(archive: archive,
                                                                  nightID: "corrupt-night",
                                                                  implementation: implementation)
            XCTFail("corrupt evidence must fail before SleepStagerV2")
        } catch let error as NightLabFileStoreError {
            XCTAssertEqual(error, .corruptRawAsset("hr"))
        }
    }

    func testOutOfWindowEvidenceIsRejectedBeforeStaging() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = NightLabFileStore(rootDirectory: root)
        try await archive.createNight(recordingManifest(id: "outside-night", start: 1_000, end: 1_010))
        let hr = [HRSample(ts: 1_010, bpm: 60)] // exact exclusive end
        _ = try await archive.appendRawAsset(nightID: "outside-night",
                                             assetID: "hr",
                                             kind: .heartRate,
                                             fileName: "hr.json",
                                             data: try NightLabJSON.encode(hr),
                                             startUnix: 1_010,
                                             endUnix: 1_011,
                                             sampleCount: 1,
                                             expectedCadenceHz: 1)
        _ = try await archive.sealNight(nightID: "outside-night")

        do {
            _ = try await NightLabSleepStagerV2BaselineRunner.run(archive: archive,
                                                                  nightID: "outside-night",
                                                                  implementation: implementation)
            XCTFail("half-open archive boundary must be validated before replay")
        } catch let error as NightLabArchiveLoaderError {
            XCTAssertEqual(error, .rowOutsideNight(assetID: "hr", timestamp: 1_010))
        }
    }

    func testChangedInputEvidenceChangesBaselineProvenanceAndHash() async throws {
        let rootA = try tempRoot()
        let rootB = try tempRoot()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let a = try await createSealedArchive(root: rootA,
                                              id: "changed-night",
                                              start: 990,
                                              end: 1_290,
                                              hrOffset: 0)
        let b = try await createSealedArchive(root: rootB,
                                              id: "changed-night",
                                              start: 990,
                                              end: 1_290,
                                              hrOffset: 20)

        let runA = try await NightLabSleepStagerV2BaselineRunner.run(archive: a,
                                                                     nightID: "changed-night",
                                                                     implementation: implementation)
        let runB = try await NightLabSleepStagerV2BaselineRunner.run(archive: b,
                                                                     nightID: "changed-night",
                                                                     implementation: implementation)
        let hrA = try XCTUnwrap(runA.artifact.inputAssets.first(where: { $0.assetID == "hr" }))
        let hrB = try XCTUnwrap(runB.artifact.inputAssets.first(where: { $0.assetID == "hr" }))
        XCTAssertNotEqual(hrA.sha256, hrB.sha256)
        XCTAssertNotEqual(runA.baselineFile.sha256, runB.baselineFile.sha256)
    }

    func testDeterministicDerivedArtifactIsIdempotentAndRefusesDifferingOverwrite() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await createSealedArchive(root: root,
                                                    id: "derived-night",
                                                    start: 990,
                                                    end: 1_020,
                                                    includeGravity: false)
        let a = Data("same-baseline".utf8)
        let first = try await archive.saveDeterministicDerivedArtifact(nightID: "derived-night",
                                                                        fileName: "canonical.json",
                                                                        data: a)
        let second = try await archive.saveDeterministicDerivedArtifact(nightID: "derived-night",
                                                                         fileName: "canonical.json",
                                                                         data: a)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.sha256, NightLabFileStore.sha256Hex(a))

        do {
            _ = try await archive.saveDeterministicDerivedArtifact(nightID: "derived-night",
                                                                    fileName: "canonical.json",
                                                                    data: Data("different".utf8))
            XCTFail("canonical derived evidence must never be overwritten")
        } catch let error as NightLabFileStoreError {
            XCTAssertEqual(error, .derivedArtifactConflict("canonical.json"))
        }
    }

    func testLegacySchemaV1NightCanProduceBaselineWithoutInventedModernProvenance() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try await createSealedArchive(root: root,
                                                    id: "legacy-night",
                                                    start: 990,
                                                    end: 1_290,
                                                    schemaVersion: 1,
                                                    includeModernProvenance: false,
                                                    includeGravity: false)
        let run = try await NightLabSleepStagerV2BaselineRunner.run(archive: archive,
                                                                    nightID: "legacy-night",
                                                                    implementation: implementation)
        XCTAssertEqual(run.artifact.manifestSchemaVersion, 1)
        XCTAssertNil(run.artifact.sourceDeviceID)
        XCTAssertNil(run.artifact.sourceDeviceModel)
        XCTAssertNil(run.artifact.sourceFirmware)
        XCTAssertNil(run.artifact.sourceStoreSchemaVersion)
        XCTAssertNil(run.artifact.sourceStreamFingerprint)
        XCTAssertNil(run.artifact.sourceNOOPVersion)
    }

    func testMissingOptionalStreamsUseExistingProductionBehaviour() throws {
        let start = 990
        let end = 1_290
        let manifest = NightRecordManifest(nightID: "hr-only",
                                           state: .sealed,
                                           windowStartUnix: start,
                                           windowEndUnix: end,
                                           timezoneOffsetSeconds: 0,
                                           rawAssets: [])
        let streams = NightLabArchivedStreams(manifest: manifest,
                                              hr: heartRate(start: start, end: end),
                                              rr: [],
                                              gravity: [],
                                              respiration: [],
                                              wristStatus: [])
        let direct = SleepStagerV2.stageSession(start: start,
                                                end: end,
                                                grav: [],
                                                hr: streams.hr,
                                                rr: [],
                                                resp: [])
        let artifact = try SleepStagerV2ReplayAdapter(implementation: implementation).replay(streams: streams)
        XCTAssertEqual(artifact.productionSegments, direct)
        XCTAssertFalse(artifact.productionSegments.isEmpty)
    }

    func testInvalidImplementationIdentityIsRejected() throws {
        let bad = SleepStagerV2ImplementationIdentity(noopCommitSHA: "", stagerSourceBlobSHA: "blob")
        do {
            _ = try SleepStagerV2ReplayAdapter(implementation: bad).replay(streams: directStreams())
            XCTFail("missing build provenance must not produce a research baseline")
        } catch let error as SleepStagerV2ReplayError {
            XCTAssertEqual(error, .invalidImplementationIdentity)
        }
    }
}
