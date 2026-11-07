import Foundation
import WhoopProtocol

/// Typed view of the immutable stream assets Night Lab captured from NOOP's durable store.
///
/// This is the handoff object for replay algorithms. Callers do not know file names, JSON layout, or
/// archive directories; they receive the same protocol-level row types the production stager consumes.
/// Reference labels are deliberately absent from this type.
///
/// Intentionally not declared `Sendable`: the existing WhoopProtocol row structs are not Sendable contracts.
/// Night Lab does not strengthen another package's concurrency promises by wishful thinking.
public struct NightLabArchivedStreams: Equatable {
    public let manifest: NightRecordManifest
    public let hr: [HRSample]
    public let rr: [RRInterval]
    public let gravity: [GravitySample]
    public let respiration: [RespSample]
    public let wristStatus: [NightLabWristStatusRow]

    public init(manifest: NightRecordManifest,
                hr: [HRSample],
                rr: [RRInterval],
                gravity: [GravitySample],
                respiration: [RespSample],
                wristStatus: [NightLabWristStatusRow]) {
        self.manifest = manifest
        self.hr = hr
        self.rr = rr
        self.gravity = gravity
        self.respiration = respiration
        self.wristStatus = wristStatus
    }
}

public enum NightLabArchiveLoaderError: Error, Sendable, Equatable {
    case nightNotSealed(String)
    case unexpectedAssetKind(assetID: String, expected: NightSignalKind, actual: NightSignalKind)
    case decodedRowCountMismatch(assetID: String, manifestCount: Int, decodedCount: Int)
    case rowOutsideNight(assetID: String, timestamp: Int)
}

/// Decodes a sealed Night Lab archive back into protocol-level streams for deterministic replay.
///
/// Every byte read goes through `NightLabFileStore.rawData`, which rechecks the asset's SHA-256 digest.
/// The loader then validates semantic invariants the byte hash cannot prove: the asset kind matches its
/// contract, decoded row count matches the manifest, and no decoded row escaped the night's half-open window.
public enum NightLabArchiveLoader {

    public static func load(archive: NightLabFileStore,
                            nightID: String) async throws -> NightLabArchivedStreams {
        let manifest = try await archive.loadManifest(nightID: nightID)
        guard manifest.state == .sealed else {
            throw NightLabArchiveLoaderError.nightNotSealed(nightID)
        }

        let hr: [HRSample] = try await decode(assetID: "hr",
                                              kind: .heartRate,
                                              manifest: manifest,
                                              archive: archive,
                                              timestamp: { $0.ts })
        let rr: [RRInterval] = try await decode(assetID: "rr",
                                                kind: .rrIntervals,
                                                manifest: manifest,
                                                archive: archive,
                                                timestamp: { $0.ts })
        let gravity: [GravitySample] = try await decode(assetID: "gravity",
                                                        kind: .accelerometer,
                                                        manifest: manifest,
                                                        archive: archive,
                                                        timestamp: { $0.ts })
        let respiration: [RespSample] = try await decode(assetID: "respiration",
                                                         kind: .respiration,
                                                         manifest: manifest,
                                                         archive: archive,
                                                         timestamp: { $0.ts })
        let wrist: [NightLabWristStatusRow] = try await decode(assetID: "wrist-status",
                                                               kind: .wristStatus,
                                                               manifest: manifest,
                                                               archive: archive,
                                                               timestamp: { $0.ts })

        return NightLabArchivedStreams(manifest: manifest,
                                       hr: hr,
                                       rr: rr,
                                       gravity: gravity,
                                       respiration: respiration,
                                       wristStatus: wrist)
    }

    /// Recompute the coverage report from the ARCHIVED rows rather than trusting the capture-time copy.
    /// This is the report a replay should use: it describes exactly the bytes whose hashes are in the sealed
    /// manifest. Sparse contact state remains event-like and therefore intentionally has no fake percentage.
    public static func coverage(for streams: NightLabArchivedStreams) -> [NightSignalCoverageReport] {
        let start = streams.manifest.windowStartUnix
        let end = streams.manifest.windowEndUnix
        return [
            NightSignalCoverage.analyze(kind: .heartRate,
                                        timestamps: streams.hr.map(\.ts),
                                        windowStartUnix: start,
                                        windowEndUnix: end,
                                        expectedCadenceHz: 1.0),
            NightSignalCoverage.analyze(kind: .rrIntervals,
                                        timestamps: streams.rr.map(\.ts),
                                        windowStartUnix: start,
                                        windowEndUnix: end,
                                        expectedCadenceHz: nil),
            NightSignalCoverage.analyze(kind: .accelerometer,
                                        timestamps: streams.gravity.map(\.ts),
                                        windowStartUnix: start,
                                        windowEndUnix: end,
                                        expectedCadenceHz: 1.0),
            NightSignalCoverage.analyze(kind: .respiration,
                                        timestamps: streams.respiration.map(\.ts),
                                        windowStartUnix: start,
                                        windowEndUnix: end,
                                        expectedCadenceHz: 1.0),
            NightSignalCoverageReport(kind: .wristStatus,
                                      sampleCount: streams.wristStatus.count,
                                      windowSeconds: max(0, end - start),
                                      expectedSamples: nil,
                                      coverageFraction: nil,
                                      largestGapSeconds: nil,
                                      gapCount: nil),
        ]
    }

    /// Build the label-blind replay metadata from the same sealed rows. Algorithms receive this plus the
    /// typed streams above; external WHOOP/PSG references live in a different namespace and never enter here.
    public static func replayInput(for streams: NightLabArchivedStreams) -> NightReplayInput {
        NightReplayInput(manifest: streams.manifest, coverage: coverage(for: streams))
    }

    private static func decode<T: Decodable>(assetID: String,
                                             kind expectedKind: NightSignalKind,
                                             manifest: NightRecordManifest,
                                             archive: NightLabFileStore,
                                             timestamp: (T) -> Int) async throws -> [T] {
        // Missing optional stream = honest empty array. The capture bridge writes no zero-row placeholder,
        // so absence means "NOOP had no rows for this signal in this night", not a decode failure.
        guard let asset = manifest.rawAssets.first(where: { $0.id == assetID }) else { return [] }
        guard asset.kind == expectedKind else {
            throw NightLabArchiveLoaderError.unexpectedAssetKind(assetID: assetID,
                                                                 expected: expectedKind,
                                                                 actual: asset.kind)
        }

        let data = try await archive.rawData(nightID: manifest.nightID, assetID: assetID)
        let rows = try NightLabJSON.decode([T].self, from: data)
        guard rows.count == asset.sampleCount else {
            throw NightLabArchiveLoaderError.decodedRowCountMismatch(assetID: assetID,
                                                                      manifestCount: asset.sampleCount,
                                                                      decodedCount: rows.count)
        }
        for row in rows {
            let ts = timestamp(row)
            guard ts >= manifest.windowStartUnix, ts < manifest.windowEndUnix else {
                throw NightLabArchiveLoaderError.rowOutsideNight(assetID: assetID, timestamp: ts)
            }
        }
        return rows
    }
}
