import Foundation

/// One loss-aware workout representation shared by HealthKit write-back and activity-file export.
///
/// This model is intentionally richer than the persisted `WorkoutRow`. A caller may populate only the
/// fields it can prove. Missing data stays `nil`/empty; a summary distance or elevation value does not
/// imply a GPS route, and an untimed route point does not become a timed sample merely because the
/// workout has start/end timestamps.
public struct CanonicalWorkout: Sendable, Equatable {
    public enum DataSource: String, Sendable, Equatable, Hashable, CaseIterable {
        case whoopBLE = "whoop-ble"
        case whoopImport = "whoop-import"
        case noopComputed = "noop-computed"
        case appleHealth = "apple-health"
        case coreLocation = "core-location"
        case manual = "manual"
        case activityFile = "activity-file"
        case lifting = "lifting"
        case legacyDetected = "legacy-detected"
        case unknown = "unknown"
    }

    public enum ValueStatus: String, Sendable, Equatable {
        case measured
        case imported
        case derived
        case manual
    }

    public enum Field: String, Sendable, Equatable, Hashable, CaseIterable {
        case identity, sport, timing, duration, heartRateSamples, heartRateSummary
        case distance, energy, route, altitude, elevation, cadence, power, laps, strain, coverage
    }

    /// Provenance belongs to the field, not just the workout. One workout may legitimately contain,
    /// for example, a WHOOP HR trace and a Core Location route.
    public struct Provenance: Sendable, Equatable {
        public var source: DataSource
        public var status: ValueStatus
        public var detail: String?

        public init(source: DataSource, status: ValueStatus, detail: String? = nil) {
            self.source = source
            self.status = status
            self.detail = detail
        }
    }

    public struct HRSample: Sendable, Equatable {
        public var timestamp: Int
        public var bpm: Int
        public var provenance: Provenance

        public init(timestamp: Int, bpm: Int, provenance: Provenance) {
            self.timestamp = timestamp
            self.bpm = bpm
            self.provenance = provenance
        }
    }

    /// A genuine route fix. `timestamp == nil` means the stored source retained position but lost timing.
    /// Exporters must not synthesize a timestamp for that point.
    public struct TrackPoint: Sendable, Equatable {
        public var timestamp: Int?
        public var latitude: Double
        public var longitude: Double
        public var altitudeM: Double?
        public var distanceM: Double?
        public var speedMps: Double?
        public var heartRateBpm: Int?
        public var cadenceRpm: Int?
        public var powerWatts: Int?
        public var provenance: Provenance

        public init(timestamp: Int? = nil,
                    latitude: Double,
                    longitude: Double,
                    altitudeM: Double? = nil,
                    distanceM: Double? = nil,
                    speedMps: Double? = nil,
                    heartRateBpm: Int? = nil,
                    cadenceRpm: Int? = nil,
                    powerWatts: Int? = nil,
                    provenance: Provenance) {
            self.timestamp = timestamp
            self.latitude = latitude
            self.longitude = longitude
            self.altitudeM = altitudeM
            self.distanceM = distanceM
            self.speedMps = speedMps
            self.heartRateBpm = heartRateBpm
            self.cadenceRpm = cadenceRpm
            self.powerWatts = powerWatts
            self.provenance = provenance
        }
    }

    public struct Lap: Sendable, Equatable {
        public var startTimestamp: Int
        public var endTimestamp: Int
        public var elapsedDurationS: Double?
        public var movingDurationS: Double?
        public var distanceM: Double?
        public var ascentM: Double?
        public var descentM: Double?
        public var energyKcal: Double?
        public var averageHeartRate: Int?
        public var maximumHeartRate: Int?
        public var averageCadenceRpm: Int?
        public var averagePowerWatts: Int?

        public init(startTimestamp: Int,
                    endTimestamp: Int,
                    elapsedDurationS: Double? = nil,
                    movingDurationS: Double? = nil,
                    distanceM: Double? = nil,
                    ascentM: Double? = nil,
                    descentM: Double? = nil,
                    energyKcal: Double? = nil,
                    averageHeartRate: Int? = nil,
                    maximumHeartRate: Int? = nil,
                    averageCadenceRpm: Int? = nil,
                    averagePowerWatts: Int? = nil) {
            self.startTimestamp = startTimestamp
            self.endTimestamp = endTimestamp
            self.elapsedDurationS = elapsedDurationS
            self.movingDurationS = movingDurationS
            self.distanceM = distanceM
            self.ascentM = ascentM
            self.descentM = descentM
            self.energyKcal = energyKcal
            self.averageHeartRate = averageHeartRate
            self.maximumHeartRate = maximumHeartRate
            self.averageCadenceRpm = averageCadenceRpm
            self.averagePowerWatts = averagePowerWatts
        }
    }

    public var stableID: String
    public var source: DataSource
    public var sport: String
    public var startTimestamp: Int
    public var endTimestamp: Int
    public var timeZoneIdentifier: String?
    public var elapsedDurationS: Double?
    public var movingDurationS: Double?
    public var heartRateSamples: [HRSample]
    public var averageHeartRate: Int?
    public var maximumHeartRate: Int?
    public var distanceM: Double?
    public var energyKcal: Double?
    public var route: [TrackPoint]
    public var ascentM: Double?
    public var descentM: Double?
    public var averageCadenceRpm: Int?
    public var averagePowerWatts: Int?
    public var laps: [Lap]
    /// Proprietary metrics remain namespaced inside NOOP. They are not automatically mapped to HealthKit/FIT.
    public var strain: Double?
    public var proprietaryMetrics: [String: Double]
    public var recordingCoverage: Double?
    public var provenance: [Field: Provenance]

    public init(stableID: String,
                source: DataSource,
                sport: String,
                startTimestamp: Int,
                endTimestamp: Int,
                timeZoneIdentifier: String? = nil,
                elapsedDurationS: Double? = nil,
                movingDurationS: Double? = nil,
                heartRateSamples: [HRSample] = [],
                averageHeartRate: Int? = nil,
                maximumHeartRate: Int? = nil,
                distanceM: Double? = nil,
                energyKcal: Double? = nil,
                route: [TrackPoint] = [],
                ascentM: Double? = nil,
                descentM: Double? = nil,
                averageCadenceRpm: Int? = nil,
                averagePowerWatts: Int? = nil,
                laps: [Lap] = [],
                strain: Double? = nil,
                proprietaryMetrics: [String: Double] = [:],
                recordingCoverage: Double? = nil,
                provenance: [Field: Provenance] = [:]) {
        self.stableID = stableID
        self.source = source
        self.sport = sport
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
        self.timeZoneIdentifier = timeZoneIdentifier
        self.elapsedDurationS = elapsedDurationS
        self.movingDurationS = movingDurationS
        self.heartRateSamples = heartRateSamples.sorted { $0.timestamp < $1.timestamp }
        self.averageHeartRate = averageHeartRate
        self.maximumHeartRate = maximumHeartRate
        self.distanceM = distanceM
        self.energyKcal = energyKcal
        self.route = route
        self.ascentM = ascentM
        self.descentM = descentM
        self.averageCadenceRpm = averageCadenceRpm
        self.averagePowerWatts = averagePowerWatts
        self.laps = laps.sorted { $0.startTimestamp < $1.startTimestamp }
        self.strain = strain
        self.proprietaryMetrics = proprietaryMetrics
        self.recordingCoverage = recordingCoverage
        self.provenance = provenance
    }

    /// The identifier the future Strava upload layer should use. It is stable across repeated exports.
    public var externalID: String { "noop-\(stableID)" }

    /// Build the canonical id from the store's real natural workout key: `(deviceId, startTs, sport)`.
    /// The two independent 64-bit FNV-1a passes are a compact, deterministic representation of ALL
    /// natural-key components, not a timestamp-only identity. This is an identity hash, not a security hash.
    public static func persistedStableID(deviceID: String, startTimestamp: Int, sport: String) -> String {
        let normalizedSport = sport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = "\(deviceID)\u{1f}\(startTimestamp)\u{1f}\(normalizedSport)"
        let bytes = Array(key.utf8)
        let a = fnv1a64(bytes, seed: 0xcbf29ce484222325)
        let b = fnv1a64(bytes.reversed(), seed: 0x84222325cbf29ce4)
        return String(format: "w1-%016llx%016llx", a, b)
    }

    private static func fnv1a64<S: Sequence>(_ bytes: S, seed: UInt64) -> UInt64 where S.Element == UInt8 {
        var hash = seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    /// Deterministic, field-specific source precedence. This does not merge conflicting candidates;
    /// it documents which source a resolver is allowed to choose when multiple candidates describe
    /// the same canonical field. The winning field must still retain its own provenance.
    public static func sourcePrecedence(for field: Field) -> [DataSource] {
        switch field {
        case .route, .altitude, .elevation:
            return [.coreLocation, .activityFile, .appleHealth, .whoopImport, .whoopBLE,
                    .manual, .noopComputed, .lifting, .legacyDetected, .unknown]
        case .heartRateSamples, .heartRateSummary, .coverage:
            return [.whoopBLE, .activityFile, .appleHealth, .whoopImport, .coreLocation,
                    .noopComputed, .manual, .lifting, .legacyDetected, .unknown]
        case .power, .cadence:
            return [.activityFile, .appleHealth, .whoopImport, .whoopBLE, .coreLocation,
                    .noopComputed, .manual, .lifting, .legacyDetected, .unknown]
        case .strain:
            return [.whoopImport, .noopComputed, .whoopBLE, .legacyDetected, .activityFile,
                    .appleHealth, .manual, .lifting, .coreLocation, .unknown]
        case .identity, .sport, .timing, .duration, .distance, .energy, .laps:
            // For structural/summary fields, prefer the selected workout's primary source rather than
            // silently stitching two overlapping workouts together. A higher layer can use this order
            // only after it has established that candidates represent the same real-world activity.
            return [.whoopBLE, .whoopImport, .activityFile, .appleHealth, .manual,
                    .lifting, .noopComputed, .legacyDetected, .coreLocation, .unknown]
        }
    }
}
