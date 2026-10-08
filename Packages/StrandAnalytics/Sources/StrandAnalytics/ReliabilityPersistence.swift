import Foundation

/// Small atomic JSON store used for crash-safe reliability state. It is intentionally independent of
/// SwiftUI and BLE so session state can be restored before either subsystem has finished reconnecting.
public actor ActiveSessionPersistence {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) { self.url = url }

    public func save(_ snapshot: ActiveSessionSnapshot) throws {
        let data = try encoder.encode(snapshot)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    public func load() throws -> ActiveSessionSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(ActiveSessionSnapshot.self, from: Data(contentsOf: url))
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

public struct ActivityCorrection: Equatable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let candidateStartSec: Int
    public let candidateEndSec: Int
    public let correctedType: String?
    public let acceptedAsActivity: Bool
    public let recordedAtSec: Int

    public init(id: UUID = UUID(), candidateStartSec: Int, candidateEndSec: Int,
                correctedType: String?, acceptedAsActivity: Bool, recordedAtSec: Int) {
        self.id = id
        self.candidateStartSec = candidateStartSec
        self.candidateEndSec = candidateEndSec
        self.correctedType = correctedType
        self.acceptedAsActivity = acceptedAsActivity
        self.recordedAtSec = recordedAtSec
    }
}

/// Append-only local correction history. Corrections are evidence for future classifier evaluation;
/// they do not rewrite old candidates or silently retrain production behaviour.
public actor ActivityCorrectionStore {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) { self.url = url }

    public func all() throws -> [ActivityCorrection] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try decoder.decode([ActivityCorrection].self, from: Data(contentsOf: url))
    }

    public func append(_ correction: ActivityCorrection) throws {
        var rows = try all()
        guard !rows.contains(where: { $0.id == correction.id }) else { return }
        rows.append(correction)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try encoder.encode(rows).write(to: url, options: [.atomic])
    }
}

public struct PersistedMetricProvenance: Equatable, Codable, Sendable, Identifiable {
    public var id: String { "\(metricKey):\(periodStartSec)" }
    public let metricKey: String
    public let periodStartSec: Int
    public let provenance: DerivedMetricProvenance

    public init(metricKey: String, periodStartSec: Int, provenance: DerivedMetricProvenance) {
        self.metricKey = metricKey
        self.periodStartSec = periodStartSec
        self.provenance = provenance
    }
}

/// Sidecar provenance store. This deliberately does not recalculate historical scores. A future
/// scoring migration must write a new algorithm version intentionally rather than mutating old rows.
public actor MetricProvenanceStore {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) { self.url = url }

    public func all() throws -> [PersistedMetricProvenance] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try decoder.decode([PersistedMetricProvenance].self, from: Data(contentsOf: url))
    }

    public func upsert(_ row: PersistedMetricProvenance) throws {
        var rows = try all()
        if let i = rows.firstIndex(where: { $0.id == row.id }) {
            // Preserve explicit history semantics: callers can intentionally replace provenance for the
            // same metric period, but no background process performs this operation automatically.
            rows[i] = row
        } else {
            rows.append(row)
        }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try encoder.encode(rows).write(to: url, options: [.atomic])
    }
}
