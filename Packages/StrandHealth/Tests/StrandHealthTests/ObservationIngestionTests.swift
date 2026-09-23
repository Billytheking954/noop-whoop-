import Foundation
import XCTest
@testable import StrandHealth

final class ObservationIngestionTests: XCTestCase {
    private let providerID = "healthkit.heartRate"

    private actor StubProvider: HealthObservationProvider {
        private var batches: [ObservationChangeBatch]
        private(set) var receivedCursors: [ProviderCursor?] = []

        init(batches: [ObservationChangeBatch]) {
            self.batches = batches
        }

        func changes(since cursor: ProviderCursor?) async throws -> ObservationChangeBatch {
            receivedCursors.append(cursor)
            return batches.removeFirst()
        }

        func cursors() -> [ProviderCursor?] { receivedCursors }
    }

    private struct ThrowingProvider: HealthObservationProvider {
        struct Expected: Error {}
        func changes(since cursor: ProviderCursor?) async throws -> ObservationChangeBatch {
            throw Expected()
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StrandHealthIngestionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func cursor(_ text: String, provider: String? = nil) -> ProviderCursor {
        ProviderCursor(provider: provider ?? providerID, payload: Data(text.utf8))
    }

    private func observation(_ id: String, value: Double) -> ObservationRecord {
        ObservationRecord(
            id: id,
            metric: .heartRate,
            value: MetricValue(value: value, unit: .beatsPerMinute),
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_000),
            provenance: ObservationProvenance(
                classification: .measured,
                source: SourceIdentity(provider: providerID, identifier: "com.apple.Health"),
                providerIdentifier: id
            ),
            ingestedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
    }

    private func batch(id: String, value: Double, next: ProviderCursor) -> ObservationChangeBatch {
        ObservationChangeBatch(provider: providerID,
                               observations: [observation(id, value: value)],
                               deletions: [],
                               nextCursor: next)
    }

    func testSecondSyncFetchesFromPreviouslyCommittedCursor() async throws {
        let store = FileObservationStore(rootDirectory: try temporaryDirectory())
        let firstCursor = cursor("one")
        let secondCursor = cursor("two")
        let provider = StubProvider(batches: [
            batch(id: "one", value: 60, next: firstCursor),
            batch(id: "two", value: 61, next: secondCursor),
        ])
        let coordinator = ObservationIngestionCoordinator()

        try await coordinator.sync(providerIdentifier: providerID, provider: provider, store: store)
        try await coordinator.sync(providerIdentifier: providerID, provider: provider, store: store)

        let seen = await provider.cursors()
        XCTAssertNil(seen[0])
        XCTAssertEqual(seen[1], firstCursor)
        let committed = try await store.cursor(for: providerID)
        XCTAssertEqual(committed, secondCursor)
    }

    func testProviderMismatchDoesNotCommitBatch() async throws {
        let store = FileObservationStore(rootDirectory: try temporaryDirectory())
        let wrongProvider = "healthkit.hrv.sdnn"
        let wrongCursor = cursor("wrong", provider: wrongProvider)
        let wrongObservation = ObservationRecord(
            id: "wrong",
            metric: .heartRateVariabilitySDNN,
            value: MetricValue(value: 42, unit: .milliseconds),
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_000_000),
            provenance: ObservationProvenance(
                classification: .measured,
                source: SourceIdentity(provider: wrongProvider, identifier: "com.apple.Health"),
                providerIdentifier: "wrong"
            ),
            ingestedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let provider = StubProvider(batches: [
            ObservationChangeBatch(provider: wrongProvider,
                                   observations: [wrongObservation],
                                   deletions: [],
                                   nextCursor: wrongCursor)
        ])

        do {
            try await ObservationIngestionCoordinator().sync(providerIdentifier: providerID,
                                                             provider: provider,
                                                             store: store)
            XCTFail("expected provider mismatch")
        } catch let error as ObservationIngestionError {
            XCTAssertEqual(error, .providerMismatch(expected: providerID, actual: wrongProvider))
        }

        let committed = try await store.cursor(for: providerID)
        XCTAssertNil(committed)
    }

    func testProviderFailureLeavesCommittedCursorUntouched() async throws {
        let store = FileObservationStore(rootDirectory: try temporaryDirectory())
        let existingCursor = cursor("existing")
        try await store.commit(batch(id: "existing", value: 60, next: existingCursor),
                               expectedPriorCursor: nil)

        do {
            try await ObservationIngestionCoordinator().sync(providerIdentifier: providerID,
                                                             provider: ThrowingProvider(),
                                                             store: store)
            XCTFail("expected provider failure")
        } catch is ThrowingProvider.Expected {
            // expected
        }

        let committed = try await store.cursor(for: providerID)
        XCTAssertEqual(committed, existingCursor)
    }
}
