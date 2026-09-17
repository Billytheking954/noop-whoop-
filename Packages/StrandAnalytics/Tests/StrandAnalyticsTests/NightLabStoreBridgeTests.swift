import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

final class NightLabStoreBridgeTests: XCTestCase {

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NightLabBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func seededStore() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(id: "test-whoop",
                                      brand: "WHOOP",
                                      model: "WHOOP 5.0",
                                      sourceKind: .liveBLE,
                                      capabilities: [.hr, .hrv, .sleep],
                                      status: .active,
                                      addedAt: 900,
                                      lastSeenAt: 1_100))

        // The 1_010 rows sit exactly on the requested END boundary below and must not enter the archive.
        let streams = Streams(
            hr: [
                HRSample(ts: 1_000, bpm: 60),
                HRSample(ts: 1_001, bpm: 61),
                HRSample(ts: 1_010, bpm: 99),
            ],
            rr: [
                // Two legitimate beats in one second. Coverage sampleCount must remain 3, not collapse
                // these to two unique timestamp seconds.
                RRInterval(ts: 1_001, rrMs: 1_000, srcChannel: .whoop5Historical, ord: 0),
                RRInterval(ts: 1_001, rrMs: 990, srcChannel: .whoop5Historical, ord: 1),
                RRInterval(ts: 1_002, rrMs: 1_010, srcChannel: .whoop5Historical, ord: 2),
                RRInterval(ts: 1_010, rrMs: 900, srcChannel: .whoop5Historical, ord: 3),
            ],
            resp: [
                RespSample(ts: 1_000, raw: 100),
                RespSample(ts: 1_001, raw: 101),
                RespSample(ts: 1_010, raw: 999),
            ],
            gravity: [
                GravitySample(ts: 1_000, x: 0.0, y: 0.0, z: 1.0, dynAccel: 0.01),
                GravitySample(ts: 1_001, x: 0.1, y: 0.0, z: 0.99, dynAccel: 0.03),
                GravitySample(ts: 1_010, x: 1.0, y: 1.0, z: 1.0, dynAccel: 9.0),
            ]
        )
        _ = try await store.insert(streams, deviceId: "test-whoop")

        // Contact is a sparse state-change event. This second insert's HR collides harmlessly with the
        // existing 1_000 HR natural key, while the contact event is persisted for the bridge to snapshot.
        _ = try await store.insert(
            StandardHRMapping.samples(fromHR: 60,
                                      rr: [],
                                      contact: .supportedDetected,
                                      at: 1_000),
            deviceId: "test-whoop"
        )
        return store
    }

    func testCaptureSnapshotsProductionStoreStreamsAndSealsArchive() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await seededStore()
        let archive = NightLabFileStore(rootDirectory: root)

        let result = try await NightLabStoreBridge.capture(
            store: store,
            archive: archive,
            request: NightLabStoreBridgeRequest(
                nightID: "night-bridge-1",
                deviceID: "test-whoop",
                windowStartUnix: 1_000,
                windowEndUnix: 1_010,
                timezoneOffsetSeconds: 3_600,
                sourceFirmware: "50.test",
                noopVersion: "11.6-test"
            )
        )

        XCTAssertEqual(result.manifest.state, .sealed)
        XCTAssertEqual(result.manifest.schemaVersion, 2)
        XCTAssertEqual(result.manifest.sourceDeviceID, "test-whoop")
        XCTAssertEqual(result.manifest.sourceDeviceModel, "WHOOP 5.0")
        XCTAssertEqual(result.manifest.sourceFirmware, "50.test")
        XCTAssertEqual(result.manifest.sourceStoreSchemaVersion, WhoopStoreInfo.schemaVersion)
        XCTAssertEqual(result.manifest.sourceStreamFingerprint, result.sourceFingerprint)
        XCTAssertFalse(result.sourceFingerprint.isEmpty)

        XCTAssertEqual(Set(result.manifest.rawAssets.map(\.id)),
                       Set(["hr", "rr", "gravity", "respiration", "wrist-status"]))

        let hr = try NightLabJSON.decode(
            [HRSample].self,
            from: try await archive.rawData(nightID: "night-bridge-1", assetID: "hr")
        )
        XCTAssertEqual(hr.map(\.ts), [1_000, 1_001])
        XCTAssertFalse(hr.contains(where: { $0.ts == 1_010 }), "end boundary must stay exclusive")

        let rr = try NightLabJSON.decode(
            [RRInterval].self,
            from: try await archive.rawData(nightID: "night-bridge-1", assetID: "rr")
        )
        XCTAssertEqual(rr.count, 3)
        XCTAssertTrue(rr.allSatisfy { $0.ts < 1_010 })
        XCTAssertTrue(rr.allSatisfy { $0.srcChannel == .whoop5Historical })

        let wrist = try NightLabJSON.decode(
            [NightLabWristStatusRow].self,
            from: try await archive.rawData(nightID: "night-bridge-1", assetID: "wrist-status")
        )
        XCTAssertEqual(wrist,
                       [NightLabWristStatusRow(ts: 1_000,
                                               state: StandardHRContact.supportedDetected.rawValue)])
    }

    func testCoverageKeepsTrueRRRowCountWithoutInflatingOneHzCoverage() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await seededStore()
        let archive = NightLabFileStore(rootDirectory: root)

        let result = try await NightLabStoreBridge.capture(
            store: store,
            archive: archive,
            request: NightLabStoreBridgeRequest(nightID: "night-coverage",
                                                deviceID: "test-whoop",
                                                windowStartUnix: 1_000,
                                                windowEndUnix: 1_010,
                                                timezoneOffsetSeconds: 0)
        )

        let hr = try XCTUnwrap(result.coverage.first(where: { $0.kind == .heartRate }))
        XCTAssertEqual(hr.sampleCount, 2)
        XCTAssertEqual(hr.expectedSamples, 10)
        XCTAssertEqual(hr.coverageFraction ?? -1, 0.2, accuracy: 0.0001)

        let rr = try XCTUnwrap(result.coverage.first(where: { $0.kind == .rrIntervals }))
        XCTAssertEqual(rr.sampleCount, 3, "same-second beats are separate real rows")
        XCTAssertNil(rr.expectedSamples, "R-R is beat/event driven, not a 1 Hz sampled signal")
        XCTAssertNil(rr.coverageFraction)

        let motion = try XCTUnwrap(result.coverage.first(where: { $0.kind == .accelerometer }))
        XCTAssertEqual(motion.sampleCount, 2)
        XCTAssertEqual(motion.coverageFraction ?? -1, 0.2, accuracy: 0.0001)

        let contact = try XCTUnwrap(result.coverage.first(where: { $0.kind == .wristStatus }))
        XCTAssertEqual(contact.sampleCount, 1)
        XCTAssertNil(contact.coverageFraction)
        XCTAssertNil(contact.largestGapSeconds, "sparse state changes are not sampling gaps")
    }

    func testRowLimitFailsBeforeCreatingPartialArchive() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await seededStore()
        let archive = NightLabFileStore(rootDirectory: root)

        do {
            _ = try await NightLabStoreBridge.capture(
                store: store,
                archive: archive,
                request: NightLabStoreBridgeRequest(nightID: "night-too-large",
                                                    deviceID: "test-whoop",
                                                    windowStartUnix: 1_000,
                                                    windowEndUnix: 1_010,
                                                    timezoneOffsetSeconds: 0,
                                                    maxRowsPerStream: 1)
            )
            XCTFail("expected explicit row-limit failure")
        } catch let error as NightLabStoreBridgeError {
            XCTAssertEqual(error, .rowLimitExceeded(kind: .heartRate, limit: 1))
        }

        do {
            _ = try await archive.loadManifest(nightID: "night-too-large")
            XCTFail("bridge must validate the snapshot before creating archive files")
        } catch let error as NightLabFileStoreError {
            XCTAssertEqual(error, .nightNotFound("night-too-large"))
        }
    }

    func testMissingRegistryRowDoesNotBlockCapture() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(hr: [HRSample(ts: 2_000, bpm: 55)]),
                                   deviceId: "orphaned-source")
        let archive = NightLabFileStore(rootDirectory: root)

        let result = try await NightLabStoreBridge.capture(
            store: store,
            archive: archive,
            request: NightLabStoreBridgeRequest(nightID: "night-orphan",
                                                deviceID: "orphaned-source",
                                                windowStartUnix: 2_000,
                                                windowEndUnix: 2_010,
                                                timezoneOffsetSeconds: 0)
        )

        XCTAssertEqual(result.manifest.sourceDeviceID, "orphaned-source")
        XCTAssertNil(result.manifest.sourceDeviceModel)
        XCTAssertEqual(result.manifest.rawAssets.map(\.id), ["hr"])
    }
}
