import Foundation
import XCTest
@testable import StrandHealth

final class ObservationProviderTests: XCTestCase {

    func testBatchRoundTripPreservesOpaqueCursorAndDeletion() throws {
        let batch = fixtureBatch()
        let data = try JSONEncoder().encode(batch)
        let decoded = try JSONDecoder().decode(ObservationChangeBatch.self, from: data)

        XCTAssertEqual(decoded, batch)
        XCTAssertEqual(decoded.nextCursor.payload, Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(decoded.deletions.first?.providerIdentifier, "deleted-1")
    }

    func testValidatorAcceptsZeroValuedObservationAlongsideDeletion() throws {
        let batch = fixtureBatch(value: 0)

        XCTAssertNoThrow(try ObservationChangeBatchValidator.validate(batch))
        XCTAssertFalse(batch.isEmpty)
        XCTAssertEqual(batch.observations.first?.value.value, 0)
        XCTAssertEqual(batch.deletions.first?.providerIdentifier, "deleted-1")
    }

    func testValidatorRejectsCursorFromAnotherProvider() {
        let batch = fixtureBatch(cursor: ProviderCursor(provider: "other", payload: Data([1])))

        XCTAssertThrowsError(try ObservationChangeBatchValidator.validate(batch)) { error in
            XCTAssertEqual(error as? ObservationChangeValidationError, .cursorProviderMismatch)
        }
    }

    func testValidatorRequiresProviderIdentifierForIncrementalObservations() {
        let batch = fixtureBatch(observationProviderIdentifier: nil)

        XCTAssertThrowsError(try ObservationChangeBatchValidator.validate(batch)) { error in
            XCTAssertEqual(error as? ObservationChangeValidationError,
                           .missingObservationProviderIdentifier)
        }
    }

    func testValidatorRejectsDuplicateObservationProviderIdentifiers() {
        let observation = fixtureObservation(providerIdentifier: "sample-1")
        let batch = ObservationChangeBatch(
            provider: "healthkit",
            observations: [observation, observation],
            deletions: [],
            nextCursor: ProviderCursor(provider: "healthkit", payload: Data([1]))
        )

        XCTAssertThrowsError(try ObservationChangeBatchValidator.validate(batch)) { error in
            XCTAssertEqual(error as? ObservationChangeValidationError,
                           .duplicateObservationProviderIdentifier("sample-1"))
        }
    }

    func testValidatorRejectsDuplicateDeletionProviderIdentifiers() {
        let deletion = ObservationDeletion(provider: "healthkit", providerIdentifier: "deleted-1")
        let batch = ObservationChangeBatch(
            provider: "healthkit",
            observations: [],
            deletions: [deletion, deletion],
            nextCursor: ProviderCursor(provider: "healthkit", payload: Data([1]))
        )

        XCTAssertThrowsError(try ObservationChangeBatchValidator.validate(batch)) { error in
            XCTAssertEqual(error as? ObservationChangeValidationError,
                           .duplicateDeletionProviderIdentifier("deleted-1"))
        }
    }

    func testValidatorRejectsObservationDeletionConflict() {
        let batch = ObservationChangeBatch(
            provider: "healthkit",
            observations: [fixtureObservation(providerIdentifier: "same-id")],
            deletions: [ObservationDeletion(provider: "healthkit", providerIdentifier: "same-id")],
            nextCursor: ProviderCursor(provider: "healthkit", payload: Data([1]))
        )

        XCTAssertThrowsError(try ObservationChangeBatchValidator.validate(batch)) { error in
            XCTAssertEqual(error as? ObservationChangeValidationError,
                           .observationDeletionConflict("same-id"))
        }
    }

    func testValidatorRejectsDeletionFromAnotherProvider() {
        let batch = ObservationChangeBatch(
            provider: "healthkit",
            observations: [],
            deletions: [ObservationDeletion(provider: "whoop", providerIdentifier: "deleted-1")],
            nextCursor: ProviderCursor(provider: "healthkit", payload: Data([1]))
        )

        XCTAssertThrowsError(try ObservationChangeBatchValidator.validate(batch)) { error in
            XCTAssertEqual(error as? ObservationChangeValidationError, .invalidDeletionProvider)
        }
    }

    func testValidatorWrapsCanonicalObservationFailure() {
        let invalid = ObservationRecord(
            id: "bad-window",
            metric: .heartRate,
            value: MetricValue(value: 60, unit: .beatsPerMinute),
            startDate: Date(timeIntervalSince1970: 2),
            endDate: Date(timeIntervalSince1970: 1),
            provenance: ObservationProvenance(
                classification: .measured,
                source: SourceIdentity(provider: "healthkit", identifier: "fixture"),
                providerIdentifier: "sample-1"
            ),
            ingestedAt: Date(timeIntervalSince1970: 3)
        )
        let batch = ObservationChangeBatch(
            provider: "healthkit",
            observations: [invalid],
            deletions: [],
            nextCursor: ProviderCursor(provider: "healthkit", payload: Data([1]))
        )

        XCTAssertThrowsError(try ObservationChangeBatchValidator.validate(batch)) { error in
            XCTAssertEqual(error as? ObservationChangeValidationError,
                           .invalidObservation(.invalidTimeRange))
        }
    }

    func testProviderProtocolCanAdvanceCursorDeterministically() async throws {
        let expected = fixtureBatch()
        let provider = FixtureProvider(batch: expected)

        let result = try await provider.changes(since: nil)

        XCTAssertEqual(result, expected)
    }

    private func fixtureBatch(value: Double = 72,
                              observationProviderIdentifier: String? = "sample-1",
                              cursor: ProviderCursor? = nil) -> ObservationChangeBatch {
        ObservationChangeBatch(
            provider: "healthkit",
            observations: [fixtureObservation(value: value,
                                              providerIdentifier: observationProviderIdentifier)],
            deletions: [ObservationDeletion(provider: "healthkit", providerIdentifier: "deleted-1")],
            nextCursor: cursor ?? ProviderCursor(provider: "healthkit",
                                                 payload: Data([0x01, 0x02, 0x03]))
        )
    }

    private func fixtureObservation(value: Double = 72,
                                    providerIdentifier: String?) -> ObservationRecord {
        ObservationRecord(
            id: "healthkit:\(providerIdentifier ?? "missing")",
            metric: .heartRate,
            value: MetricValue(value: value, unit: .beatsPerMinute),
            startDate: Date(timeIntervalSince1970: 1_000),
            endDate: Date(timeIntervalSince1970: 1_001),
            provenance: ObservationProvenance(
                classification: .measured,
                source: SourceIdentity(provider: "healthkit", identifier: "fixture"),
                providerIdentifier: providerIdentifier
            ),
            ingestedAt: Date(timeIntervalSince1970: 2_000)
        )
    }
}

private struct FixtureProvider: HealthObservationProvider {
    let batch: ObservationChangeBatch

    func changes(since cursor: ProviderCursor?) async throws -> ObservationChangeBatch {
        batch
    }
}
