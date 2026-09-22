import Foundation
import WhoopProtocol
import WhoopStore

/// Parameters for snapshotting one already-stored NOOP night into the immutable Night Lab archive.
///
/// The window is HALF-OPEN `[windowStartUnix, windowEndUnix)`, matching Night Lab's archive contract.
/// WhoopStore's public stream readers currently use inclusive upper bounds, so the bridge translates the
/// request to `to = windowEndUnix - 1` instead of allowing the first sample after the night to leak in.
public struct NightLabStoreBridgeRequest: Sendable, Equatable {
    public let nightID: String
    public let deviceID: String
    public let windowStartUnix: Int
    public let windowEndUnix: Int
    public let timezoneOffsetSeconds: Int
    public let sourceDeviceModelOverride: String?
    public let sourceFirmware: String?
    public let noopVersion: String?
    public let unlabelledAliasOfWhoop5: Bool
    public let maxRowsPerStream: Int
    public let maxSnapshotAttempts: Int

    public init(nightID: String,
                deviceID: String,
                windowStartUnix: Int,
                windowEndUnix: Int,
                timezoneOffsetSeconds: Int,
                sourceDeviceModelOverride: String? = nil,
                sourceFirmware: String? = nil,
                noopVersion: String? = nil,
                unlabelledAliasOfWhoop5: Bool = false,
                maxRowsPerStream: Int = 250_000,
                maxSnapshotAttempts: Int = 3) {
        self.nightID = nightID
        self.deviceID = deviceID
        self.windowStartUnix = windowStartUnix
        self.windowEndUnix = windowEndUnix
        self.timezoneOffsetSeconds = timezoneOffsetSeconds
        self.sourceDeviceModelOverride = sourceDeviceModelOverride
        self.sourceFirmware = sourceFirmware
        self.noopVersion = noopVersion
        self.unlabelledAliasOfWhoop5 = unlabelledAliasOfWhoop5
        self.maxRowsPerStream = maxRowsPerStream
        self.maxSnapshotAttempts = maxSnapshotAttempts
    }
}

public enum NightLabStoreBridgeError: Error, Sendable, Equatable {
    case invalidWindow
    case invalidRowLimit
    case invalidSnapshotAttempts
    case rowLimitExceeded(kind: NightSignalKind, limit: Int)
    case sourceChangedDuringSnapshot(attempts: Int)
}

/// The result of a successful store snapshot. `manifest` is already SEALED: all raw JSON assets were
/// written, hashed, re-read, and verified before this value is returned.
public struct NightLabStoreBridgeResult: Sendable, Equatable {
    public let manifest: NightRecordManifest
    public let coverage: [NightSignalCoverageReport]
    public let sourceFingerprint: String

    public init(manifest: NightRecordManifest,
                coverage: [NightSignalCoverageReport],
                sourceFingerprint: String) {
        self.manifest = manifest
        self.coverage = coverage
        self.sourceFingerprint = sourceFingerprint
    }
}

/// Codable archive shape for sparse standard-BLE wrist/contact state changes. The store's
/// `StandardHRContactSample` is intentionally not Codable, so Night Lab gives it an explicit stable shape
/// rather than encoding an implementation detail from WhoopStore.
public struct NightLabWristStatusRow: Codable, Sendable, Equatable {
    public let ts: Int
    public let state: String

    public init(ts: Int, state: String) {
        self.ts = ts
        self.state = state
    }
}

/// Bridge from NOOP's durable decoded database into Night Lab's immutable research archive.
///
/// DESIGN RULE: this type reads through WhoopStore's EXISTING public APIs rather than re-querying SQLite.
/// Those APIs contain source-policy decisions (measured HR over PPG fallback, WHOOP 5 R-R transport policy,
/// timestamp guards, etc.). Reimplementing the SQL here would create two definitions of "the data NOOP
/// actually staged" and they would eventually drift.
public enum NightLabStoreBridge {

    private struct Snapshot {
        let hr: [HRSample]
        let rr: [RRInterval]
        let gravity: [GravitySample]
        let respiration: [RespSample]
        let wristStatus: [StandardHRContactSample]
        let sourceDeviceModel: String?
        let fingerprint: String
    }

    /// Snapshot and seal one Night Lab record.
    ///
    /// A fingerprint is read BEFORE and AFTER the stream reads. Historical offloads can add an older R-R or
    /// motion row while the app is running; without this bracket the archive could contain HR from database
    /// state A and motion from state B. If the witness changes, the whole read is discarded and retried.
    public static func capture(store: WhoopStore,
                               archive: NightLabFileStore,
                               request: NightLabStoreBridgeRequest) async throws -> NightLabStoreBridgeResult {
        let windowDuration = request.windowEndUnix.subtractingReportingOverflow(request.windowStartUnix)
        guard !windowDuration.overflow, windowDuration.partialValue > 0 else {
            throw NightLabStoreBridgeError.invalidWindow
        }
        guard request.maxRowsPerStream > 0, request.maxRowsPerStream < Int.max else {
            throw NightLabStoreBridgeError.invalidRowLimit
        }
        guard request.maxSnapshotAttempts > 0 else {
            throw NightLabStoreBridgeError.invalidSnapshotAttempts
        }

        // Read and validate the entire source snapshot BEFORE creating archive state. Row-limit failures and
        // a moving offload therefore leave no partial night behind.
        let snapshot = try await stableSnapshot(store: store, request: request)
        let sourceModel = request.sourceDeviceModelOverride ?? snapshot.sourceDeviceModel

        let recording = NightRecordManifest(
            nightID: request.nightID,
            state: .recording,
            windowStartUnix: request.windowStartUnix,
            windowEndUnix: request.windowEndUnix,
            timezoneOffsetSeconds: request.timezoneOffsetSeconds,
            sourceDeviceID: request.deviceID,
            sourceDeviceModel: sourceModel,
            sourceFirmware: request.sourceFirmware,
            sourceStoreSchemaVersion: WhoopStoreInfo.schemaVersion,
            sourceStreamFingerprint: snapshot.fingerprint,
            noopVersion: request.noopVersion,
            rawAssets: []
        )
        try await archive.createNight(recording)

        do {
            // Store the EXACT rows returned by NOOP's normal read policy. Sorted-key JSON makes repeated
            // captures byte-stable for the same rows and therefore gives useful SHA-256 evidence.
            try await appendIfPresent(snapshot.hr,
                                      timestamps: snapshot.hr.map(\.ts),
                                      nightID: request.nightID,
                                      assetID: "hr",
                                      kind: .heartRate,
                                      fileName: "hr.json",
                                      expectedCadenceHz: 1.0,
                                      archive: archive)
            try await appendIfPresent(snapshot.rr,
                                      timestamps: snapshot.rr.map(\.ts),
                                      nightID: request.nightID,
                                      assetID: "rr",
                                      kind: .rrIntervals,
                                      fileName: "rr.json",
                                      expectedCadenceHz: nil,
                                      archive: archive)
            try await appendIfPresent(snapshot.gravity,
                                      timestamps: snapshot.gravity.map(\.ts),
                                      nightID: request.nightID,
                                      assetID: "gravity",
                                      kind: .accelerometer,
                                      fileName: "gravity.json",
                                      expectedCadenceHz: 1.0,
                                      archive: archive)
            try await appendIfPresent(snapshot.respiration,
                                      timestamps: snapshot.respiration.map(\.ts),
                                      nightID: request.nightID,
                                      assetID: "respiration",
                                      kind: .respiration,
                                      fileName: "respiration.json",
                                      expectedCadenceHz: 1.0,
                                      archive: archive)

            let wristRows = snapshot.wristStatus.map {
                NightLabWristStatusRow(ts: $0.ts, state: $0.contact.rawValue)
            }
            try await appendIfPresent(wristRows,
                                      timestamps: wristRows.map(\.ts),
                                      nightID: request.nightID,
                                      assetID: "wrist-status",
                                      kind: .wristStatus,
                                      fileName: "wrist-status.json",
                                      expectedCadenceHz: nil,
                                      archive: archive)

            let coverage = coverageReports(snapshot: snapshot,
                                           windowStartUnix: request.windowStartUnix,
                                           windowEndUnix: request.windowEndUnix)
            let sealed = try await archive.sealNight(nightID: request.nightID)
            return NightLabStoreBridgeResult(manifest: sealed,
                                             coverage: coverage,
                                             sourceFingerprint: snapshot.fingerprint)
        } catch {
            // The bridge owns this recording because createNight above succeeded. Roll it back so a transient
            // filesystem/encoding error can be retried with the same night ID. discardRecordingNight refuses
            // sealed evidence, so this cleanup path can never delete a successful archive.
            try? await archive.discardRecordingNight(nightID: request.nightID)
            throw error
        }
    }

    // MARK: - Stable source snapshot

    private static func stableSnapshot(store: WhoopStore,
                                       request: NightLabStoreBridgeRequest) async throws -> Snapshot {
        // Store readers are inclusive at the upper bound. The request was validated above, so subtracting
        // one is safe and converts the Night Lab half-open interval without changing a legitimate row.
        let inclusiveEnd = request.windowEndUnix - 1
        let fetchLimit = request.maxRowsPerStream + 1

        for _ in 0..<request.maxSnapshotAttempts {
            let before = try await sourceFingerprint(store: store,
                                                     deviceID: request.deviceID,
                                                     from: request.windowStartUnix,
                                                     to: inclusiveEnd)

            let hr = try await store.hrSamples(deviceId: request.deviceID,
                                               from: request.windowStartUnix,
                                               to: inclusiveEnd,
                                               limit: fetchLimit)
            try enforceLimit(hr.count, kind: .heartRate, limit: request.maxRowsPerStream)

            let rr = try await store.rrIntervals(deviceId: request.deviceID,
                                                 from: request.windowStartUnix,
                                                 to: inclusiveEnd,
                                                 limit: fetchLimit,
                                                 unlabelledAliasOfWhoop5: request.unlabelledAliasOfWhoop5)
            try enforceLimit(rr.count, kind: .rrIntervals, limit: request.maxRowsPerStream)

            let gravity = try await store.gravitySamples(deviceId: request.deviceID,
                                                         from: request.windowStartUnix,
                                                         to: inclusiveEnd,
                                                         limit: fetchLimit)
            try enforceLimit(gravity.count, kind: .accelerometer, limit: request.maxRowsPerStream)

            let respiration = try await store.respSamples(deviceId: request.deviceID,
                                                          from: request.windowStartUnix,
                                                          to: inclusiveEnd,
                                                          limit: fetchLimit)
            try enforceLimit(respiration.count, kind: .respiration, limit: request.maxRowsPerStream)

            let wristStatus = try await store.standardHRContacts(deviceId: request.deviceID,
                                                                 from: request.windowStartUnix,
                                                                 to: inclusiveEnd,
                                                                 limit: fetchLimit)
            try enforceLimit(wristStatus.count, kind: .wristStatus, limit: request.maxRowsPerStream)

            // Registry model lookup belongs INSIDE the witness bracket. dayStreamFingerprint contains the
            // registry brand/model text, so a concurrent model reconciliation causes this attempt to retry.
            let sourceDeviceModel = modelFromRegistry(store: store, deviceID: request.deviceID)
            let after = try await sourceFingerprint(store: store,
                                                    deviceID: request.deviceID,
                                                    from: request.windowStartUnix,
                                                    to: inclusiveEnd)
            if before == after {
                return Snapshot(hr: hr,
                                rr: rr,
                                gravity: gravity,
                                respiration: respiration,
                                wristStatus: wristStatus,
                                sourceDeviceModel: sourceDeviceModel,
                                fingerprint: after)
            }
        }

        throw NightLabStoreBridgeError.sourceChangedDuringSnapshot(attempts: request.maxSnapshotAttempts)
    }

    /// Composite witness for EVERY source the bridge currently snapshots.
    ///
    /// `dayStreamFingerprint` intentionally omits measured `hrSample` because its original cache job did not
    /// need that row family. Night Lab does. Pairing it with `hrFingerprint` closes that hole while retaining
    /// dayStreamFingerprint's PPG fallback, R-R, respiration, gravity, event and registry witnesses.
    private static func sourceFingerprint(store: WhoopStore,
                                          deviceID: String,
                                          from: Int,
                                          to: Int) async throws -> String {
        let day = try await store.dayStreamFingerprint(deviceId: deviceID, from: from, to: to)
        let measuredHR = try await store.hrFingerprint(deviceId: deviceID, from: from, to: to)
        return day + "|measuredHr\(measuredHR.count):\(measuredHR.maxTs)"
    }

    private static func enforceLimit(_ count: Int,
                                     kind: NightSignalKind,
                                     limit: Int) throws {
        if count > limit {
            throw NightLabStoreBridgeError.rowLimitExceeded(kind: kind, limit: limit)
        }
    }

    // MARK: - Archive encoding

    private static func appendIfPresent<T: Encodable>(_ rows: [T],
                                                       timestamps: [Int],
                                                       nightID: String,
                                                       assetID: String,
                                                       kind: NightSignalKind,
                                                       fileName: String,
                                                       expectedCadenceHz: Double?,
                                                       archive: NightLabFileStore) async throws {
        guard !rows.isEmpty else { return }
        guard let minTs = timestamps.min(), let maxTs = timestamps.max() else { return }
        let bytes = try NightLabJSON.encode(rows)
        _ = try await archive.appendRawAsset(nightID: nightID,
                                             assetID: assetID,
                                             kind: kind,
                                             fileName: fileName,
                                             data: bytes,
                                             startUnix: minTs,
                                             endUnix: maxTs + 1,
                                             sampleCount: rows.count,
                                             expectedCadenceHz: expectedCadenceHz)
    }

    // MARK: - Coverage / provenance

    private static func coverageReports(snapshot: Snapshot,
                                        windowStartUnix: Int,
                                        windowEndUnix: Int) -> [NightSignalCoverageReport] {
        let windowDuration = windowEndUnix.subtractingReportingOverflow(windowStartUnix)
        let windowSeconds = windowDuration.overflow ? 0 : max(0, windowDuration.partialValue)
        let hr = NightSignalCoverage.analyze(kind: .heartRate,
                                             timestamps: snapshot.hr.map(\.ts),
                                             windowStartUnix: windowStartUnix,
                                             windowEndUnix: windowEndUnix,
                                             expectedCadenceHz: 1.0)
        let rr = NightSignalCoverage.analyze(kind: .rrIntervals,
                                             timestamps: snapshot.rr.map(\.ts),
                                             windowStartUnix: windowStartUnix,
                                             windowEndUnix: windowEndUnix,
                                             expectedCadenceHz: nil)
        let gravity = NightSignalCoverage.analyze(kind: .accelerometer,
                                                  timestamps: snapshot.gravity.map(\.ts),
                                                  windowStartUnix: windowStartUnix,
                                                  windowEndUnix: windowEndUnix,
                                                  expectedCadenceHz: 1.0)
        let respiration = NightSignalCoverage.analyze(kind: .respiration,
                                                      timestamps: snapshot.respiration.map(\.ts),
                                                      windowStartUnix: windowStartUnix,
                                                      windowEndUnix: windowEndUnix,
                                                      expectedCadenceHz: 1.0)

        // Contact is sparse STATE-CHANGE evidence, not a sampled 1 Hz signal. A ten-hour interval between
        // identical contact states is not a ten-hour data gap, so deliberately do not manufacture gap or
        // percentage statistics for this stream.
        let wrist = NightSignalCoverageReport(kind: .wristStatus,
                                              sampleCount: snapshot.wristStatus.count,
                                              windowSeconds: windowSeconds,
                                              expectedSamples: nil,
                                              coverageFraction: nil,
                                              largestGapSeconds: nil,
                                              gapCount: nil)
        return [hr, rr, gravity, respiration, wrist]
    }

    private static func modelFromRegistry(store: WhoopStore, deviceID: String) -> String? {
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        // Registry absence is legal: imported/forgotten device ids may retain durable sample rows. Capturing
        // those rows is more important than inventing a model label or failing an otherwise reproducible night.
        return (try? registry.all())?.first(where: { $0.id == deviceID })?.model
    }
}
