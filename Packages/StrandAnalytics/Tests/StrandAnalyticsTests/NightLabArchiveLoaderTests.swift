import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class NightLabArchiveLoaderTests: XCTestCase {

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NightLabLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func recordingManifest(id: String = "loader-night") -> NightRecordManifest {
        NightRecordManifest(nightID: id,
                            state: .recording,
                            windowStartUnix: 1_000,
                            windowEndUnix: 1_100,
                            timezoneOffsetSeconds: 0,
                            sourceDeviceID: "test-source",
                            sourceDeviceModel: "WHOOP 5.0",
                            sourceStoreSchemaVersion: 18,
                            sourceStreamFingerprint: "source-witness",
                            noopVersion: "test",
                            rawAssets: [])
    }

    func testLoadsTypedRowsFromVerifiedSealedArchive() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = NightLabFileStore(rootDirectory: root)
        try await archive.createNight(recordingManifest())

        let hr = [HRSample(ts: 1_000, bpm: 60), HRSample(ts: 1_001, bpm: 61)]
        let rr = [
            RRInterval(ts: 1_001, rrMs: 1_000, srcChannel: .whoop5Historical, ord: 0),
            RRInterval(ts: 1_001, rrMs: 990, srcChannel: .whoop5Historical, ord: 1),
        ]
        _ = try await archive.appendRawAsset(nightID: "loader-night",
                                             assetID: "hr",
                                             kind: .heartRate,
                                             fileName: "hr.json",
                                             data: try NightLabJSON.encode(hr),
                                             startUnix: 1_000,
                                             endUnix: 1_002,
                                             sampleCount: hr.count,
                                             expectedCadenceHz: 1)
        _ = try await archive.appendRawAsset(nightID: "loader-night",
                                             assetID: "rr",
                                             kind: .rrIntervals,
                                             fileName: "rr.json",
                                             data: try NightLabJSON.encode(rr),
                                             startUnix: 1_001,
                                             endUnix: 1_002,
                                             sampleCount: rr.count)
        _ = try await archive.sealNight(nightID: "loader-night")

        let loaded = try await NightLabArchiveLoader.load(archive: archive, nightID: "loader-night")
        XCTAssertEqual(loaded.hr, hr)
        XCTAssertEqual(loaded.rr, rr)
        XCTAssertTrue(loaded.gravity.isEmpty)
        XCTAssertTrue(loaded.respiration.isEmpty)
        XCTAssertTrue(loaded.wristStatus.isEmpty)
        XCTAssertEqual(loaded.manifest.sourceStreamFingerprint, "source-witness")

        let coverage = NightLabArchiveLoader.coverage(for: loaded)
        XCTAssertEqual(coverage.first(where: { $0.kind == .heartRate })?.sampleCount, 2)
        XCTAssertEqual(coverage.first(where: { $0.kind == .rrIntervals })?.sampleCount, 2)

        let replay = NightLabArchiveLoader.replayInput(for: loaded)
        XCTAssertEqual(replay.manifest.nightID, "loader-night")
        XCTAssertEqual(replay.coverage, coverage)
    }

    func testRefusesUnsealedNight() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = NightLabFileStore(rootDirectory: root)
        try await archive.createNight(recordingManifest(id: "still-recording"))

        do {
            _ = try await NightLabArchiveLoader.load(archive: archive, nightID: "still-recording")
            XCTFail("replay must never read a night that can still mutate")
        } catch let error as NightLabArchiveLoaderError {
            XCTAssertEqual(error, .nightNotSealed("still-recording"))
        }
    }

    func testRejectsDecodedRowCountThatDisagreesWithManifest() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = NightLabFileStore(rootDirectory: root)
        try await archive.createNight(recordingManifest(id: "bad-count"))

        let hr = [HRSample(ts: 1_000, bpm: 60)]
        _ = try await archive.appendRawAsset(nightID: "bad-count",
                                             assetID: "hr",
                                             kind: .heartRate,
                                             fileName: "hr.json",
                                             data: try NightLabJSON.encode(hr),
                                             startUnix: 1_000,
                                             endUnix: 1_001,
                                             sampleCount: 2,
                                             expectedCadenceHz: 1)
        _ = try await archive.sealNight(nightID: "bad-count")

        do {
            _ = try await NightLabArchiveLoader.load(archive: archive, nightID: "bad-count")
            XCTFail("manifest count disagreement must not reach a replay algorithm")
        } catch let error as NightLabArchiveLoaderError {
            XCTAssertEqual(error,
                           .decodedRowCountMismatch(assetID: "hr", manifestCount: 2, decodedCount: 1))
        }
    }

    func testRejectsRowOutsideManifestNightWindow() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = NightLabFileStore(rootDirectory: root)
        try await archive.createNight(recordingManifest(id: "bad-window"))

        let hr = [HRSample(ts: 1_100, bpm: 60)] // exact exclusive end, therefore outside
        _ = try await archive.appendRawAsset(nightID: "bad-window",
                                             assetID: "hr",
                                             kind: .heartRate,
                                             fileName: "hr.json",
                                             data: try NightLabJSON.encode(hr),
                                             startUnix: 1_100,
                                             endUnix: 1_101,
                                             sampleCount: 1,
                                             expectedCadenceHz: 1)
        _ = try await archive.sealNight(nightID: "bad-window")

        do {
            _ = try await NightLabArchiveLoader.load(archive: archive, nightID: "bad-window")
            XCTFail("out-of-window raw row must not reach replay")
        } catch let error as NightLabArchiveLoaderError {
            XCTAssertEqual(error, .rowOutsideNight(assetID: "hr", timestamp: 1_100))
        }
    }
}
