import Foundation

/// Whether a value is directly observed, deterministically calculated, model-estimated,
/// or isolated research output. This classification is deliberately orthogonal to source.
public enum EvidenceClassification: String, Codable, CaseIterable, Sendable, Equatable {
    case measured
    case derived
    case estimated
    case experimental
}

/// Provider-independent metric identity. A string-backed type keeps the schema extensible without
/// collapsing metrics that share a broad label but use incompatible definitions.
public struct HealthMetricKind: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let heartRate = Self(rawValue: "heartRate")
    public static let restingHeartRate = Self(rawValue: "restingHeartRate")
    public static let heartRateVariabilitySDNN = Self(rawValue: "heartRateVariability.sdnn")
    public static let heartRateVariabilityRMSSD = Self(rawValue: "heartRateVariability.rmssd")
    public static let respiratoryRate = Self(rawValue: "respiratoryRate")
    public static let oxygenSaturation = Self(rawValue: "oxygenSaturation")
    public static let skinTemperature = Self(rawValue: "skinTemperature")
    public static let activeEnergy = Self(rawValue: "activeEnergy")
    public static let steps = Self(rawValue: "steps")
    public static let walkingRunningDistance = Self(rawValue: "distance.walkingRunning")
    public static let cyclingDistance = Self(rawValue: "distance.cycling")
    public static let swimmingDistance = Self(rawValue: "distance.swimming")
    public static let cadence = Self(rawValue: "cadence")
    public static let power = Self(rawValue: "power")
    public static let sleepDuration = Self(rawValue: "sleep.duration")
    public static let timeInBed = Self(rawValue: "sleep.timeInBed")
}

/// Explicit unit identity. Values are not silently converted at the model boundary.
public struct MetricUnit: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let beatsPerMinute = Self(rawValue: "count/min")
    public static let milliseconds = Self(rawValue: "ms")
    public static let breathsPerMinute = Self(rawValue: "breaths/min")
    public static let fraction = Self(rawValue: "fraction")
    public static let percent = Self(rawValue: "percent")
    public static let celsius = Self(rawValue: "degC")
    public static let kilocalories = Self(rawValue: "kcal")
    public static let count = Self(rawValue: "count")
    public static let meters = Self(rawValue: "m")
    public static let seconds = Self(rawValue: "s")
    public static let watts = Self(rawValue: "W")
    public static let revolutionsPerMinute = Self(rawValue: "rev/min")
    public static let unitless = Self(rawValue: "1")
}

public struct MetricValue: Codable, Hashable, Sendable {
    public let value: Double
    public let unit: MetricUnit

    public init(value: Double, unit: MetricUnit) {
        self.value = value
        self.unit = unit
    }
}

/// Stable identity for the logical source that supplied an observation, for example WHOOP,
/// HealthKit, or a future provider adapter.
public struct SourceIdentity: Codable, Hashable, Sendable {
    public let provider: String
    public let identifier: String
    public let displayName: String?

    public init(provider: String, identifier: String, displayName: String? = nil) {
        self.provider = provider
        self.identifier = identifier
        self.displayName = displayName
    }
}

/// Device metadata is optional because not every provider exposes it. Missing fields remain missing
/// instead of being back-filled with guessed values.
public struct DeviceIdentity: Codable, Hashable, Sendable {
    public let identifier: String?
    public let manufacturer: String?
    public let model: String?
    public let hardwareVersion: String?
    public let firmwareVersion: String?

    public init(identifier: String? = nil,
                manufacturer: String? = nil,
                model: String? = nil,
                hardwareVersion: String? = nil,
                firmwareVersion: String? = nil) {
        self.identifier = identifier
        self.manufacturer = manufacturer
        self.model = model
        self.hardwareVersion = hardwareVersion
        self.firmwareVersion = firmwareVersion
    }
}

public enum ObservationQualityState: String, Codable, CaseIterable, Sendable, Equatable {
    case unknown
    case nominal
    case degraded
}

/// Quality describes the evidence itself, not confidence in a future physiological interpretation.
public struct ObservationQuality: Codable, Hashable, Sendable {
    public let state: ObservationQualityState
    public let coverageFraction: Double?
    public let flags: [String]

    public init(state: ObservationQualityState = .unknown,
                coverageFraction: Double? = nil,
                flags: [String] = []) {
        self.state = state
        self.coverageFraction = coverageFraction
        self.flags = flags
    }
}

/// Traceability that must survive normalisation. Provider identifiers and external identifiers are
/// intentionally separate because a provider's record key is not necessarily a cross-system identity.
public struct ObservationProvenance: Codable, Hashable, Sendable {
    public let classification: EvidenceClassification
    public let source: SourceIdentity
    public let device: DeviceIdentity?
    public let providerIdentifier: String?
    public let externalIdentifier: String?

    public init(classification: EvidenceClassification,
                source: SourceIdentity,
                device: DeviceIdentity? = nil,
                providerIdentifier: String? = nil,
                externalIdentifier: String? = nil) {
        self.classification = classification
        self.source = source
        self.device = device
        self.providerIdentifier = providerIdentifier
        self.externalIdentifier = externalIdentifier
    }
}

/// Canonical provider observation. It preserves the provider's evidence and identity without deciding
/// which source should win a later reconciliation step.
public struct ObservationRecord: Codable, Hashable, Sendable {
    public let id: String
    public let metric: HealthMetricKind
    public let value: MetricValue
    public let startDate: Date
    public let endDate: Date
    public let quality: ObservationQuality
    public let provenance: ObservationProvenance
    public let ingestedAt: Date

    public init(id: String,
                metric: HealthMetricKind,
                value: MetricValue,
                startDate: Date,
                endDate: Date,
                quality: ObservationQuality = .init(),
                provenance: ObservationProvenance,
                ingestedAt: Date) {
        self.id = id
        self.metric = metric
        self.value = value
        self.startDate = startDate
        self.endDate = endDate
        self.quality = quality
        self.provenance = provenance
        self.ingestedAt = ingestedAt
    }
}

public struct AlgorithmIdentity: Codable, Hashable, Sendable {
    public let identifier: String
    public let version: String
    public let implementationRevision: String?

    public init(identifier: String, version: String, implementationRevision: String? = nil) {
        self.identifier = identifier
        self.version = version
        self.implementationRevision = implementationRevision
    }
}

public enum ValidationStatus: String, Codable, CaseIterable, Sendable, Equatable {
    case unvalidated
    case internallyValidated
    case externallyValidated
}

/// Result produced from canonical evidence. The input fingerprint is opaque to this package; callers
/// choose the deterministic hashing scheme, while this record preserves the exact identity they used.
public struct DerivedMetricRecord: Codable, Hashable, Sendable {
    public let id: String
    public let metric: HealthMetricKind
    public let value: MetricValue
    public let classification: EvidenceClassification
    public let inputStartDate: Date
    public let inputEndDate: Date
    public let algorithm: AlgorithmIdentity
    public let inputFingerprint: String
    public let generatedAt: Date
    public let evidenceQuality: ObservationQuality
    public let validationStatus: ValidationStatus

    public init(id: String,
                metric: HealthMetricKind,
                value: MetricValue,
                classification: EvidenceClassification,
                inputStartDate: Date,
                inputEndDate: Date,
                algorithm: AlgorithmIdentity,
                inputFingerprint: String,
                generatedAt: Date,
                evidenceQuality: ObservationQuality = .init(),
                validationStatus: ValidationStatus = .unvalidated) {
        self.id = id
        self.metric = metric
        self.value = value
        self.classification = classification
        self.inputStartDate = inputStartDate
        self.inputEndDate = inputEndDate
        self.algorithm = algorithm
        self.inputFingerprint = inputFingerprint
        self.generatedAt = generatedAt
        self.evidenceQuality = evidenceQuality
        self.validationStatus = validationStatus
    }
}

public enum CanonicalEvidenceValidationError: Error, Sendable, Equatable {
    case invalidRecordIdentifier
    case invalidMetricIdentifier
    case invalidUnitIdentifier
    case nonFiniteMetricValue
    case invalidTimeRange
    case invalidSourceIdentity
    case invalidCoverageFraction
    case invalidAlgorithmIdentity
    case missingInputFingerprint
    case measuredDerivedMetric
}

/// Structural validation only. This validates the canonical contract; it does not claim that a sensor,
/// provider, algorithm, or physiological interpretation is scientifically accurate.
public enum CanonicalEvidenceValidator {
    public static func validate(_ record: ObservationRecord) throws {
        try validateIdentifier(record.id, error: .invalidRecordIdentifier)
        try validateMetric(record.metric)
        try validateValue(record.value)
        guard record.endDate >= record.startDate else {
            throw CanonicalEvidenceValidationError.invalidTimeRange
        }
        try validateSource(record.provenance.source)
        try validateQuality(record.quality)
    }

    public static func validate(_ record: DerivedMetricRecord) throws {
        try validateIdentifier(record.id, error: .invalidRecordIdentifier)
        try validateMetric(record.metric)
        try validateValue(record.value)
        guard record.inputEndDate >= record.inputStartDate else {
            throw CanonicalEvidenceValidationError.invalidTimeRange
        }
        guard record.classification != .measured else {
            throw CanonicalEvidenceValidationError.measuredDerivedMetric
        }
        try validateIdentifier(record.algorithm.identifier, error: .invalidAlgorithmIdentity)
        try validateIdentifier(record.algorithm.version, error: .invalidAlgorithmIdentity)
        if let revision = record.algorithm.implementationRevision {
            try validateIdentifier(revision, error: .invalidAlgorithmIdentity)
        }
        try validateIdentifier(record.inputFingerprint, error: .missingInputFingerprint)
        try validateQuality(record.evidenceQuality)
    }

    private static func validateMetric(_ metric: HealthMetricKind) throws {
        try validateIdentifier(metric.rawValue, error: .invalidMetricIdentifier)
    }

    private static func validateValue(_ value: MetricValue) throws {
        guard value.value.isFinite else {
            throw CanonicalEvidenceValidationError.nonFiniteMetricValue
        }
        try validateIdentifier(value.unit.rawValue, error: .invalidUnitIdentifier)
    }

    private static func validateSource(_ source: SourceIdentity) throws {
        do {
            try validateIdentifier(source.provider, error: .invalidSourceIdentity)
            try validateIdentifier(source.identifier, error: .invalidSourceIdentity)
        } catch {
            throw CanonicalEvidenceValidationError.invalidSourceIdentity
        }
    }

    private static func validateQuality(_ quality: ObservationQuality) throws {
        if let coverage = quality.coverageFraction,
           !coverage.isFinite || coverage < 0 || coverage > 1 {
            throw CanonicalEvidenceValidationError.invalidCoverageFraction
        }
    }

    private static func validateIdentifier(_ value: String,
                                           error: CanonicalEvidenceValidationError) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw error
        }
    }
}
