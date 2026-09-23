import Foundation
import XCTest
@testable import StrandHealth

final class ObservationStoreTests: XCTestCase {
    private let provider = "healthkit.heartRate"

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StrandHealthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func cursor(_ value: String) -> ProviderCursor {
        ProviderCursor(provider: provider, payload: Data(value.utf8))
    }

    private func observation(id: String,
                             providerIdentifier: String,
                             value: Double,
                             start: TimeInterval = 1_700_000_000) -> ObservationRecord {
        ObservationRecord(
            id: id,
            metric: .heartRate,
            value: MetricValue(value: value, unit: .beatsPerMinute),
            startDate: Date(timeIntervalSince1970: start),
            endDate: Date(timeIntervalSince1970: start),
            quality: ObservationQuality(state: .nominal),
            provenance: ObservationProvenance(
                classification: .measured,
                source: SourceIdentity(provider: provider, identifier: "com.apple.Health"),
                providerIdentifier: providerIdentifier
            ),
            ingestedAt: Date(timeIntervalSince1970: start + 10)
        )
    }

    private func batch(observations: [ObservationRecord],
                       deletions: [ObservationDeletion] = [],
                       nextCursor: ProviderCursor) -> ObservationChangeBatch {
        ObservationChangeBatch(
            provider: provider,
            observations: observations,
            deletions: deletions,
            nextCursor: nextCursor
        )
    }

    func testCommitPersistsObservationAndCursorAcrossRestart() async throws {
        let root = try temporaryDirectory()
        let first = FileObservationStore(rootDirectory: root)
        let next = cursor("one")
        try await first.commit(
            batch(observations: [observation(id: "record-1", providerIdentifier: "hk-1", value: 61)],
                  nextCursor: next),
            expectedPriorCursor: nil
        )

        let reopened = FileObservationStore(rootDirectory: root)
        let reopenedCursor = try await reopened.cursor(for: provider)
        let reopenedRows = try await reopened.observations(for: provider)
        let reopenedRecord = try await reopened.observation(provider: provider, providerIdentifier: "hk-1")
        XCTAssertEqual(reopenedCursor, next)
        XCTAssertEqual(reopenedRows.map(\.id), ["record-1"])
        XCTAssertEqual(reopenedRecord?.value.value, 61)
    }

    func testUpsertIsIdempotentByProviderIdentifier() async throws {
        let root = try temporaryDirectory()
        let store = FileObservationStore(rootDirectory: root)
        let firstCursor = cursor("one")
        let secondCursor = cursor("two")

        try await store.commit(
            batch(observations: [observation(id: "old", providerIdentifier: "hk-1", value: 60)],
                  nextCursor: firstCursor),
            expectedPriorCursor: nil
        )
        try await store.commit(
            batch(observations: [observation(id: "new", providerIdentifier: "hk-1", value: 63)],
                  nextCursor: secondCursor),
            expectedPriorCursor: firstCursor
        )

        let rows = try await store.observations(for: provider)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, "new")
        XCTAssertEqual(rows.first?.value.value, 63)
        let committedCursor = try await store.cursor(for: provider)
        XCTAssertEqual(committedCursor, secondCursor)
    }

    func testDeletionRemovesObservationWhileZeroValueRemainsMeasuredEvidence() async throws {
        let root = try temporaryDirectory()
        let store = FileObservationStore(rootDirectory: root)
        let firstCursor = cursor("one")
        let secondCursor = cursor("two")

        try await store.commit(
            batch(observations: [
                observation(id: "zero", providerIdentifier: "hk-zero", value: 0),
                observation(id: "delete", providerIdentifier: "hk-delete", value: 72),
            ], nextCursor: firstCursor),
            expectedPriorCursor: nil
        )
        try await store.commit(
            batch(observations: [],
                  deletions: [ObservationDeletion(provider: provider, providerIdentifier: "hk-delete")],
                  nextCursor: secondCursor),
            expectedPriorCursor: firstCursor
        )

        let rows = try await store.observations(for: provider)
        XCTAssertEqual(rows.map(\.id), ["zero"])
        XCTAssertEqual(rows.first?.value.value, 0)
    }

    func testStaleCursorIsRejectedWithoutChangingCommittedState() async throws {
        let root = try temporaryDirectory()
        let store = FileObservationStore(rootDirectory: root)
        let firstCursor = cursor("one")
        try await store.commit(
            batch(observations: [observation(id: "first", providerIdentifier: "hk-1", value: 61)],
                  nextCursor: firstCursor),
            expectedPriorCursor: nil
        )

        do {
            try await store.commit(
                batch(observations: [observation(id: "stale", providerIdentifier: "hk-2", value: 70)],
                      nextCursor: cursor("two")),
                expectedPriorCursor: nil
            )
            XCTFail("expected stale cursor rejection")
        } catch let error as ObservationStoreError {
            XCTAssertEqual(error, .staleCursor)
        }

        let cursorAfterStaleCommit = try await store.cursor(for: provider)
        let rowsAfterStaleCommit = try await store.observations(for: provider)
        XCTAssertEqual(cursorAfterStaleCommit, firstCursor)
        XCTAssertEqual(rowsAfterStaleCommit.map(\.id), ["first"])
    }

    func testWriteFailureDoesNotAdvanceCursorOrApplyBatch() async throws {
        struct ExpectedWriteFailure: Error {}
        let root = try temporaryDirectory()
        let initial = FileObservationStore(rootDirectory: root)
        let firstCursor = cursor("one")
        try await initial.commit(
            batch(observations: [observation(id: "first", providerIdentifier: "hk-1", value: 61)],
                  nextCursor: firstCursor),
            expectedPriorCursor: nil
        )

        let failing = FileObservationStore(rootDirectory: root) { _, _ in
            throw ExpectedWriteFailure()
        }
        do {
            try await failing.commit(
                batch(observations: [observation(id: "second", providerIdentifier: "hk-2", value: 70)],
                      nextCursor: cursor("two")),
                expectedPriorCursor: firstCursor
            )
            XCTFail("expected injected write failure")
        } catch is ExpectedWriteFailure {
            // expected
        }

        let reopened = FileObservationStore(rootDirectory: root)
        let cursorAfterFailure = try await reopened.cursor(for: provider)
        let rowsAfterFailure = try await reopened.observations(for: provider)
        XCTAssertEqual(cursorAfterFailure, firstCursor)
        XCTAssertEqual(rowsAfterFailure.map(\.id), ["first"])
    }

    func testInvalidBatchIsRejectedBeforeAnyCursorExists() async throws {
        let root = try temporaryDirectory()
        let store = FileObservationStore(rootDirectory: root)
        let duplicate = observation(id: "one", providerIdentifier: "same", value: 60)
        let second = observation(id: "two", providerIdentifier: "same", value: 61)

        do {
            try await store.commit(
                batch(observations: [duplicate, second], nextCursor: cursor("one")),
                expectedPriorCursor: nil
            )
            XCTFail("expected duplicate provider identifier rejection")
        } catch let error as ObservationChangeValidationError {
            XCTAssertEqual(error, .duplicateObservationProviderIdentifier("same"))
        }

        let invalidCursor = try await store.cursor(for: provider)
        let invalidRows = try await store.observations(for: provider)
        XCTAssertNil(invalidCursor)
        XCTAssertTrue(invalidRows.isEmpty)
    }

    func testProvidersAreIsolatedIntoIndependentLogs() async throws {
        let root = try temporaryDirectory()
        let heartRateStore = FileObservationStore(rootDirectory: root)
        let hrCursor = cursor("hr")
        try await heartRateStore.commit(
            batch(observations: [observation(id: "hr", providerIdentifier: "hr-1", value: 65)],
                  nextCursor: hrCursor),
            expectedPriorCursor: nil
        )

        let otherProvider = "healthkit.hrv.sdnn"
        let hrvCursor = ProviderCursor(provider: otherProvider, payload: Data("hrv".utf8))
        let hrv = ObservationRecord(
            id: "hrv",
            metric: .heartRateVariabilitySDNN,
            value: MetricValue(value: 44, unit: .milliseconds),
            startDate: Date(timeIntervalSince1970: 1_700_000_010),
            endDate: Date(timeIntervalSince1970: 1_700_000_010),
            provenance: ObservationProvenance(
                classification: .measured,
                source: SourceIdentity(provider: otherProvider, identifier: "com.apple.Health"),
                providerIdentifier: "hrv-1"
            ),
            ingestedAt: Date(timeIntervalSince1970: 1_700_000_020)
        )
        try await heartRateStore.commit(
            ObservationChangeBatch(provider: otherProvider,
                                   observations: [hrv],
                                   deletions: [],
                                   nextCursor: hrvCursor),
            expectedPriorCursor: nil
        )

        let heartRows = try await heartRateStore.observations(for: provider)
        let hrvRows = try await heartRateStore.observations(for: otherProvider)
        let storedHeartCursor = try await heartRateStore.cursor(for: provider)
        let storedHrvCursor = try await heartRateStore.cursor(for: otherProvider)
        XCTAssertEqual(heartRows.map(\.id), ["hr"])
        XCTAssertEqual(hrvRows.map(\.id), ["hrv"])
        XCTAssertEqual(storedHeartCursor, hrCursor)
        XCTAssertEqual(storedHrvCursor, hrvCursor)
    }
}
