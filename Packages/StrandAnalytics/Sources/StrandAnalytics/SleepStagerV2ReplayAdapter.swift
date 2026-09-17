import Foundation
import Dispatch
import WhoopProtocol

/// Identifies the exact NOOP checkout and exact SleepStagerV2 source used to produce a baseline.
/// Values are supplied by the caller/build layer; Night Lab never invents repository provenance.
public struct SleepStagerV2ImplementationIdentity: Codable, Sendable, Equatable {
    public let noopCommitSHA: String
    public let stagerSourceBlobSHA: String

    public init(noopCommitSHA: String, stagerSourceBlobSHA: String) {
        self.noopCommitSHA = noopCommitSHA
        self.stagerSourceBlobSHA = stagerSourceBlobSHA
    }
}

public enum SleepStagerV2BaselineStage: String, Codable, Sendable, Equatable, CaseIterable {
    case wake
    case light
    case deep
    case rem
}

/// One Unix-anchored evaluation epoch. The final epoch may be clipped by the Night Lab half-open end.
public struct SleepStagerV2BaselineEpoch: Codable, Sendable, Equatable {
    public let startUnix: Int
    public let endUnix: Int
    public let stage: SleepStagerV2BaselineStage

    public init(startUnix: Int, endUnix: Int, stage: SleepStagerV2BaselineStage) {
        self.startUnix = startUnix
        self.endUnix = endUnix
        self.stage = stage
    }
}

/// A non-epoch boundary fragment before the first absolute Unix multiple-of-30 boundary.
/// Kept separate so Night Lab never calls a 1...29 second fragment a 30-second epoch.
public struct SleepStagerV2BaselineBoundary: Codable, Sendable, Equatable {
    public let startUnix: Int
    public let endUnix: Int
    public let stage: SleepStagerV2BaselineStage

    public init(startUnix: Int, endUnix: Int, stage: SleepStagerV2BaselineStage) {
        self.startUnix = startUnix
        self.endUnix = endUnix
        self.stage = stage
    }
}

/// Immutable identity of one archived input asset. `usedByStager` distinguishes provenance that belongs to
/// the sealed archive (for example wrist/contact state) from the four streams accepted by production V2.
public struct SleepStagerV2InputAssetIdentity: Codable, Sendable, Equatable {
    public let assetID: String
    public let kind: NightSignalKind
    public let sha256: String
    public let sampleCount: Int
    public let usedByStager: Bool

    public init(assetID: String,
                kind: NightSignalKind,
                sha256: String,
                sampleCount: Int,
                usedByStager: Bool) {
        self.assetID = assetID
        self.kind = kind
        self.sha256 = sha256
        self.sampleCount = sampleCount
        self.usedByStager = usedByStager
    }
}

/// Deterministic, label-blind production baseline for one sealed Night Lab session window.
///
/// Deliberately absent: execution time, execution duration, WHOOP/PSG reference stages, UI state, and any
/// mutable app data. Those omissions are what make identical replay inputs byte-reproducible.
public struct SleepStagerV2BaselineArtifact: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let nightID: String
    public let algorithm: NightAlgorithmIdentity
    public let implementation: SleepStagerV2ImplementationIdentity

    public let manifestSchemaVersion: Int
    public let sourceStreamFingerprint: String?
    public let sourceDeviceID: String?
    public let sourceDeviceModel: String?
    public let sourceFirmware: String?
    public let sourceStoreSchemaVersion: Int?
    public let sourceNOOPVersion: String?
    public let timezoneOffsetSeconds: Int
    public let inputAssets: [SleepStagerV2InputAssetIdentity]

    public let windowStartUnix: Int
    public let windowEndUnix: Int
    public let epochSeconds: Int
    public let epochAnchorUnix: Int

    /// Exact public production return value, retained so a canonicalisation bug can be separated from a
    /// staging bug without rerunning the model.
    public let productionSegments: [StageSegment]
    public let leadingBoundary: SleepStagerV2BaselineBoundary?
    public let epochs: [SleepStagerV2BaselineEpoch]

    public init(schemaVersion: Int = SleepStagerV2BaselineArtifact.currentSchemaVersion,
                nightID: String,
                algorithm: NightAlgorithmIdentity,
                implementation: SleepStagerV2ImplementationIdentity,
                manifestSchemaVersion: Int,
                sourceStreamFingerprint: String?,
                sourceDeviceID: String?,
                sourceDeviceModel: String?,
                sourceFirmware: String?,
                sourceStoreSchemaVersion: Int?,
                sourceNOOPVersion: String?,
                timezoneOffsetSeconds: Int,
                inputAssets: [SleepStagerV2InputAssetIdentity],
                windowStartUnix: Int,
                windowEndUnix: Int,
                epochSeconds: Int = 30,
                epochAnchorUnix: Int = 0,
                productionSegments: [StageSegment],
                leadingBoundary: SleepStagerV2BaselineBoundary?,
                epochs: [SleepStagerV2BaselineEpoch]) {
        self.schemaVersion = schemaVersion
        self.nightID = nightID
        self.algorithm = algorithm
        self.implementation = implementation
        self.manifestSchemaVersion = manifestSchemaVersion
        self.sourceStreamFingerprint = sourceStreamFingerprint
        self.sourceDeviceID = sourceDeviceID
        self.sourceDeviceModel = sourceDeviceModel
        self.sourceFirmware = sourceFirmware
        self.sourceStoreSchemaVersion = sourceStoreSchemaVersion
        self.sourceNOOPVersion = sourceNOOPVersion
        self.timezoneOffsetSeconds = timezoneOffsetSeconds
        self.inputAssets = inputAssets
        self.windowStartUnix = windowStartUnix
        self.windowEndUnix = windowEndUnix
        self.epochSeconds = epochSeconds
        self.epochAnchorUnix = epochAnchorUnix
        self.productionSegments = productionSegments
        self.leadingBoundary = leadingBoundary
        self.epochs = epochs
    }
}

public struct SleepStagerV2ExecutionReceipt: Codable, Sendable, Equatable {
    public let nightID: String
    public let executedAtUnix: Int
    public let durationNanoseconds: UInt64
    public let baselineSHA256: String
    public let noopCommitSHA: String

    public init(nightID: String,
                executedAtUnix: Int,
                durationNanoseconds: UInt64,
                baselineSHA256: String,
                noopCommitSHA: String) {
        self.nightID = nightID
        self.executedAtUnix = executedAtUnix
        self.durationNanoseconds = durationNanoseconds
        self.baselineSHA256 = baselineSHA256
        self.noopCommitSHA = noopCommitSHA
    }
}

public struct SleepStagerV2BaselineExecution: Sendable, Equatable {
    public let artifact: SleepStagerV2BaselineArtifact
    public let baselineFile: NightDerivedArtifactIdentity
    public let receipt: SleepStagerV2ExecutionReceipt
    public let receiptFile: NightDerivedArtifactIdentity

    public init(artifact: SleepStagerV2BaselineArtifact,
                baselineFile: NightDerivedArtifactIdentity,
                receipt: SleepStagerV2ExecutionReceipt,
                receiptFile: NightDerivedArtifactIdentity) {
        self.artifact = artifact
        self.baselineFile = baselineFile
        self.receipt = receipt
        self.receiptFile = receiptFile
    }
}

public enum SleepStagerV2ReplayError: Error, Sendable, Equatable {
    case invalidImplementationIdentity
    case invalidWindow(start: Int, end: Int)
    case emptyProductionSegments
    case unknownProductionStage(String)
    case invalidProductionSegment(start: Int, end: Int)
    case productionCoverageStart(expected: Int, actual: Int)
    case productionCoverageEnd(expected: Int, actual: Int)
    case productionGapOrOverlap(expectedStart: Int, actualStart: Int)
    case unalignedInteriorProductionBoundary(Int)
    case noProductionStageForTimestamp(Int)
    case missingAssetDigest(String)
    case unsupportedAssetDigest(assetID: String, algorithm: String?)
}

/// Thin, deliberately boring adapter around the unchanged production `SleepStagerV2.stageSession` entry.
/// It has no filesystem/reference access and therefore cannot read WHOOP/PSG answers.
public struct SleepStagerV2ReplayAdapter: Sendable {
    public static let algorithmID = "sleep-stager-v2"
    public static let algorithmVersion = "2"
    public static let epochSeconds = 30
    public static let epochAnchorUnix = 0

    public let implementation: SleepStagerV2ImplementationIdentity

    public init(implementation: SleepStagerV2ImplementationIdentity) {
        self.implementation = implementation
    }

    public func replay(streams: NightLabArchivedStreams) throws -> SleepStagerV2BaselineArtifact {
        guard !implementation.noopCommitSHA.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !implementation.stagerSourceBlobSHA.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SleepStagerV2ReplayError.invalidImplementationIdentity
        }

        let manifest = streams.manifest
        guard manifest.windowEndUnix > manifest.windowStartUnix else {
            throw SleepStagerV2ReplayError.invalidWindow(start: manifest.windowStartUnix,
                                                         end: manifest.windowEndUnix)
        }

        // BASELINE INTEGRITY: this is intentionally the exact current production call. Do not add extra
        // smoothing, contact gates, reference labels, detection, or Night-Lab-only fallbacks here.
        let segments = SleepStagerV2.stageSession(start: manifest.windowStartUnix,
                                                  end: manifest.windowEndUnix,
                                                  grav: streams.gravity,
                                                  hr: streams.hr,
                                                  rr: streams.rr,
                                                  resp: streams.respiration)

        let canonical = try Self.canonicalize(productionSegments: segments,
                                              windowStartUnix: manifest.windowStartUnix,
                                              windowEndUnix: manifest.windowEndUnix)
        let inputAssets = try Self.assetIdentities(from: manifest)

        return SleepStagerV2BaselineArtifact(
            nightID: manifest.nightID,
            algorithm: NightAlgorithmIdentity(id: Self.algorithmID,
                                              version: Self.algorithmVersion,
                                              build: implementation.stagerSourceBlobSHA),
            implementation: implementation,
            manifestSchemaVersion: manifest.schemaVersion,
            sourceStreamFingerprint: manifest.sourceStreamFingerprint,
            sourceDeviceID: manifest.sourceDeviceID,
            sourceDeviceModel: manifest.sourceDeviceModel,
            sourceFirmware: manifest.sourceFirmware,
            sourceStoreSchemaVersion: manifest.sourceStoreSchemaVersion,
            sourceNOOPVersion: manifest.noopVersion,
            timezoneOffsetSeconds: manifest.timezoneOffsetSeconds,
            inputAssets: inputAssets,
            windowStartUnix: manifest.windowStartUnix,
            windowEndUnix: manifest.windowEndUnix,
            epochSeconds: Self.epochSeconds,
            epochAnchorUnix: Self.epochAnchorUnix,
            productionSegments: segments,
            leadingBoundary: canonical.leadingBoundary,
            epochs: canonical.epochs
        )
    }

    /// Expand the public production segments onto V2's absolute Unix 30-second evaluation grid without
    /// reconstructing any private features/classifier logic.
    static func canonicalize(productionSegments segments: [StageSegment],
                             windowStartUnix start: Int,
                             windowEndUnix end: Int)
        throws -> (leadingBoundary: SleepStagerV2BaselineBoundary?, epochs: [SleepStagerV2BaselineEpoch]) {
        guard end > start else { throw SleepStagerV2ReplayError.invalidWindow(start: start, end: end) }
        guard !segments.isEmpty else { throw SleepStagerV2ReplayError.emptyProductionSegments }

        // Validate labels and the exact public tiling contract before deriving anything from it.
        for segment in segments {
            _ = try stage(segment.stage)
            guard segment.end > segment.start else {
                throw SleepStagerV2ReplayError.invalidProductionSegment(start: segment.start,
                                                                        end: segment.end)
            }
            guard segment.start >= start, segment.end <= end else {
                if segment.start < start {
                    throw SleepStagerV2ReplayError.productionCoverageStart(expected: start,
                                                                           actual: segment.start)
                }
                throw SleepStagerV2ReplayError.productionCoverageEnd(expected: end,
                                                                     actual: segment.end)
            }
        }
        guard segments[0].start == start else {
            throw SleepStagerV2ReplayError.productionCoverageStart(expected: start,
                                                                   actual: segments[0].start)
        }
        guard segments[segments.count - 1].end == end else {
            throw SleepStagerV2ReplayError.productionCoverageEnd(expected: end,
                                                                 actual: segments[segments.count - 1].end)
        }
        if segments.count > 1 {
            for i in 1..<segments.count {
                guard segments[i].start == segments[i - 1].end else {
                    throw SleepStagerV2ReplayError.productionGapOrOverlap(
                        expectedStart: segments[i - 1].end,
                        actualStart: segments[i].start
                    )
                }
                // V2's real interior stage transitions originate from aligned feature epochs. If that
                // contract changes, fail rather than silently manufacturing a 30-second evaluation label.
                guard isEpochAligned(segments[i].start) else {
                    throw SleepStagerV2ReplayError.unalignedInteriorProductionBoundary(segments[i].start)
                }
            }
        }

        let firstAligned = firstEpochBoundary(atOrAfter: start)
        var leading: SleepStagerV2BaselineBoundary?
        if firstAligned > start {
            let boundaryEnd = min(firstAligned, end)
            let label = try stageAt(timestamp: start, segments: segments)
            leading = SleepStagerV2BaselineBoundary(startUnix: start,
                                                    endUnix: boundaryEnd,
                                                    stage: label)
        }

        var epochs: [SleepStagerV2BaselineEpoch] = []
        var epochStart = firstAligned
        while epochStart < end {
            let epochEnd = min(epochStart + Self.epochSeconds, end)
            let label = try stageAt(timestamp: epochStart, segments: segments)
            epochs.append(SleepStagerV2BaselineEpoch(startUnix: epochStart,
                                                     endUnix: epochEnd,
                                                     stage: label))
            epochStart += Self.epochSeconds
        }
        return (leading, epochs)
    }

    private static func assetIdentities(from manifest: NightRecordManifest) throws -> [SleepStagerV2InputAssetIdentity] {
        let modelInputIDs: Set<String> = ["hr", "rr", "gravity", "respiration"]
        return try manifest.rawAssets.map { asset in
            guard asset.digestAlgorithm?.lowercased() == "sha256" else {
                throw SleepStagerV2ReplayError.unsupportedAssetDigest(assetID: asset.id,
                                                                      algorithm: asset.digestAlgorithm)
            }
            guard let digest = asset.digest,
                  !digest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SleepStagerV2ReplayError.missingAssetDigest(asset.id)
            }
            return SleepStagerV2InputAssetIdentity(assetID: asset.id,
                                                   kind: asset.kind,
                                                   sha256: digest,
                                                   sampleCount: asset.sampleCount,
                                                   usedByStager: modelInputIDs.contains(asset.id))
        }.sorted { lhs, rhs in
            if lhs.assetID != rhs.assetID { return lhs.assetID < rhs.assetID }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    private static func stage(_ raw: String) throws -> SleepStagerV2BaselineStage {
        guard let value = SleepStagerV2BaselineStage(rawValue: raw) else {
            throw SleepStagerV2ReplayError.unknownProductionStage(raw)
        }
        return value
    }

    private static func stageAt(timestamp: Int,
                                segments: [StageSegment]) throws -> SleepStagerV2BaselineStage {
        guard let segment = segments.first(where: { $0.start <= timestamp && timestamp < $0.end }) else {
            throw SleepStagerV2ReplayError.noProductionStageForTimestamp(timestamp)
        }
        return try stage(segment.stage)
    }

    private static func isEpochAligned(_ timestamp: Int) -> Bool {
        normalizedRemainder(timestamp - Self.epochAnchorUnix, modulus: Self.epochSeconds) == 0
    }

    private static func firstEpochBoundary(atOrAfter timestamp: Int) -> Int {
        let relative = timestamp - Self.epochAnchorUnix
        let remainder = normalizedRemainder(relative, modulus: Self.epochSeconds)
        if remainder == 0 { return timestamp }
        return timestamp + (Self.epochSeconds - remainder)
    }

    private static func normalizedRemainder(_ value: Int, modulus: Int) -> Int {
        let raw = value % modulus
        return raw >= 0 ? raw : raw + modulus
    }
}

/// Executes the label-blind baseline from sealed evidence, writes a deterministic canonical artifact, and
/// records non-deterministic timing in a separate append-only execution receipt.
public enum NightLabSleepStagerV2BaselineRunner {
    public static let baselineFileName = "sleep_stager_v2_baseline.json"

    public static func run(archive: NightLabFileStore,
                           nightID: String,
                           implementation: SleepStagerV2ImplementationIdentity) async throws
        -> SleepStagerV2BaselineExecution {
        // Loader first: the monotonic duration below is staging/canonicalisation time, not disk verification.
        // It also guarantees raw SHA, decoded-row-count, and half-open-window validation before V2 sees rows.
        let streams = try await NightLabArchiveLoader.load(archive: archive, nightID: nightID)

        let executedAtUnix = Int(Date().timeIntervalSince1970)
        let started = DispatchTime.now().uptimeNanoseconds
        let artifact = try SleepStagerV2ReplayAdapter(implementation: implementation).replay(streams: streams)
        let finished = DispatchTime.now().uptimeNanoseconds
        let duration = finished >= started ? finished - started : 0

        let baselineData = try NightLabJSON.encode(artifact)
        let baselineFile = try await archive.saveDeterministicDerivedArtifact(
            nightID: nightID,
            fileName: baselineFileName,
            data: baselineData
        )

        let receipt = SleepStagerV2ExecutionReceipt(nightID: nightID,
                                                    executedAtUnix: executedAtUnix,
                                                    durationNanoseconds: duration,
                                                    baselineSHA256: baselineFile.sha256,
                                                    noopCommitSHA: implementation.noopCommitSHA)
        let receiptData = try NightLabJSON.encode(receipt)
        // Uptime makes same-second executions distinct without contaminating the deterministic baseline.
        let receiptName = "sleep_stager_v2_\(executedAtUnix)_\(started).json"
        let receiptFile = try await archive.saveExecutionDerivedArtifact(nightID: nightID,
                                                                         fileName: receiptName,
                                                                         data: receiptData)

        return SleepStagerV2BaselineExecution(artifact: artifact,
                                              baselineFile: baselineFile,
                                              receipt: receipt,
                                              receiptFile: receiptFile)
    }
}
