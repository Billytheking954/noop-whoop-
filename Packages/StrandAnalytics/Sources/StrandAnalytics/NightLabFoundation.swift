import Foundation

// NightLabFoundation.swift
//
// Phase 1 of the Night Lab redesign. This file deliberately contains no sleep-classification logic.
// Its job is to keep captured evidence separate from derived answers so future sleep engines can be
// replayed and compared without accidentally training on, or reading, reference labels.
//
// Core rules:
//   1. Raw capture assets are write-once once a night is sealed.
//   2. A sealed raw asset carries an integrity digest supplied by the capture/storage layer.
//   3. Replay inputs can see raw assets and raw-derived coverage only. They cannot see reference labels.
//   4. Every derived run records the exact algorithm identity/version that produced it.
//   5. Reference labels live in their own type and archive namespace and are only for evaluation.

public enum NightSignalKind: String, Codable, Sendable, CaseIterable, Equatable {
    case heartRate
    case rrIntervals
    case accelerometer
    case gyroscope
    case wristStatus
    case optical
    case respiration
    case skinTemperature
    case unknown
}

public enum NightRecordState: String, Codable, Sendable, Equatable {
    case recording
    case sealed
}

/// Metadata for one immutable raw capture asset. The raw bytes remain in the archive; this descriptor is
/// what analytics code is allowed to carry around. `digest` is intentionally algorithm-agnostic so the
/// storage layer can use SHA-256 without making StrandAnalytics depend on a crypto package.
public struct NightRawAsset: Codable, Sendable, Equatable {
    public let id: String
    public let kind: NightSignalKind
    public let relativePath: String
    public let startUnix: Int
    public let endUnix: Int
    public let sampleCount: Int
    public let expectedCadenceHz: Double?
    public let digestAlgorithm: String?
    public let digest: String?

    public init(id: String,
                kind: NightSignalKind,
                relativePath: String,
                startUnix: Int,
                endUnix: Int,
                sampleCount: Int,
                expectedCadenceHz: Double? = nil,
                digestAlgorithm: String? = nil,
                digest: String? = nil) {
        self.id = id
        self.kind = kind
        self.relativePath = relativePath
        self.startUnix = startUnix
        self.endUnix = endUnix
        self.sampleCount = sampleCount
        self.expectedCadenceHz = expectedCadenceHz
        self.digestAlgorithm = digestAlgorithm
        self.digest = digest
    }
}

/// The permanent identity/provenance record for one captured night.
///
/// `schemaVersion` versions the archive contract, not the sleep algorithm. Algorithm versions are recorded
/// separately in `NightAlgorithmIdentity`, which lets the same sealed night be replayed forever.
///
/// v2 adds the exact source-device id, WhoopStore schema version, and the source-stream fingerprint that
/// bracketed the snapshot. They are OPTIONAL so a v1 archive can still decode honestly instead of being
/// retroactively assigned provenance it never recorded.
public struct NightRecordManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let nightID: String
    public let state: NightRecordState
    public let windowStartUnix: Int
    public let windowEndUnix: Int
    public let timezoneOffsetSeconds: Int
    public let sourceDeviceID: String?
    public let sourceDeviceModel: String?
    public let sourceFirmware: String?
    public let sourceStoreSchemaVersion: Int?
    public let sourceStreamFingerprint: String?
    public let noopVersion: String?
    public let rawAssets: [NightRawAsset]

    public init(schemaVersion: Int = NightRecordManifest.currentSchemaVersion,
                nightID: String,
                state: NightRecordState,
                windowStartUnix: Int,
                windowEndUnix: Int,
                timezoneOffsetSeconds: Int,
                sourceDeviceID: String? = nil,
                sourceDeviceModel: String? = nil,
                sourceFirmware: String? = nil,
                sourceStoreSchemaVersion: Int? = nil,
                sourceStreamFingerprint: String? = nil,
                noopVersion: String? = nil,
                rawAssets: [NightRawAsset]) {
        self.schemaVersion = schemaVersion
        self.nightID = nightID
        self.state = state
        self.windowStartUnix = windowStartUnix
        self.windowEndUnix = windowEndUnix
        self.timezoneOffsetSeconds = timezoneOffsetSeconds
        self.sourceDeviceID = sourceDeviceID
        self.sourceDeviceModel = sourceDeviceModel
        self.sourceFirmware = sourceFirmware
        self.sourceStoreSchemaVersion = sourceStoreSchemaVersion
        self.sourceStreamFingerprint = sourceStreamFingerprint
        self.noopVersion = noopVersion
        self.rawAssets = rawAssets
    }
}

public enum NightLabValidationError: Error, Sendable, Equatable {
    case invalidNightID
    case invalidWindow
    case duplicateAssetID(String)
    case unsafeRawPath(String)
    case invalidAssetWindow(String)
    case invalidSampleCount(String)
    case invalidCadence(String)
    case missingIntegrityDigest(String)
}

/// Structural validation for a Night Lab manifest. This is intentionally strict at the seal boundary.
/// A recording may still be incomplete; a sealed night must have enough provenance to detect later edits.
public enum NightManifestValidator {
    public static func validate(_ manifest: NightRecordManifest) throws {
        guard isSafeIdentifier(manifest.nightID) else { throw NightLabValidationError.invalidNightID }
        guard manifest.windowEndUnix > manifest.windowStartUnix else {
            throw NightLabValidationError.invalidWindow
        }

        var ids = Set<String>()
        for asset in manifest.rawAssets {
            guard isSafeIdentifier(asset.id) else {
                throw NightLabValidationError.unsafeRawPath(asset.relativePath)
            }
            guard ids.insert(asset.id).inserted else {
                throw NightLabValidationError.duplicateAssetID(asset.id)
            }
            guard isSafeRawPath(asset.relativePath) else {
                throw NightLabValidationError.unsafeRawPath(asset.relativePath)
            }
            guard asset.endUnix >= asset.startUnix else {
                throw NightLabValidationError.invalidAssetWindow(asset.id)
            }
            guard asset.sampleCount >= 0 else {
                throw NightLabValidationError.invalidSampleCount(asset.id)
            }
            if let cadence = asset.expectedCadenceHz, (!cadence.isFinite || cadence <= 0) {
                throw NightLabValidationError.invalidCadence(asset.id)
            }
            if manifest.state == .sealed {
                guard let algorithm = asset.digestAlgorithm?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !algorithm.isEmpty,
                      let digest = asset.digest?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !digest.isEmpty else {
                    throw NightLabValidationError.missingIntegrityDigest(asset.id)
                }
            }
        }
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    private static func isSafeRawPath(_ path: String) -> Bool {
        guard path.hasPrefix("raw/"), !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains(where: { $0 == ".." || $0.isEmpty })
    }
}

/// Signal availability calculated only from raw timestamps. When a signal is event-driven or its expected
/// cadence is unknown, `coverageFraction`, `expectedSamples`, and `gapCount` stay nil rather than inventing
/// a reassuring percentage.
public struct NightSignalCoverageReport: Codable, Sendable, Equatable {
    public let kind: NightSignalKind
    public let sampleCount: Int
    public let windowSeconds: Int
    public let expectedSamples: Int?
    public let coverageFraction: Double?
    public let largestGapSeconds: Int?
    public let gapCount: Int?

    public init(kind: NightSignalKind,
                sampleCount: Int,
                windowSeconds: Int,
                expectedSamples: Int?,
                coverageFraction: Double?,
                largestGapSeconds: Int?,
                gapCount: Int?) {
        self.kind = kind
        self.sampleCount = sampleCount
        self.windowSeconds = windowSeconds
        self.expectedSamples = expectedSamples
        self.coverageFraction = coverageFraction
        self.largestGapSeconds = largestGapSeconds
        self.gapCount = gapCount
    }
}

public enum NightSignalCoverage {
    /// Analyze timestamps inside `[windowStartUnix, windowEndUnix)`.
    ///
    /// `sampleCount` is the TRUE number of rows in the window. Temporal coverage and gaps use unique
    /// timestamp seconds, because streams such as R-R can legitimately contain several beats with the same
    /// `ts`. Conflating those two meanings used to under-report R-R row counts, while counting all repeated
    /// timestamps toward a 1 Hz coverage percentage would over-report coverage. Keep the two facts separate.
    public static func analyze(kind: NightSignalKind,
                               timestamps: [Int],
                               windowStartUnix: Int,
                               windowEndUnix: Int,
                               expectedCadenceHz: Double? = nil) -> NightSignalCoverageReport {
        let duration = max(0, windowEndUnix - windowStartUnix)
        let filtered = timestamps.filter {
            $0 >= windowStartUnix && $0 < windowEndUnix
        }
        let sampleCount = filtered.count
        let ordered = Array(Set(filtered)).sorted()

        let largestGap: Int? = {
            guard duration > 0 else { return nil }
            guard let first = ordered.first, let last = ordered.last else { return duration }
            var largest = max(0, first - windowStartUnix)
            if ordered.count > 1 {
                for i in 1..<ordered.count {
                    largest = max(largest, ordered[i] - ordered[i - 1])
                }
            }
            largest = max(largest, windowEndUnix - last)
            return largest
        }()

        guard let cadence = expectedCadenceHz,
              cadence.isFinite,
              cadence > 0,
              duration > 0 else {
            return NightSignalCoverageReport(kind: kind,
                                             sampleCount: sampleCount,
                                             windowSeconds: duration,
                                             expectedSamples: nil,
                                             coverageFraction: nil,
                                             largestGapSeconds: largestGap,
                                             gapCount: nil)
        }

        let expected = max(1, Int((Double(duration) * cadence).rounded()))
        let coverage = min(1.0, Double(ordered.count) / Double(expected))
        let expectedInterval = 1.0 / cadence
        let gapThreshold = expectedInterval * 1.5

        var gaps = 0
        if let first = ordered.first {
            if Double(first - windowStartUnix) > gapThreshold { gaps += 1 }
            if ordered.count > 1 {
                for i in 1..<ordered.count where Double(ordered[i] - ordered[i - 1]) > gapThreshold {
                    gaps += 1
                }
            }
            if let last = ordered.last, Double(windowEndUnix - last) > gapThreshold { gaps += 1 }
        } else if duration > 0 {
            gaps = 1
        }

        return NightSignalCoverageReport(kind: kind,
                                         sampleCount: sampleCount,
                                         windowSeconds: duration,
                                         expectedSamples: expected,
                                         coverageFraction: coverage,
                                         largestGapSeconds: largestGap,
                                         gapCount: gaps)
    }
}

public struct NightAlgorithmIdentity: Codable, Sendable, Equatable {
    public let id: String
    public let version: String
    public let build: String?

    public init(id: String, version: String, build: String? = nil) {
        self.id = id
        self.version = version
        self.build = build
    }
}

/// The only input contract a Night Lab replay algorithm receives. There is deliberately no reference-label
/// field here. Evaluation code must join a completed run with `NightReferenceLabels` afterwards.
public struct NightReplayInput: Codable, Sendable, Equatable {
    public let manifest: NightRecordManifest
    public let coverage: [NightSignalCoverageReport]

    public init(manifest: NightRecordManifest, coverage: [NightSignalCoverageReport]) {
        self.manifest = manifest
        self.coverage = coverage
    }
}

/// A replay algorithm returns a JSON payload owned by that algorithm. Phase 1 does not dictate the eventual
/// sleep-stage schema; it only guarantees version/provenance and keeps the input side blind.
public protocol NightReplayAlgorithm: Sendable {
    var identity: NightAlgorithmIdentity { get }
    func run(input: NightReplayInput) throws -> String
}

public struct NightAlgorithmRun: Codable, Sendable, Equatable {
    public let nightID: String
    public let algorithm: NightAlgorithmIdentity
    public let inputSchemaVersion: Int
    public let runAtUnix: Int
    public let outputJSON: String

    public init(nightID: String,
                algorithm: NightAlgorithmIdentity,
                inputSchemaVersion: Int,
                runAtUnix: Int,
                outputJSON: String) {
        self.nightID = nightID
        self.algorithm = algorithm
        self.inputSchemaVersion = inputSchemaVersion
        self.runAtUnix = runAtUnix
        self.outputJSON = outputJSON
    }
}

public enum NightReplayRunner {
    /// `runAtUnix` is injected rather than read from the live clock, keeping replay tests deterministic.
    public static func run<A: NightReplayAlgorithm>(algorithm: A,
                                                    input: NightReplayInput,
                                                    runAtUnix: Int) throws -> NightAlgorithmRun {
        try NightManifestValidator.validate(input.manifest)
        let payload = try algorithm.run(input: input)
        return NightAlgorithmRun(nightID: input.manifest.nightID,
                                 algorithm: algorithm.identity,
                                 inputSchemaVersion: input.manifest.schemaVersion,
                                 runAtUnix: runAtUnix,
                                 outputJSON: payload)
    }
}

/// Reference labels are intentionally a separate object from NightReplayInput. A provider can be WHOOP,
/// PSG, a manually annotated timeline, or another comparator. These are evaluation evidence, never features.
public struct NightReferenceEpoch: Codable, Sendable, Equatable {
    public let startUnix: Int
    public let endUnix: Int
    public let label: String

    public init(startUnix: Int, endUnix: Int, label: String) {
        self.startUnix = startUnix
        self.endUnix = endUnix
        self.label = label
    }
}

public struct NightReferenceLabels: Codable, Sendable, Equatable {
    public let nightID: String
    public let provider: String
    public let importedAtUnix: Int
    public let epochs: [NightReferenceEpoch]
    public let summary: [String: Double]

    public init(nightID: String,
                provider: String,
                importedAtUnix: Int,
                epochs: [NightReferenceEpoch] = [],
                summary: [String: Double] = [:]) {
        self.nightID = nightID
        self.provider = provider
        self.importedAtUnix = importedAtUnix
        self.epochs = epochs
        self.summary = summary
    }
}

/// Canonical archive paths. Keeping raw, derived, and reference namespaces separate makes accidental label
/// leakage much harder and makes backup/export tooling predictable.
public enum NightLabArchiveLayout {
    public static func nightDirectory(_ nightID: String) -> String { "NightLab/\(nightID)" }
    public static func manifestPath(_ nightID: String) -> String { "\(nightDirectory(nightID))/manifest.json" }
    public static func rawDirectory(_ nightID: String) -> String { "\(nightDirectory(nightID))/raw" }
    public static func derivedDirectory(_ nightID: String) -> String { "\(nightDirectory(nightID))/derived" }
    public static func referencesDirectory(_ nightID: String) -> String { "\(nightDirectory(nightID))/references" }
}

/// Stable JSON encoding for manifests, replay results, and references. Sorted keys make archive diffs useful
/// and prevent meaningless byte changes when the same value is encoded twice.
public enum NightLabJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
