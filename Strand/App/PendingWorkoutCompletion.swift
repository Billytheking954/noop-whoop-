import Foundation
import WhoopStore

/// Durable, idempotent completion queue. A stopped workout stays here until both its
/// database row and recorded route have been saved; a process kill or I/O error is retryable.
enum PendingWorkoutCompletion {
    struct Entry: Codable, Equatable {
        let deviceID: String
        let row: WorkoutRow
        let route: WorkoutRoute?

        var key: String { "\(deviceID)|\(row.startTs)|\(row.sport)" }
    }

    private static let lock = NSRecursiveLock()

    static func defaultURL() throws -> URL {
        URL(fileURLWithPath: try StorePaths.defaultDatabasePath())
            .deletingLastPathComponent().appendingPathComponent("pending-workout-completions.json")
    }

    static func load(at url: URL) throws -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
    }

    static func enqueue(_ entry: Entry, at url: URL) throws {
        try StoreWriteBarrier.withWritePermit {
            lock.lock()
            defer { lock.unlock() }
            var entries = try load(at: url)
            entries.removeAll { $0.key == entry.key }
            entries.append(entry)
            try write(entries, to: url)
        }
    }

    private static func write(_ entries: [Entry], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }

    private static func acknowledge(_ entry: Entry, at url: URL) throws {
        try StoreWriteBarrier.withWritePermit {
            lock.lock()
            defer { lock.unlock() }
            var entries = try load(at: url)
            entries.removeAll { $0.key == entry.key && $0 == entry }
            try write(entries, to: url)
        }
    }

    /// The caller serializes drains. Failure leaves the entry intact, including its original stop time.
    @MainActor
    static func drain(at url: URL, persist: (Entry) async throws -> Void) async throws {
        while let entry = try load(at: url).first {
            try await persist(entry)
            try acknowledge(entry, at: url)
        }
    }
}
