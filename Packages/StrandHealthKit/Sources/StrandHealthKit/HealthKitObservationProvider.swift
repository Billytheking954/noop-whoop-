import Foundation
import StrandHealth

/// Canonical quantity streams that the HealthKit adapter can ingest without changing their meaning.
///
/// This enum is intentionally provider-facing rather than a second health-metric taxonomy. The mapping
/// below ends at `HealthMetricKind`, and unsupported/ambiguous HealthKit types stay unsupported until
/// their semantics have a deliberate canonical home.
public enum HealthKitQuantityKind: String, CaseIterable, Sendable {
    case heartRate
    case restingHeartRate
    case heartRateVariabilitySDNN
    case oxygenSaturation
    case respiratoryRate
    case bodyTemperature
    case activeEnergy
    case steps
    case walkingRunningDistance
    case cyclingDistance
    case swimmingDistance

    public var metric: HealthMetricKind {
        switch self {
        case .heartRate: return .heartRate
        case .restingHeartRate: return .restingHeartRate
        case .heartRateVariabilitySDNN: return .heartRateVariabilitySDNN
        case .oxygenSaturation: return .oxygenSaturation
        case .respiratoryRate: return .respiratoryRate
        case .bodyTemperature: return .skinTemperature
        case .activeEnergy: return .activeEnergy
        case .steps: return .steps
        case .walkingRunningDistance: return .walkingRunningDistance
        case .cyclingDistance: return .cyclingDistance
        case .swimmingDistance: return .swimmingDistance
        }
    }

    public var canonicalUnit: MetricUnit {
        switch self {
        case .heartRate, .restingHeartRate:
            return .beatsPerMinute
        case .heartRateVariabilitySDNN:
            return .milliseconds
        case .oxygenSaturation:
            // HealthKit's percent quantity is read as a 0...1 fraction. Preserve that source value
            // explicitly instead of silently multiplying it into a different unit at ingestion.
            return .fraction
        case .respiratoryRate:
            return .breathsPerMinute
        case .bodyTemperature:
            return .celsius
        case .activeEnergy:
            return .kilocalories
        case .steps:
            return .count
        case .walkingRunningDistance, .cyclingDistance, .swimmingDistance:
            return .meters
        }
    }

    /// One independently anchored stream per metric. Keeping cursors per stream avoids pretending a
    /// HealthKit anchor for heart rate can advance the state of HRV, steps, or another sample type.
    public var providerIdentifier: String {
        "healthkit.\(metric.rawValue)"
    }
}

#if os(iOS) && canImport(HealthKit)
import HealthKit

public enum HealthKitObservationProviderError: Error, Sendable, Equatable {
    case cursorProviderMismatch(expected: String, actual: String)
    case unsupportedCursorVersion(Int)
    case emptyCursorPayload
    case invalidCursorArchive
    case unavailableQuantityType(String)
    case missingNextAnchor
    case unexpectedSampleType
}

/// Read-only, deletion-aware HealthKit quantity provider for canonical incremental ingestion.
///
/// One instance owns one quantity stream. It deliberately does not persist cursors itself: the caller
/// passes the store's committed cursor in, and `ObservationIngestionCoordinator` persists the returned
/// next cursor atomically with the observations/deletions. This prevents an anchor from moving past data
/// that failed to commit.
///
/// The existing shipping `HealthKitBridge` remains untouched while this provider is introduced. It can
/// therefore be validated alongside production behaviour before any observer is switched over.
public final class HealthKitObservationProvider: @unchecked Sendable, HealthObservationProvider {
    public static let cursorFormatVersion = 1

    public let kind: HealthKitQuantityKind
    private let healthStore: HKHealthStore

    public init(kind: HealthKitQuantityKind, healthStore: HKHealthStore = HKHealthStore()) {
        self.kind = kind
        self.healthStore = healthStore
    }

    public var providerIdentifier: String { kind.providerIdentifier }

    public func changes(since cursor: ProviderCursor?) async throws -> ObservationChangeBatch {
        let priorAnchor = try decode(cursor: cursor)
        guard let quantityType = HKObjectType.quantityType(forIdentifier: kind.quantityTypeIdentifier) else {
            throw HealthKitObservationProviderError.unavailableQuantityType(kind.quantityTypeIdentifier.rawValue)
        }

        let result = try await anchoredChanges(type: quantityType, anchor: priorAnchor)
        let ingestedAt = Date()
        let observations = try result.samples.map { try normalise($0, ingestedAt: ingestedAt) }
        let deletions = result.deleted.map {
            ObservationDeletion(provider: providerIdentifier, providerIdentifier: $0.uuid.uuidString)
        }
        let nextCursor = try encode(anchor: result.anchor)
        let batch = ObservationChangeBatch(
            provider: providerIdentifier,
            observations: observations,
            deletions: deletions,
            nextCursor: nextCursor
        )
        try ObservationChangeBatchValidator.validate(batch)
        return batch
    }

    private func decode(cursor: ProviderCursor?) throws -> HKQueryAnchor? {
        guard let cursor else { return nil }
        guard cursor.provider == providerIdentifier else {
            throw HealthKitObservationProviderError.cursorProviderMismatch(
                expected: providerIdentifier,
                actual: cursor.provider
            )
        }
        guard cursor.formatVersion == Self.cursorFormatVersion else {
            throw HealthKitObservationProviderError.unsupportedCursorVersion(cursor.formatVersion)
        }
        guard !cursor.payload.isEmpty else {
            throw HealthKitObservationProviderError.emptyCursorPayload
        }
        do {
            guard let anchor = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: HKQueryAnchor.self,
                from: cursor.payload
            ) else {
                throw HealthKitObservationProviderError.invalidCursorArchive
            }
            return anchor
        } catch is HealthKitObservationProviderError {
            throw HealthKitObservationProviderError.invalidCursorArchive
        } catch {
            throw HealthKitObservationProviderError.invalidCursorArchive
        }
    }

    private func encode(anchor: HKQueryAnchor) throws -> ProviderCursor {
        let data = try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
        guard !data.isEmpty else { throw HealthKitObservationProviderError.emptyCursorPayload }
        return ProviderCursor(
            provider: providerIdentifier,
            formatVersion: Self.cursorFormatVersion,
            payload: data
        )
    }

    private struct AnchoredResult {
        let samples: [HKQuantitySample]
        let deleted: [HKDeletedObject]
        let anchor: HKQueryAnchor
    }

    private func anchoredChanges(type: HKQuantityType,
                                 anchor: HKQueryAnchor?) async throws -> AnchoredResult {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: Self.notNoopAuthored,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, deleted, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let newAnchor else {
                    continuation.resume(throwing: HealthKitObservationProviderError.missingNextAnchor)
                    return
                }
                let rawSamples = samples ?? []
                let quantitySamples = rawSamples.compactMap { $0 as? HKQuantitySample }
                guard quantitySamples.count == rawSamples.count else {
                    continuation.resume(throwing: HealthKitObservationProviderError.unexpectedSampleType)
                    return
                }
                continuation.resume(returning: AnchoredResult(
                    samples: quantitySamples,
                    deleted: deleted ?? [],
                    anchor: newAnchor
                ))
            }
            healthStore.execute(query)
        }
    }

    private func normalise(_ sample: HKQuantitySample,
                           ingestedAt: Date) throws -> ObservationRecord {
        let value = sample.quantity.doubleValue(for: kind.healthKitUnit)
        let source = sample.sourceRevision.source
        let device = sample.device.map {
            DeviceIdentity(
                identifier: $0.localIdentifier ?? $0.udiDeviceIdentifier,
                manufacturer: $0.manufacturer,
                model: $0.model,
                hardwareVersion: $0.hardwareVersion,
                firmwareVersion: $0.firmwareVersion
            )
        }
        let providerObjectID = sample.uuid.uuidString
        let record = ObservationRecord(
            id: "healthkit:\(providerObjectID)",
            metric: kind.metric,
            value: MetricValue(value: value, unit: kind.canonicalUnit),
            startDate: sample.startDate,
            endDate: sample.endDate,
            quality: ObservationQuality(state: .unknown),
            provenance: ObservationProvenance(
                classification: .measured,
                source: SourceIdentity(
                    provider: providerIdentifier,
                    identifier: source.bundleIdentifier,
                    displayName: source.name
                ),
                device: device,
                providerIdentifier: providerObjectID,
                externalIdentifier: sample.metadata?[HKMetadataKeyExternalUUID] as? String
            ),
            ingestedAt: ingestedAt
        )
        try CanonicalEvidenceValidator.validate(record)
        return record
    }

    /// Match the shipping bridge's loop-prevention rule: samples written by this app must never be
    /// re-imported as Apple Health evidence.
    private static var notNoopAuthored: NSPredicate {
        NSCompoundPredicate(
            notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: [HKSource.default()])
        )
    }
}

private extension HealthKitQuantityKind {
    var quantityTypeIdentifier: HKQuantityTypeIdentifier {
        switch self {
        case .heartRate: return .heartRate
        case .restingHeartRate: return .restingHeartRate
        case .heartRateVariabilitySDNN: return .heartRateVariabilitySDNN
        case .oxygenSaturation: return .oxygenSaturation
        case .respiratoryRate: return .respiratoryRate
        case .bodyTemperature: return .bodyTemperature
        case .activeEnergy: return .activeEnergyBurned
        case .steps: return .stepCount
        case .walkingRunningDistance: return .distanceWalkingRunning
        case .cyclingDistance: return .distanceCycling
        case .swimmingDistance: return .distanceSwimming
        }
    }

    var healthKitUnit: HKUnit {
        switch self {
        case .heartRate, .restingHeartRate, .respiratoryRate:
            return HKUnit.count().unitDivided(by: .minute())
        case .heartRateVariabilitySDNN:
            return .secondUnit(with: .milli)
        case .oxygenSaturation:
            return .percent()
        case .bodyTemperature:
            return .degreeCelsius()
        case .activeEnergy:
            return .kilocalorie()
        case .steps:
            return .count()
        case .walkingRunningDistance, .cyclingDistance, .swimmingDistance:
            return .meter()
        }
    }
}
#endif
