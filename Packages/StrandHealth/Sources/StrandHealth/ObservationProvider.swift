import Foundation

/// Opaque incremental position owned by a provider adapter.
///
/// The canonical layer deliberately does not interpret `payload`: HealthKit may archive an
/// `HKQueryAnchor`, while a future provider may use a page token or another cursor format. The provider
/// and format version prevent callers from accidentally feeding one adapter another adapter's cursor.
public struct ProviderCursor: Codable, Hashable, Sendable {
    public let provider: String
    public let formatVersion: Int
    public let payload: Data

    public init(provider: String, formatVersion: Int = 1, payload: Data) {
        self.provider = provider
        self.formatVersion = formatVersion
        self.payload = payload
    }
}

/// A provider-owned observation that disappeared after an earlier incremental read.
///
/// Deletion APIs such as HealthKit's anchored query expose the provider object identifier but do not
/// necessarily retain the original sample metadata. Keeping deletion as its own event prevents a
/// removed sample from being silently represented as zero or "missing data".
public struct ObservationDeletion: Codable, Hashable, Sendable {
    public let provider: String
    public let providerIdentifier: String

    public init(provider: String, providerIdentifier: String) {
        self.provider = provider
        self.providerIdentifier = providerIdentifier
    }
}

/// One atomic incremental provider result. Callers should persist `nextCursor` only after both the
/// observations and deletions have been committed successfully; otherwise replay the prior cursor.
public struct ObservationChangeBatch: Codable, Hashable, Sendable {
    public let provider: String
    public let observations: [ObservationRecord]
    public let deletions: [ObservationDeletion]
    public let nextCursor: ProviderCursor

    public init(provider: String,
                observations: [ObservationRecord],
                deletions: [ObservationDeletion],
                nextCursor: ProviderCursor) {
        self.provider = provider
        self.observations = observations
        self.deletions = deletions
        self.nextCursor = nextCursor
    }

    public var isEmpty: Bool {
        observations.isEmpty && deletions.isEmpty
    }
}

/// Narrow read contract for incremental health observations. Workout ingestion remains a separate
/// concern so a provider that supports samples does not have to pretend it also supports activities.
public protocol HealthObservationProvider: Sendable {
    func changes(since cursor: ProviderCursor?) async throws -> ObservationChangeBatch
}

public enum ObservationChangeValidationError: Error, Sendable, Equatable {
    case invalidProviderIdentifier
    case cursorProviderMismatch
    case invalidCursorVersion
    case emptyCursorPayload
    case observationProviderMismatch
    case missingObservationProviderIdentifier
    case duplicateObservationProviderIdentifier(String)
    case invalidDeletionProvider
    case invalidDeletionProviderIdentifier
    case duplicateDeletionProviderIdentifier(String)
    case observationDeletionConflict(String)
    case invalidObservation(CanonicalEvidenceValidationError)
}

/// Structural validation for an incremental batch before a persistence transaction accepts it.
///
/// This is intentionally stricter than validating a standalone `ObservationRecord`: incremental
/// upsert/delete semantics require stable provider identifiers, and a single batch must never contain
/// contradictory instructions for the same provider object.
public enum ObservationChangeBatchValidator {
    public static func validate(_ batch: ObservationChangeBatch) throws {
        guard isValidIdentifier(batch.provider) else {
            throw ObservationChangeValidationError.invalidProviderIdentifier
        }
        guard batch.nextCursor.provider == batch.provider else {
            throw ObservationChangeValidationError.cursorProviderMismatch
        }
        guard batch.nextCursor.formatVersion > 0 else {
            throw ObservationChangeValidationError.invalidCursorVersion
        }
        guard !batch.nextCursor.payload.isEmpty else {
            throw ObservationChangeValidationError.emptyCursorPayload
        }

        var observationIdentifiers = Set<String>()
        for observation in batch.observations {
            do {
                try CanonicalEvidenceValidator.validate(observation)
            } catch let error as CanonicalEvidenceValidationError {
                throw ObservationChangeValidationError.invalidObservation(error)
            }

            guard observation.provenance.source.provider == batch.provider else {
                throw ObservationChangeValidationError.observationProviderMismatch
            }
            guard let providerIdentifier = observation.provenance.providerIdentifier,
                  isValidIdentifier(providerIdentifier) else {
                throw ObservationChangeValidationError.missingObservationProviderIdentifier
            }
            guard observationIdentifiers.insert(providerIdentifier).inserted else {
                throw ObservationChangeValidationError.duplicateObservationProviderIdentifier(providerIdentifier)
            }
        }

        var deletionIdentifiers = Set<String>()
        for deletion in batch.deletions {
            guard deletion.provider == batch.provider else {
                throw ObservationChangeValidationError.invalidDeletionProvider
            }
            guard isValidIdentifier(deletion.providerIdentifier) else {
                throw ObservationChangeValidationError.invalidDeletionProviderIdentifier
            }
            guard deletionIdentifiers.insert(deletion.providerIdentifier).inserted else {
                throw ObservationChangeValidationError.duplicateDeletionProviderIdentifier(deletion.providerIdentifier)
            }
        }

        if let conflict = observationIdentifiers.intersection(deletionIdentifiers).sorted().first {
            throw ObservationChangeValidationError.observationDeletionConflict(conflict)
        }
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
