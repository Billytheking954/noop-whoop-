import Foundation
import CryptoKit

public struct NightDerivedArtifactIdentity: Codable, Sendable, Equatable {
    public let relativePath: String
    public let sha256: String
    public let byteCount: Int

    public init(relativePath: String, sha256: String, byteCount: Int) {
        self.relativePath = relativePath
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

/// One byte-exact member of a portable Night Lab bundle. Paths are relative to the night directory and
/// are constrained to the archive's manifest/raw/derived/reference namespaces during export and import.
public struct NightLabBundleEntry: Codable, Sendable, Equatable {
    public let relativePath: String
    public let sha256: String
    public let byteCount: Int
    public let data: Data

    public init(relativePath: String, sha256: String, byteCount: Int, data: Data) {
        self.relativePath = relativePath
        self.sha256 = sha256
        self.byteCount = byteCount
        self.data = data
    }
}

/// Deterministic, dependency-free transport container for one sealed research night.
///
/// The same archived bytes always encode to the same bundle bytes: there is deliberately no export time,
/// device name, or other live metadata here. `files` is required to be in lexical path order.
public struct NightLabBundle: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let nightID: String
    public let files: [NightLabBundleEntry]

    public init(schemaVersion: Int = NightLabBundle.currentSchemaVersion,
                nightID: String,
                files: [NightLabBundleEntry]) {
        self.schemaVersion = schemaVersion
        self.nightID = nightID
        self.files = files
    }
}

public enum NightLabBundleImportDisposition: String, Codable, Sendable, Equatable {
    case imported
    case alreadyPresent
}

public struct NightLabBundleImportResult: Sendable, Equatable {
    public let nightID: String
    public let disposition: NightLabBundleImportDisposition
    public let bundleSHA256: String

    public init(nightID: String,
                disposition: NightLabBundleImportDisposition,
                bundleSHA256: String) {
        self.nightID = nightID
        self.disposition = disposition
        self.bundleSHA256 = bundleSHA256
    }
}

public enum NightLabBundleError: Error, Sendable, Equatable {
    case unsupportedSchema(Int)
    case nonCanonicalEncoding
    case nightNotSealed(String)
    case missingManifest
    case manifestNightMismatch(expected: String, actual: String)
    case nonCanonicalFileOrder
    case duplicatePath(String)
    case unsafePath(String)
    case corruptEntry(String)
    case rawInventoryMismatch
    case invalidReference(String)
    case invalidDerivedEvidence(String)
    case targetConflict(String)
}

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
    case derivedRequiresSealedNight(String)
    case derivedArtifactConflict(String)
    case derivedArtifactNotFound(String)
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

    /// Remove an incomplete recording so a failed multi-file capture can be retried cleanly.
    ///
    /// This is deliberately NOT a general delete API. A sealed night is immutable evidence and can never be
    /// removed through this rollback path. The actor serializes this against append/seal operations.
    public func discardRecordingNight(nightID: String) throws {
        let manifest = try loadManifest(nightID: nightID)
        guard manifest.state == .recording else {
            throw NightLabFileStoreError.nightNotRecording(nightID)
        }
        try fileManager.removeItem(at: nightURL(nightID))
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

        guard try createWriteOnce(data, at: destination) else {
            throw NightLabFileStoreError.rawAssetAlreadyExists(assetID)
        }
        do {
            try writeManifest(updated)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
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

    // MARK: - Portable bundle export/import

    /// Export every archived file for one sealed night into canonical, byte-identical JSON.
    /// Raw assets are re-hashed through the normal verified read path before any bundle is returned.
    public func exportBundle(nightID: String) throws -> Data {
        let manifest = try loadManifest(nightID: nightID)
        guard manifest.state == .sealed else { throw NightLabBundleError.nightNotSealed(nightID) }
        try NightManifestValidator.validate(manifest)
        for asset in manifest.rawAssets {
            _ = try verifiedRawData(nightID: nightID, asset: asset)
        }

        let directory = nightURL(nightID)
        try inspectionSafePath(directory)
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw NightLabFileStoreError.nightNotFound(nightID)
        }

        var entries: [NightLabBundleEntry] = []
        while let item = enumerator.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey,
                                                            .isSymbolicLinkKey])
            let relativePath = try bundleRelativePath(for: item, under: directory)
            if values.isSymbolicLink == true {
                throw NightLabBundleError.unsafePath(relativePath)
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, Self.isSafeBundlePath(relativePath) else {
                throw NightLabBundleError.unsafePath(relativePath)
            }
            let data = try Data(contentsOf: item)
            entries.append(NightLabBundleEntry(relativePath: relativePath,
                                               sha256: Self.sha256Hex(data),
                                               byteCount: data.count,
                                               data: data))
        }
        if let enumerationError { throw enumerationError }
        entries.sort { $0.relativePath < $1.relativePath }
        guard entries.contains(where: { $0.relativePath == "manifest.json" }) else {
            throw NightLabBundleError.missingManifest
        }
        let bundle = NightLabBundle(nightID: nightID, files: entries)
        try Self.validateBundleEnvelope(bundle)
        try Self.validateReferences(in: bundle)
        return try NightLabJSON.encode(bundle)
    }

    /// Validate a complete portable bundle in an isolated staging archive, then publish it without replacing
    /// any existing night. Importing byte-identical evidence is idempotent; a different archive with the same
    /// night id is a hard conflict.
    @discardableResult
    public func importBundle(_ data: Data) async throws -> NightLabBundleImportResult {
        let bundle = try NightLabJSON.decode(NightLabBundle.self, from: data)
        try Self.validateBundleEnvelope(bundle)
        let canonicalData = try NightLabJSON.encode(bundle)
        guard canonicalData == data else { throw NightLabBundleError.nonCanonicalEncoding }
        let digest = Self.sha256Hex(canonicalData)

        let destination = nightURL(bundle.nightID)
        if fileManager.fileExists(atPath: destination.path) {
            let existing: Data
            do { existing = try exportBundle(nightID: bundle.nightID) }
            catch { throw NightLabBundleError.targetConflict(bundle.nightID) }
            guard existing == canonicalData else { throw NightLabBundleError.targetConflict(bundle.nightID) }
            return NightLabBundleImportResult(nightID: bundle.nightID,
                                              disposition: .alreadyPresent,
                                              bundleSHA256: digest)
        }

        let stagingRoot = rootDirectory.appendingPathComponent(
            ".NightLab-import-\(UUID().uuidString)", isDirectory: true
        )
        let stagingStore = NightLabFileStore(rootDirectory: stagingRoot, fileManager: fileManager)
        let stagingNight = stagingRoot.appendingPathComponent(
            NightLabArchiveLayout.nightDirectory(bundle.nightID), isDirectory: true
        )
        defer { try? fileManager.removeItem(at: stagingRoot) }

        try fileManager.createDirectory(at: stagingNight, withIntermediateDirectories: true)
        for entry in bundle.files {
            let target = stagingNight.appendingPathComponent(entry.relativePath, isDirectory: false)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try entry.data.write(to: target, options: [.atomic])
        }

        // The typed loader proves raw hashes, row counts, signal kinds, and the half-open night window.
        _ = try await NightLabArchiveLoader.load(archive: stagingStore, nightID: bundle.nightID)
        let inspection = try await NightLabInspection.load(archive: stagingStore, nightID: bundle.nightID)
        if let error = inspection.baselineError {
            throw NightLabBundleError.invalidDerivedEvidence(error)
        }
        if let error = inspection.receiptsError {
            throw NightLabBundleError.invalidDerivedEvidence(error)
        }
        if let invalid = inspection.receipts.first(where: { $0.error != nil }) {
            throw NightLabBundleError.invalidDerivedEvidence(invalid.fileName)
        }
        try Self.validateReferences(in: bundle)

        try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        do {
            try fileManager.moveItem(at: stagingNight, to: destination)
        } catch {
            // A different store actor may have won the publish race. Preserve it and only accept exact bytes.
            if fileManager.fileExists(atPath: destination.path) {
                let existing: Data
                do { existing = try exportBundle(nightID: bundle.nightID) }
                catch { throw NightLabBundleError.targetConflict(bundle.nightID) }
                guard existing == canonicalData else { throw NightLabBundleError.targetConflict(bundle.nightID) }
                return NightLabBundleImportResult(nightID: bundle.nightID,
                                                  disposition: .alreadyPresent,
                                                  bundleSHA256: digest)
            }
            throw error
        }
        return NightLabBundleImportResult(nightID: bundle.nightID,
                                          disposition: .imported,
                                          bundleSHA256: digest)
    }

    /// Persist a derived run without mutating raw evidence. A run with the same identity/time is write-once.
    public func saveRun(_ run: NightAlgorithmRun) throws {
        _ = try loadManifest(nightID: run.nightID)
        let name = safeComponent(run.algorithm.id) + "_" + safeComponent(run.algorithm.version)
            + "_\(run.runAtUnix).json"
        let url = derivedURL(run.nightID).appendingPathComponent(name, isDirectory: false)
        try writeNew(try NightLabJSON.encode(run), to: url)
    }

    /// Save one canonical derived artifact. Replaying identical evidence is idempotent: byte-identical
    /// content returns the same identity. Different bytes at the same canonical path are evidence conflict,
    /// never an overwrite.
    @discardableResult
    public func saveDeterministicDerivedArtifact(nightID: String,
                                                 fileName: String,
                                                 data: Data) throws -> NightDerivedArtifactIdentity {
        try requireSealedNight(nightID)
        guard isSafeFileName(fileName) else { throw NightLabFileStoreError.unsafeFileName(fileName) }

        let relativePath = "derived/\(fileName)"
        let url = derivedURL(nightID).appendingPathComponent(fileName, isDirectory: false)
        return try saveDeterministic(data,
                                     to: url,
                                     relativePath: relativePath,
                                     conflictName: fileName)
    }

    /// Read an already-persisted canonical derived artifact. This is primarily an audit/test seam; replay
    /// algorithms never use previous derived results as inputs.
    public func derivedArtifactData(nightID: String, fileName: String) throws -> Data {
        _ = try loadManifest(nightID: nightID)
        guard isSafeFileName(fileName) else { throw NightLabFileStoreError.unsafeFileName(fileName) }
        let url = derivedURL(nightID).appendingPathComponent(fileName, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else {
            throw NightLabFileStoreError.derivedArtifactNotFound(fileName)
        }
        return try Data(contentsOf: url)
    }

    /// Append one non-deterministic execution artifact below derived/executions. Timing receipts belong here,
    /// not in the canonical baseline. Existing receipt paths are never replaced.
    @discardableResult
    public func saveExecutionDerivedArtifact(nightID: String,
                                             fileName: String,
                                             data: Data) throws -> NightDerivedArtifactIdentity {
        try requireSealedNight(nightID)
        guard isSafeFileName(fileName) else { throw NightLabFileStoreError.unsafeFileName(fileName) }
        let directory = executionsURL(nightID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        guard try createWriteOnce(data, at: url) else {
            throw NightLabFileStoreError.derivedArtifactConflict("executions/\(fileName)")
        }
        return NightDerivedArtifactIdentity(relativePath: "derived/executions/\(fileName)",
                                             sha256: Self.sha256Hex(data),
                                             byteCount: data.count)
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

    // MARK: - Read-only inspection

    public func inspectionNights() throws -> [NightLabInspectionEntry] {
        let directory = rootDirectory.appendingPathComponent("NightLab", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        try inspectionSafePath(directory)
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles]).sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }.map { url in
            let id = url.lastPathComponent
            do {
                let manifest = try inspectionManifest(nightID: id)
                return NightLabInspectionEntry(id: id, manifest: manifest, error: nil)
            } catch {
                return NightLabInspectionEntry(id: id, manifest: nil, error: String(describing: error))
            }
        }
    }

    public func inspectionManifest(nightID: String) throws -> NightRecordManifest {
        guard isSafeFileName(nightID) else { throw NightLabFileStoreError.unsafeFileName(nightID) }
        try inspectionSafePath(manifestURL(nightID))
        let manifest = try loadManifest(nightID: nightID)
        guard manifest.nightID == nightID else { throw NightLabInspectionError.manifestIdentityMismatch }
        guard (1...NightRecordManifest.currentSchemaVersion).contains(manifest.schemaVersion) else {
            throw NightLabInspectionError.unsupportedSchema(manifest.schemaVersion)
        }
        try NightManifestValidator.validate(manifest)
        for asset in manifest.rawAssets {
            try inspectionSafePath(nightURL(nightID).appendingPathComponent(asset.relativePath))
        }
        return manifest
    }

    public func inspectionBaselineData(nightID: String) throws -> Data? {
        let name = NightLabSleepStagerV2BaselineRunner.baselineFileName
        try inspectionSafePath(derivedURL(nightID).appendingPathComponent(name))
        do { return try derivedArtifactData(nightID: nightID, fileName: name) }
        catch NightLabFileStoreError.derivedArtifactNotFound { return nil }
    }

    public func inspectionReceipts(nightID: String) throws -> [NightLabInspectionReceipt] {
        let directory = executionsURL(nightID)
        try inspectionSafePath(directory)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles]).sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }.map { url in
            do {
                try inspectionSafePath(url)
                let receipt = try NightLabJSON.decode(SleepStagerV2ExecutionReceipt.self,
                                                       from: Data(contentsOf: url))
                return NightLabInspectionReceipt(fileName: url.lastPathComponent, receipt: receipt, error: nil)
            } catch {
                return NightLabInspectionReceipt(fileName: url.lastPathComponent, receipt: nil,
                                                   error: String(describing: error))
            }
        }
    }

    /// Inspection never follows archive symlinks, including dangling links. No paths are created.
    private func inspectionSafePath(_ url: URL) throws {
        let root = rootDirectory.standardizedFileURL
        let target = url.standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { throw NightLabInspectionError.unsafePath }
        var current = root
        for part in target.path.dropFirst(root.path.count + 1).split(separator: "/") {
            current.appendPathComponent(String(part))
            do {
                let attributes = try fileManager.attributesOfItem(atPath: current.path)
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    throw NightLabInspectionError.unsafePath
                }
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
                // Missing optional files are handled by their reader, not manufactured here.
            }
        }
    }

    // MARK: - Integrity

    private func requireSealedNight(_ nightID: String) throws {
        let manifest = try loadManifest(nightID: nightID)
        guard manifest.state == .sealed else {
            throw NightLabFileStoreError.derivedRequiresSealedNight(nightID)
        }
        try NightManifestValidator.validate(manifest)
    }

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

    private nonisolated static func validateBundleEnvelope(_ bundle: NightLabBundle) throws {
        guard bundle.schemaVersion == NightLabBundle.currentSchemaVersion else {
            throw NightLabBundleError.unsupportedSchema(bundle.schemaVersion)
        }
        guard isSafeBundleComponent(bundle.nightID) else {
            throw NightLabBundleError.unsafePath(bundle.nightID)
        }
        let paths = bundle.files.map(\.relativePath)
        guard paths == paths.sorted() else { throw NightLabBundleError.nonCanonicalFileOrder }
        var seen = Set<String>()
        for entry in bundle.files {
            guard seen.insert(entry.relativePath).inserted else {
                throw NightLabBundleError.duplicatePath(entry.relativePath)
            }
            guard isSafeBundlePath(entry.relativePath) else {
                throw NightLabBundleError.unsafePath(entry.relativePath)
            }
            guard entry.byteCount == entry.data.count,
                  entry.sha256 == sha256Hex(entry.data) else {
                throw NightLabBundleError.corruptEntry(entry.relativePath)
            }
        }
        guard let manifestEntry = bundle.files.first(where: { $0.relativePath == "manifest.json" }) else {
            throw NightLabBundleError.missingManifest
        }
        let manifest = try NightLabJSON.decode(NightRecordManifest.self, from: manifestEntry.data)
        guard manifest.nightID == bundle.nightID else {
            throw NightLabBundleError.manifestNightMismatch(expected: bundle.nightID,
                                                            actual: manifest.nightID)
        }
        guard manifest.state == .sealed else { throw NightLabBundleError.nightNotSealed(bundle.nightID) }
        guard (1...NightRecordManifest.currentSchemaVersion).contains(manifest.schemaVersion) else {
            throw NightLabBundleError.unsupportedSchema(manifest.schemaVersion)
        }
        try NightManifestValidator.validate(manifest)
        try validateRawInventory(manifest: manifest, entries: bundle.files)
    }

    private nonisolated static func validateRawInventory(manifest: NightRecordManifest,
                                                         entries: [NightLabBundleEntry]) throws {
        let declared = Set(manifest.rawAssets.map(\.relativePath))
        let bundled = Set(entries.map(\.relativePath).filter { $0.hasPrefix("raw/") })
        guard declared == bundled else { throw NightLabBundleError.rawInventoryMismatch }
    }

    private nonisolated static func validateReferences(in bundle: NightLabBundle) throws {
        for entry in bundle.files where entry.relativePath.hasPrefix("references/") {
            let reference = try NightLabJSON.decode(NightReferenceLabels.self, from: entry.data)
            guard reference.nightID == bundle.nightID else {
                throw NightLabBundleError.invalidReference(entry.relativePath)
            }
        }
    }

    private nonisolated static func isSafeBundleComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    private nonisolated static func isSafeBundlePath(_ path: String) -> Bool {
        if path == "manifest.json" { return true }
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy(isSafeBundleComponent) else { return false }
        if parts.count == 2 {
            return parts[0] == "raw" || parts[0] == "derived" || parts[0] == "references"
        }
        return parts.count == 3 && parts[0] == "derived" && parts[1] == "executions"
    }

    private func bundleRelativePath(for item: URL, under directory: URL) throws -> String {
        let base = directory.standardizedFileURL.path + "/"
        let path = item.standardizedFileURL.path
        guard path.hasPrefix(base) else { throw NightLabBundleError.unsafePath(path) }
        return String(path.dropFirst(base.count))
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

    private func executionsURL(_ nightID: String) -> URL {
        derivedURL(nightID).appendingPathComponent("executions", isDirectory: true)
    }

    private func referencesURL(_ nightID: String) -> URL {
        nightURL(nightID).appendingPathComponent("references", isDirectory: true)
    }

    private func writeManifest(_ manifest: NightRecordManifest) throws {
        let data = try NightLabJSON.encode(manifest)
        try data.write(to: manifestURL(manifest.nightID), options: [.atomic])
    }

    /// Publish a complete write-once file without ever replacing an existing destination.
    ///
    /// Foundation does not support combining `.atomic` and `.withoutOverwriting`. Instead, bytes are first
    /// written atomically to a private sibling staging file, then hard-linked into the final path. Creating
    /// the hard link is an atomic create-if-absent operation on the same filesystem: if another writer won
    /// the race, the existing destination is preserved and this method returns `false`.
    private func createWriteOnce(_ data: Data, at destination: URL) throws -> Bool {
        let directory = destination.deletingLastPathComponent()
        let staging = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).nightlab-tmp",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: staging) }

        try data.write(to: staging, options: [.atomic])
        do {
            try fileManager.linkItem(at: staging, to: destination)
            return true
        } catch {
            if fileManager.fileExists(atPath: destination.path) {
                return false
            }
            throw error
        }
    }

    private func saveDeterministic(_ data: Data,
                                   to url: URL,
                                   relativePath: String,
                                   conflictName: String) throws -> NightDerivedArtifactIdentity {
        if fileManager.fileExists(atPath: url.path) {
            let existing = try Data(contentsOf: url)
            guard existing == data else {
                throw NightLabFileStoreError.derivedArtifactConflict(conflictName)
            }
            return NightDerivedArtifactIdentity(relativePath: relativePath,
                                                 sha256: Self.sha256Hex(existing),
                                                 byteCount: existing.count)
        }

        if try !createWriteOnce(data, at: url) {
            // An external writer won the publish race. Identical bytes remain idempotent; different bytes
            // are a hard evidence conflict and are never replaced.
            let existing = try Data(contentsOf: url)
            guard existing == data else {
                throw NightLabFileStoreError.derivedArtifactConflict(conflictName)
            }
        }
        return NightDerivedArtifactIdentity(relativePath: relativePath,
                                             sha256: Self.sha256Hex(data),
                                             byteCount: data.count)
    }

    private func writeNew(_ data: Data, to url: URL) throws {
        guard try createWriteOnce(data, at: url) else {
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
