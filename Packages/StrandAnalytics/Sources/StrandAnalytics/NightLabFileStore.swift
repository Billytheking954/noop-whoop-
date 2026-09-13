import Foundation
import CryptoKit

public enum NightLabFileStoreError: Error, Sendable, Equatable {
    case nightAlreadyExists(String)
    case nightNotFound(String)
    case nightNotRecording(String)
    case nightAlreadySealed(String)
    case rawAssetAlreadyExists(String)
    case rawAssetNotFound(String)
    case unsafeFileName(String)
    case referenceNightMismatch(expected: String, actual: String)
    case corruptRawAsset(String)
}

/// Local write-once archive for Night Lab research nights.
///
/// This store is intentionally separate from WhoopStore.rawBatch. rawBatch is transient working data and
/// may be pruned; Night Lab nights are evidence selected for replay and must survive normal raw-data pruning.
///
/// The actor boundary serializes mutations so a capture callback and a seal request cannot race each other.
public actor NightLabFileStore {
    private let rootDirectory: URL
    private let fileManager: FileManager

    public init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    /// Create a new recording night and its isolated raw/derived/reference namespaces.
    public func createNight(_ manifest: NightRecordManifest) throws {
        guard manifest.state == .recording else {
            throw NightLabFileStoreError.nightAlreadySealed(manifest.nightID)
        }
        try NightManifestValidator.validate(manifest)

        let directory = nightURL(manifest.nightID)
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw NightLabFileStoreError.nightAlreadyExists(manifest.nightID)
        }

        try fileManager.createDirectory(at: rawURL(manifest.nightID),
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: derivedURL(manifest.nightID),
                                        withIntermediateDirectories: true)
        try fileManager.createDirectory(at: referencesURL(manifest.nightID),
                                        withIntermediateDirectories: true)
        try writeManifest(manifest)
    }

    public func loadManifest(nightID: String) throws -> NightRecordManifest {
        let url = manifestURL(nightID)
        guard fileManager.fileExists(atPath: url.path) else {
            throw NightLabFileStoreError.nightNotFound(nightID)
        }
        return try NightLabJSON.decode(NightRecordManifest.self, from: Data(contentsOf: url))
    }

    /// Append one raw asset while a night is recording. Existing raw files are never replaced.
    ///
    /// `fileName` is a basename only. The stored manifest receives the canonical `raw/<fileName>` path and
    /// a SHA-256 digest of the exact bytes written to disk.
    @discardableResult
    public func appendRawAsset(nightID: String,
                               assetID: String,
                               kind: NightSignalKind,
                               fileName: String,
                               data: Data,
                               startUnix: Int,
                               endUnix: Int,
                               sampleCount: Int,
                               expectedCadenceHz: Double? = nil) throws -> NightRawAsset {
        guard isSafeFileName(fileName) else {
            throw NightLabFileStoreError.unsafeFileName(fileName)
        }

        let manifest = try loadManifest(nightID: nightID)
        guard manifest.state == .recording else {
            throw NightLabFileStoreError.nightNotRecording(nightID)
        }
        guard !manifest.rawAssets.contains(where: { $0.id == assetID }) else {
            throw NightLabFileStoreError.rawAssetAlreadyExists(assetID)
        }

        let destination = rawURL(nightID).appendingPathComponent(fileName, isDirectory: false)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw NightLabFileStoreError.rawAssetAlreadyExists(assetID)
        }

        let digest = Self.sha256Hex(data)
        let asset = NightRawAsset(id: assetID,
                                  kind: kind,
                                  relativePath: "raw/\(fileName)",
                                  startUnix: startUnix,
                                  endUnix: endUnix,
                                  sampleCount: sampleCount,
                                  expectedCadenceHz: expectedCadenceHz,
                                  digestAlgorithm: "sha256",
                                  digest: digest)

        let updated = copyManifest(manifest,
                                   state: .recording,
                                   rawAssets: manifest.rawAssets + [asset])
        try NightManifestValidator.validate(updated)

        do {
            try data.write(to: destination, options: [.atomic, .withoutOverwriting])
            do {
                try writeManifest(updated)
            } catch {
                try? fileManager.removeItem(at: destination)
                throw error
            }
        } catch CocoaError.fileWriteFileExists {
            throw NightLabFileStoreError.rawAssetAlreadyExists(assetID)
        }

        return asset
    }

    /// Seal the raw evidence. Before the state changes, every declared asset is re-read and checked against
    /// its stored digest. A corrupted/missing raw asset prevents sealing rather than silently blessing it.
    @discardableResult
    public func sealNight(nightID: String) throws -> NightRecordManifest {
        let manifest = try loadManifest(nightID: nightID)
        if manifest.state == .sealed {
            throw NightLabFileStoreError.nightAlreadySealed(nightID)
        }

        for asset in manifest.rawAssets {
            let data = try verifiedRawData(nightID: nightID, asset: asset)
            guard !data.isEmpty || asset.sampleCount == 0 else {
                throw NightLabFileStoreError.corruptRawAsset(asset.id)
            }
        }

        let sealed = copyManifest(manifest, state: .sealed, rawAssets: manifest.rawAssets)
        try NightManifestValidator.validate(sealed)
        try writeManifest(sealed)
        return sealed
    }

    /// Read a raw asset and verify its digest before returning bytes to replay code.
    public func rawData(nightID: String, assetID: String) throws -> Data {
        let manifest = try loadManifest(nightID: nightID)
        guard let asset = manifest.rawAssets.first(where: { $0.id == assetID }) else {
            throw NightLabFileStoreError.rawAssetNotFound(assetID)
        }
        return try verifiedRawData(nightID: nightID, asset: asset)
    }

    /// Persist a derived run without mutating raw evidence. A run with the same identity/time is write-once.
    public func saveRun(_ run: NightAlgorithmRun) throws {
        _ = try loadManifest(nightID: run.nightID)
        let name = safeComponent(run.algorithm.id) + "_" + safeComponent(run.algorithm.version)
            + "_\(run.runAtUnix).json"
        let url = derivedURL(run.nightID).appendingPathComponent(name, isDirectory: false)
        try writeNew(try NightLabJSON.encode(run), to: url)
    }

    /// Persist reference labels in their own namespace. These bytes are never loaded by the replay runner.
    public func saveReference(_ reference: NightReferenceLabels, for nightID: String) throws {
        _ = try loadManifest(nightID: nightID)
        guard reference.nightID == nightID else {
            throw NightLabFileStoreError.referenceNightMismatch(expected: nightID, actual: reference.nightID)
        }
        let name = safeComponent(reference.provider) + "_\(reference.importedAtUnix).json"
        let url = referencesURL(nightID).appendingPathComponent(name, isDirectory: false)
        try writeNew(try NightLabJSON.encode(reference), to: url)
    }

    public func makeReplayInput(nightID: String,
                                coverage: [NightSignalCoverageReport]) throws -> NightReplayInput {
        let manifest = try loadManifest(nightID: nightID)
        try NightManifestValidator.validate(manifest)
        return NightReplayInput(manifest: manifest, coverage: coverage)
    }

    // MARK: - Integrity

    private func verifiedRawData(nightID: String, asset: NightRawAsset) throws -> Data {
        let prefix = "raw/"
        guard asset.relativePath.hasPrefix(prefix) else {
            throw NightLabFileStoreError.corruptRawAsset(asset.id)
        }
        let fileName = String(asset.relativePath.dropFirst(prefix.count))
        guard isSafeFileName(fileName) else {
            throw NightLabFileStoreError.corruptRawAsset(asset.id)
        }
        let url = rawURL(nightID).appendingPathComponent(fileName, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else {
            throw NightLabFileStoreError.rawAssetNotFound(asset.id)
        }
        let data = try Data(contentsOf: url)
        guard asset.digestAlgorithm?.lowercased() == "sha256",
              let expected = asset.digest,
              Self.sha256Hex(data) == expected else {
            throw NightLabFileStoreError.corruptRawAsset(asset.id)
        }
        return data
    }

    public nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Paths / writes

    /// Rebuild a manifest without dropping provenance as its state/assets change. Keeping this construction
    /// in one place prevents a future schema field from being silently erased by append/seal lifecycle code.
    private func copyManifest(_ manifest: NightRecordManifest,
                              state: NightRecordState,
                              rawAssets: [NightRawAsset]) -> NightRecordManifest {
        NightRecordManifest(schemaVersion: manifest.schemaVersion,
                            nightID: manifest.nightID,
                            state: state,
                            windowStartUnix: manifest.windowStartUnix,
                            windowEndUnix: manifest.windowEndUnix,
                            timezoneOffsetSeconds: manifest.timezoneOffsetSeconds,
                            sourceDeviceID: manifest.sourceDeviceID,
                            sourceDeviceModel: manifest.sourceDeviceModel,
                            sourceFirmware: manifest.sourceFirmware,
                            sourceStoreSchemaVersion: manifest.sourceStoreSchemaVersion,
                            sourceStreamFingerprint: manifest.sourceStreamFingerprint,
                            noopVersion: manifest.noopVersion,
                            rawAssets: rawAssets)
    }

    private func nightURL(_ nightID: String) -> URL {
        rootDirectory.appendingPathComponent(NightLabArchiveLayout.nightDirectory(nightID), isDirectory: true)
    }

    private func manifestURL(_ nightID: String) -> URL {
        nightURL(nightID).appendingPathComponent("manifest.json", isDirectory: false)
    }

    private func rawURL(_ nightID: String) -> URL {
        nightURL(nightID).appendingPathComponent("raw", isDirectory: true)
    }

    private func derivedURL(_ nightID: String) -> URL {
        nightURL(nightID).appendingPathComponent("derived", isDirectory: true)
    }

    private func referencesURL(_ nightID: String) -> URL {
        nightURL(nightID).appendingPathComponent("references", isDirectory: true)
    }

    private func writeManifest(_ manifest: NightRecordManifest) throws {
        let data = try NightLabJSON.encode(manifest)
        try data.write(to: manifestURL(manifest.nightID), options: [.atomic])
    }

    private func writeNew(_ data: Data, to url: URL) throws {
        guard !fileManager.fileExists(atPath: url.path) else {
            throw NightLabFileStoreError.rawAssetAlreadyExists(url.lastPathComponent)
        }
        do {
            try data.write(to: url, options: [.atomic, .withoutOverwriting])
        } catch CocoaError.fileWriteFileExists {
            throw NightLabFileStoreError.rawAssetAlreadyExists(url.lastPathComponent)
        }
    }

    private func isSafeFileName(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    private func safeComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let result = String(scalars)
        return result.isEmpty ? "unknown" : result
    }
}
