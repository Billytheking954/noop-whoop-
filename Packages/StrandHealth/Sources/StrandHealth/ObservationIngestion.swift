import Foundation

public enum ObservationIngestionError: Error, Sendable, Equatable {
    case invalidProviderIdentifier
    case providerMismatch(expected: String, actual: String)
}

/// Executes one provider-independent incremental ingestion transaction in the only safe order:
/// load the committed cursor, fetch changes from that cursor, then atomically commit changes + next cursor.
public struct ObservationIngestionCoordinator: Sendable {
    public init() {}

    @discardableResult
    public func sync(providerIdentifier: String,
                     provider: any HealthObservationProvider,
                     store: any ObservationChangeStore) async throws -> ObservationChangeBatch {
        guard !providerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ObservationIngestionError.invalidProviderIdentifier
        }

        let priorCursor = try await store.cursor(for: providerIdentifier)
        let batch = try await provider.changes(since: priorCursor)
        guard batch.provider == providerIdentifier else {
            throw ObservationIngestionError.providerMismatch(expected: providerIdentifier,
                                                             actual: batch.provider)
        }
        try await store.commit(batch, expectedPriorCursor: priorCursor)
        return batch
    }
}
