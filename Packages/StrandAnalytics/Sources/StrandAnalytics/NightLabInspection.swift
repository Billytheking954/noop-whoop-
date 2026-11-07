import Foundation

/// A factual availability verdict for one archived signal. These labels describe the captured rows only;
/// they do not estimate physiological or sleep-staging accuracy.
public enum NightSignalAvailability: String, Codable, Sendable, Equatable {
    case complete
    case partial
    case unavailable
    case completenessUnknown
}

public struct NightSignalQualitySummary: Codable, Sendable, Equatable {
    public let kind: NightSignalKind
    public let availability: NightSignalAvailability
    public let sampleCount: Int
    public let coverageFraction: Double?
    public let gapCount: Int?
    public let largestGapSeconds: Int?
}

/// How confidently Night Lab can describe the evidence behind a saved staging result. This is deliberately
/// not an accuracy score: Night Lab has no ground truth here, and an intact archive can still contain gaps.
public enum NightSavedResultEvidence: String, Codable, Sendable, Equatable {
    case noSavedResult
    case complete
    case limited
    case completenessUnknown
}

public struct NightDataQualitySummary: Codable, Sendable, Equatable {
    public let archiveIntegrityVerified: Bool
    public let signals: [NightSignalQualitySummary]
    public let savedResultEvidence: NightSavedResultEvidence
    public let limitingSignals: [NightSignalKind]
    public let unknownCompletenessSignals: [NightSignalKind]

    /// Summarize verified archive coverage without manufacturing an accuracy percentage. A sampled signal
    /// is complete only when every expected timestamp is present and no gap was detected. Event-driven and
    /// unknown-cadence streams remain `completenessUnknown` even when rows are present.
    public init(coverage: [NightSignalCoverageReport],
                archiveIntegrityVerified: Bool,
                hasSavedSleepResult: Bool) {
        let signals = coverage.map { report in
            let availability: NightSignalAvailability
            if report.sampleCount == 0 {
                availability = .unavailable
            } else if let fraction = report.coverageFraction, let gapCount = report.gapCount {
                availability = fraction == 1.0 && gapCount == 0 ? .complete : .partial
            } else {
                availability = .completenessUnknown
            }
            return NightSignalQualitySummary(kind: report.kind,
                                             availability: availability,
                                             sampleCount: report.sampleCount,
                                             coverageFraction: report.coverageFraction,
                                             gapCount: report.gapCount,
                                             largestGapSeconds: report.largestGapSeconds)
        }

        // SleepStagerV2 receives these streams, including honest empty arrays for absent assets.
        let stagingKinds: [NightSignalKind] = [
            .heartRate, .rrIntervals, .accelerometer, .respiration,
        ]
        let stagingSignals = signals.filter { stagingKinds.contains($0.kind) }
        let limiting = stagingSignals
            .filter { $0.availability == .partial || $0.availability == .unavailable }
            .map(\.kind)
        let unknown = stagingSignals
            .filter { $0.availability == .completenessUnknown }
            .map(\.kind)

        let resultEvidence: NightSavedResultEvidence
        if !hasSavedSleepResult {
            resultEvidence = .noSavedResult
        } else if !limiting.isEmpty {
            resultEvidence = .limited
        } else if !unknown.isEmpty || stagingSignals.count < stagingKinds.count {
            resultEvidence = .completenessUnknown
        } else {
            resultEvidence = .complete
        }

        self.archiveIntegrityVerified = archiveIntegrityVerified
        self.signals = signals
        self.savedResultEvidence = resultEvidence
        self.limitingSignals = limiting
        self.unknownCompletenessSignals = unknown
    }
}

public enum NightLabInspectionError: Error, Equatable {
    case unsupportedSchema(Int)
    case manifestIdentityMismatch
    case baselineMismatch
    case unsafePath
}

public struct NightLabInspectionEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let manifest: NightRecordManifest?
    public let error: String?
}

public struct NightLabInspectionReceipt: Sendable, Equatable {
    public let fileName: String
    public let receipt: SleepStagerV2ExecutionReceipt?
    public let error: String?
}

/// A projection of existing evidence, never a replay input or a persisted artifact.
public struct NightLabInspection: Sendable, Equatable {
    public let manifest: NightRecordManifest
    public let coverage: [NightSignalCoverageReport]
    public let dataQuality: NightDataQualitySummary?
    public let baseline: SleepStagerV2BaselineArtifact?
    public let baselineSHA256: String?
    public let baselineError: String?
    public let receipts: [NightLabInspectionReceipt]
    public let receiptsError: String?
    public let spO2Diagnostics: NightLabSpO2Diagnostics?
    public let spO2DiagnosticsError: String?

    /// No runner, reference loader, or live store is used here. Protocol rows remain in this
    /// nonisolated async operation; only the Sendable inspection projection crosses to the UI.
    public static func load(archive: NightLabFileStore, nightID: String) async throws -> Self {
        let manifest = try await archive.inspectionManifest(nightID: nightID)
        guard manifest.state == .sealed else {
            return Self(manifest: manifest, coverage: [], dataQuality: nil,
                        baseline: nil, baselineSHA256: nil,
                        baselineError: nil, receipts: [], receiptsError: nil,
                        spO2Diagnostics: nil, spO2DiagnosticsError: nil)
        }
        // The typed loader validates its known streams. Verify additional declared assets too.
        for asset in manifest.rawAssets {
            _ = try await archive.rawData(nightID: nightID, assetID: asset.id)
        }
        let streams = try await NightLabArchiveLoader.load(archive: archive, nightID: nightID)
        let coverage = NightLabArchiveLoader.coverage(for: streams)
        var baseline: SleepStagerV2BaselineArtifact?
        var sha: String?
        var baselineError: String?
        do {
            if let data = try await archive.inspectionBaselineData(nightID: nightID) {
                let decoded = try NightLabJSON.decode(SleepStagerV2BaselineArtifact.self, from: data)
                try validate(decoded, manifest: manifest)
                baseline = decoded
                sha = NightLabFileStore.sha256Hex(data)
            }
        } catch { baselineError = String(describing: error) }
        var receipts: [NightLabInspectionReceipt] = []
        var receiptsError: String?
        do {
            receipts = try await archive.inspectionReceipts(nightID: nightID).map { entry in
                guard let receipt = entry.receipt else { return entry }
                let matches = receipt.nightID == nightID && receipt.baselineSHA256 == sha
                    && receipt.noopCommitSHA == baseline?.implementation.noopCommitSHA
                return NightLabInspectionReceipt(fileName: entry.fileName, receipt: receipt,
                    error: matches ? nil : "Receipt cannot be matched to the validated saved baseline")
            }
        } catch { receiptsError = String(describing: error) }

        var spO2Diagnostics: NightLabSpO2Diagnostics?
        var spO2DiagnosticsError: String?
        if manifest.rawAssets.contains(where: { $0.id == NightLabSpO2Diagnostics.rawAssetID }) {
            do {
                let data = try await archive.rawData(
                    nightID: nightID,
                    assetID: NightLabSpO2Diagnostics.rawAssetID
                )
                let rows = try NightLabJSON.decode([NightLabSpO2FrameRow].self, from: data)
                spO2Diagnostics = NightLabSpO2Diagnostics.analyze(
                    rows: rows,
                    windowStartUnix: manifest.windowStartUnix,
                    windowEndUnix: manifest.windowEndUnix,
                    baseline: baseline
                )
            } catch {
                spO2DiagnosticsError = String(describing: error)
            }
        }

        let dataQuality = NightDataQualitySummary(coverage: coverage,
                                                  archiveIntegrityVerified: true,
                                                  hasSavedSleepResult: baseline != nil)
        return Self(manifest: manifest, coverage: coverage, dataQuality: dataQuality,
                    baseline: baseline, baselineSHA256: sha,
                    baselineError: baselineError, receipts: receipts, receiptsError: receiptsError,
                    spO2Diagnostics: spO2Diagnostics, spO2DiagnosticsError: spO2DiagnosticsError)
    }

    private static func validate(_ b: SleepStagerV2BaselineArtifact, manifest m: NightRecordManifest) throws {
        guard b.schemaVersion == SleepStagerV2BaselineArtifact.currentSchemaVersion else {
            throw NightLabInspectionError.unsupportedSchema(b.schemaVersion)
        }
        let used: Set<String> = ["hr", "rr", "gravity", "respiration"]
        let assets = m.rawAssets.sorted { $0.id < $1.id }.map {
            SleepStagerV2InputAssetIdentity(assetID: $0.id, kind: $0.kind, sha256: $0.digest ?? "",
                                           sampleCount: $0.sampleCount, usedByStager: used.contains($0.id))
        }
        guard b.nightID == m.nightID, b.windowStartUnix == m.windowStartUnix,
              b.windowEndUnix == m.windowEndUnix, b.manifestSchemaVersion == m.schemaVersion,
              b.sourceStreamFingerprint == m.sourceStreamFingerprint,
              b.sourceDeviceID == m.sourceDeviceID, b.sourceDeviceModel == m.sourceDeviceModel,
              b.sourceFirmware == m.sourceFirmware, b.sourceStoreSchemaVersion == m.sourceStoreSchemaVersion,
              b.sourceNOOPVersion == m.noopVersion, b.timezoneOffsetSeconds == m.timezoneOffsetSeconds,
              b.inputAssets == assets, b.epochSeconds == 30, b.epochAnchorUnix == 0,
              b.algorithm.id == SleepStagerV2ReplayAdapter.algorithmID,
              b.algorithm.version == SleepStagerV2ReplayAdapter.algorithmVersion,
              b.algorithm.build == b.implementation.stagerSourceBlobSHA,
              !b.implementation.noopCommitSHA.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !b.implementation.stagerSourceBlobSHA.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NightLabInspectionError.baselineMismatch
        }
        // Validate SAVED segments; never invoke stageSession or replay to fill/repair data.
        let canonical = try SleepStagerV2ReplayAdapter.canonicalize(productionSegments: b.productionSegments,
            windowStartUnix: m.windowStartUnix, windowEndUnix: m.windowEndUnix)
        guard canonical.leadingBoundary == b.leadingBoundary, canonical.epochs == b.epochs else {
            throw NightLabInspectionError.baselineMismatch
        }
    }
}

public enum NightLabInspectionFormatting {
    public static func interval(start: Int, end: Int) -> String { "[\(start),\(end))" }
    public static func percentage(_ fraction: Double?) -> String {
        guard let fraction else { return "Unavailable" }
        return String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), fraction * 100)
    }
    public static func timestamp(_ unix: Int, offset: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: offset) ?? TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.string(from: Date(timeIntervalSince1970: Double(unix)))
    }
}
