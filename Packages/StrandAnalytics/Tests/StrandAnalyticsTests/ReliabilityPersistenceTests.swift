import XCTest
@testable import StrandAnalytics

final class ReliabilityPersistenceTests: XCTestCase {
    private func tempURL(_ name: String = UUID().uuidString) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-reliability-tests", isDirectory: true)
            .appendingPathComponent(name)
    }

    func testActiveSessionSnapshotSurvivesFreshStoreInstance() async throws {
        let url = tempURL("session.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID()
        let snapshot = ActiveSessionSnapshot(id: id, startSec: 100, sessionType: "Hike",
                                             source: .automatic, latestValidSampleSec: 220,
                                             elapsedActiveSeconds: 120, accumulatedSampleCount: 13,
                                             watchSessionIdentifier: "watch-1",
                                             healthKitWorkoutIdentifier: "hk-1",
                                             whoopConnected: false, lastPersistedSec: 220)
        let writer = ActiveSessionPersistence(url: url)
        try await writer.save(snapshot)

        // New actor instance simulates a fresh process opening the persisted state.
        let reader = ActiveSessionPersistence(url: url)
        let restored = try await reader.load()
        XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(restored?.id, id)
    }

    func testClearIsIdempotent() async throws {
        let url = tempURL("clear.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ActiveSessionPersistence(url: url)
        let snapshot = ActiveSessionSnapshot(startSec: 100, sessionType: "Activity",
                                             source: .manual, lastPersistedSec: 100)
        try await store.save(snapshot)
        try await store.clear()
        try await store.clear()
        let restored = try await store.load()
        XCTAssertNil(restored)
    }

    func testUserCorrectionIsAppendOnlyAndDoesNotMutateCandidate() async throws {
        let url = tempURL("corrections.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ActivityCorrectionStore(url: url)
        let correction = ActivityCorrection(candidateStartSec: 100, candidateEndSec: 400,
                                            correctedType: "Walking", acceptedAsActivity: true,
                                            recordedAtSec: 500)
        try await store.append(correction)
        try await store.append(correction)
        let rows = try await store.all()
        XCTAssertEqual(rows, [correction])
    }

    func testAlgorithmProvenancePersistsWithoutRescoringHistory() async throws {
        let url = tempURL("provenance.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = MetricProvenanceStore(url: url)
        let row = PersistedMetricProvenance(metricKey: "recovery", periodStartSec: 10_000,
                                            provenance: DerivedMetricProvenance(
                                                algorithm: ProductionAlgorithmVersions.recovery,
                                                generatedAtSec: 10_100,
                                                quality: .init(level: .partial,
                                                               reasons: ["HRV unavailable"])))
        try await store.upsert(row)
        let restored = try await MetricProvenanceStore(url: url).all()
        XCTAssertEqual(restored, [row])
        XCTAssertEqual(restored.first?.provenance.algorithm,
                       ProductionAlgorithmVersions.recovery)
    }
}
