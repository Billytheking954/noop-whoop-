import Foundation

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
    public let baseline: SleepStagerV2BaselineArtifact?
    public let baselineSHA256: String?
    public let baselineError: String?
    public let receipts: [NightLabInspectionReceipt]
    public let receiptsError: String?

    /// No runner, reference loader, or live store is used here. Protocol rows remain in this
    /// nonisolated async operation; only the Sendable inspection projection crosses to the UI.
    public static func load(archive: NightLabFileStore, nightID: String) async throws -> Self {
        let manifest = try await archive.inspectionManifest(nightID: nightID)
        guard manifest.state == .sealed else {
            return Self(manifest: manifest, coverage: [], baseline: nil, baselineSHA256: nil,
                        baselineError: nil, receipts: [], receiptsError: nil)
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
        return Self(manifest: manifest, coverage: coverage, baseline: baseline, baselineSHA256: sha,
                    baselineError: baselineError, receipts: receipts, receiptsError: receiptsError)
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
