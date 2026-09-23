import Foundation

/// Transaction boundary between an incremental observation provider and durable canonical evidence.
///
/// `commit(_:expectedPriorCursor:)` is compare-and-swap: the batch is accepted only when the cursor
/// used to fetch it is still the store's current cursor. A successful commit makes the observations,
/// deletions, and `nextCursor` visible together. A failed commit leaves the prior cursor replayable.
public protocol ObservationChangeStore: Sendable {
    func cursor(for provider: String) async throws -> ProviderCursor?
    func observation(provider: String, providerIdentifier: String) async throws -> ObservationRecord?
    func observations(for provider: String) async throws -> [ObservationRecord]
    func commit(_ batch: ObservationChangeBatch,
                expectedPriorCursor: ProviderCursor?) async throws
}

public enum ObservationStoreError: Error, Sendable, Equatable {
    case invalidProviderIdentifier
    case staleCursor
    case unsupportedSchemaVersion(Int)
    case invalidSequence(expected: UInt64, actual: UInt64)
    case filenameSequenceMismatch(filename: String, sequence: UInt64)
    case storedProviderMismatch(sequence: UInt64)
    case cursorChainMismatch(sequence: UInt64)
    case sequenceAlreadyExists(UInt64)
}

/// Durable append-only reference store for canonical observation batches.
///
/// Each successful transaction is one immutable JSON file. The file contains the observations,
/// deletions, and advanced cursor in the same payload, so a crash cannot persist one without the
/// others. Writes publish through a temporary file + rename and never overwrite an existing commit.
/// Materialized reads replay the provider's log deterministically; later storage engines can conform to
/// `ObservationChangeStore` without changing provider adapters.
public actor FileObservationStore: ObservationChangeStore {
    static let schemaVersion = 1

    struct StoredBatch: Codable, Hashable, Sendable {
        let schemaVersion: Int
        let sequence: UInt64
        let priorCursor: ProviderCursor?
        let batch: ObservationChangeBatch
    }

    struct MaterializedHistory {
        let observationsByIdentifier: [String: ObservationRecord]
    }

    typealias SnapshotWriter = @Sendable (Data, URL) throws -> Void

    private let rootDirectory: URL
    private let fileManager: FileManager
    private let writer: SnapshotWriter

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        self.fileManager = .default
        self.writer = { data, destination in
            try Self.publishWithoutOverwrite(data, to: destination)
        }
    }

    init(rootDirectory: URL,
         fileManager: FileManager = .default,
         writer: @escaping SnapshotWriter) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        self.writer = writer
    }

    public func cursor(for provider: String) async throws -> ProviderCursor? {
        try validateProviderIdentifier(provider)
        return try latestStoredBatch(for: provider)?.batch.nextCursor
    }

    public func observation(provider: String,
                            providerIdentifier: String) async throws -> ObservationRecord? {
        try validateProviderIdentifier(provider)
        try validateProviderIdentifier(providerIdentifier)
        let history = try materialize(provider: provider)
        return history.observationsByIdentifier[providerIdentifier]
    }

    public func observations(for provider: String) async throws -> [ObservationRecord] {
        try validateProviderIdentifier(provider)
        return try materialize(provider: provider).observationsByIdentifier.values.sorted(by: Self.sortRecords)
    }

    public func commit(_ batch: ObservationChangeBatch,
                       expectedPriorCursor: ProviderCursor?) async throws {
        try ObservationChangeBatchValidator.validate(batch)
        let latest = try latestStoredBatch(for: batch.provider)
        let currentCursor = latest?.batch.nextCursor
        guard currentCursor == expectedPriorCursor else {
            throw ObservationStoreError.staleCursor
        }

        let nextSequence = (latest?.sequence ?? 0) + 1
        let stored = StoredBatch(
            schemaVersion: Self.schemaVersion,
            sequence: nextSequence,
            priorCursor: expectedPriorCursor,
            batch: batch
        )
        let data = try Self.encoder.encode(stored)
        let directory = providerDirectory(for: batch.provider)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(Self.batchFilename(sequence: nextSequence))
        if fileManager.fileExists(atPath: destination.path) {
            throw ObservationStoreError.sequenceAlreadyExists(nextSequence)
        }
        try writer(data, destination)
    }

    private func latestStoredBatch(for provider: String) throws -> StoredBatch? {
        let files = try batchFiles(for: provider)
        guard let latest = files.last else { return nil }
        return try decodeAndValidate(latest, provider: provider, expectedSequence: nil)
    }

    private func materialize(provider: String) throws -> MaterializedHistory {
        let files = try batchFiles(for: provider)
        var expectedSequence: UInt64 = 1
        var priorCursor: ProviderCursor?
        var observations: [String: ObservationRecord] = [:]

        for file in files {
            let stored = try decodeAndValidate(file, provider: provider, expectedSequence: expectedSequence)
            guard stored.priorCursor == priorCursor else {
                throw ObservationStoreError.cursorChainMismatch(sequence: stored.sequence)
            }

            for observation in stored.batch.observations {
                guard let identifier = observation.provenance.providerIdentifier else {
                    // The batch validator already rejects this. Reaching this guard means the stored
                    // payload changed underneath the validator contract, so surface corruption.
                    throw ObservationChangeValidationError.missingObservationProviderIdentifier
                }
                observations[identifier] = observation
            }
            for deletion in stored.batch.deletions {
                observations.removeValue(forKey: deletion.providerIdentifier)
            }

            priorCursor = stored.batch.nextCursor
            expectedSequence += 1
        }

        return MaterializedHistory(observationsByIdentifier: observations)
    }

    private func decodeAndValidate(_ file: URL,
                                   provider: String,
                                   expectedSequence: UInt64?) throws -> StoredBatch {
        let data = try Data(contentsOf: file)
        let stored = try Self.decoder.decode(StoredBatch.self, from: data)
        guard stored.schemaVersion == Self.schemaVersion else {
            throw ObservationStoreError.unsupportedSchemaVersion(stored.schemaVersion)
        }
        if let expectedSequence, stored.sequence != expectedSequence {
            throw ObservationStoreError.invalidSequence(expected: expectedSequence, actual: stored.sequence)
        }
        let filename = file.deletingPathExtension().lastPathComponent
        guard UInt64(filename) == stored.sequence else {
            throw ObservationStoreError.filenameSequenceMismatch(filename: file.lastPathComponent,
                                                                  sequence: stored.sequence)
        }
        guard stored.batch.provider == provider else {
            throw ObservationStoreError.storedProviderMismatch(sequence: stored.sequence)
        }
        try ObservationChangeBatchValidator.validate(stored.batch)
        return stored
    }

    private func batchFiles(for provider: String) throws -> [URL] {
        let directory = providerDirectory(for: provider)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func providerDirectory(for provider: String) -> URL {
        rootDirectory.appendingPathComponent("provider-" + Self.base64URL(provider), isDirectory: true)
    }

    private func validateProviderIdentifier(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ObservationStoreError.invalidProviderIdentifier
        }
    }

    private static func batchFilename(sequence: UInt64) -> String {
        let value = String(sequence)
        return String(repeating: "0", count: max(0, 20 - value.count)) + value + ".json"
    }

    private static func base64URL(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sortRecords(_ lhs: ObservationRecord, _ rhs: ObservationRecord) -> Bool {
        if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
        if lhs.endDate != rhs.endDate { return lhs.endDate < rhs.endDate }
        if lhs.metric.rawValue != rhs.metric.rawValue { return lhs.metric.rawValue < rhs.metric.rawValue }
        return lhs.id < rhs.id
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    private static func publishWithoutOverwrite(_ data: Data, to destination: URL) throws {
        let manager = FileManager.default
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temp) }
        try data.write(to: temp, options: [.atomic])
        do {
            try manager.moveItem(at: temp, to: destination)
        } catch {
            if manager.fileExists(atPath: destination.path),
               let sequence = UInt64(destination.deletingPathExtension().lastPathComponent) {
                throw ObservationStoreError.sequenceAlreadyExists(sequence)
            }
            throw error
        }
    }
}
