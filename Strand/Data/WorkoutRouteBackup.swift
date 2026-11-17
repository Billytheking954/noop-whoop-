import Foundation
import WhoopStore

/// Versioned Apple route payload. Database backups carry it separately because route fixes
/// live in UserDefaults; it never changes the cross-platform settings whitelist.
enum WorkoutRouteBackup {
    static let entryName = "workout-routes.json"
    static let maximumBytes: Int64 = 128 * 1024 * 1024

    struct Snapshot: Codable, Equatable {
        var version = 1
        var routes: [String: WorkoutRoute]
    }

    static func capture(from defaults: UserDefaults = .standard) throws -> Snapshot {
        RouteStore.storageLock.lock()
        defer { RouteStore.storageLock.unlock() }
        let values = defaults.dictionaryRepresentation()
        var routes: [String: WorkoutRoute] = [:]
        if let raw = values[RouteStore.defaultsKey] {
            guard let data = raw as? Data else { throw CocoaError(.fileReadCorruptFile) }
            routes = try JSONDecoder().decode([String: WorkoutRoute].self, from: data)
        }
        for key in routes.keys {
            if let raw = values[RoutePointStore.defaultsKey(for: key)] {
                guard let data = raw as? Data else { throw CocoaError(.fileReadCorruptFile) }
                routes[key]?.points = try JSONDecoder().decode([WorkoutRoutePoint].self, from: data)
            }
        }
        let snapshot = Snapshot(routes: routes)
        try validate(snapshot)
        return snapshot
    }

    static func encode(_ snapshot: Snapshot) throws -> Data {
        try validate(snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    static func decode(_ data: Data) throws -> Snapshot {
        guard Int64(data.count) <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        try validate(snapshot)
        return snapshot
    }

    private static func validate(_ snapshot: Snapshot) throws {
        guard snapshot.version == 1, snapshot.routes.count <= RouteStore.maxRoutes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for (key, route) in snapshot.routes {
            let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let start = Int(parts[0]), start > 0, !parts[1].isEmpty,
                  route.distanceM.isFinite, route.distanceM >= 0,
                  RouteMath.decode(route.polyline).count >= 2 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if route.points != nil, !route.hasExportableMeasurements {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
    }

    /// Called only after a validated database replacement. A missing legacy payload is
    /// represented by an empty snapshot, preventing unrelated old routes attaching to restored rows.
    static func apply(_ snapshot: Snapshot, to defaults: UserDefaults = .standard) throws {
        _ = try encode(snapshot)
        var light: [String: WorkoutRoute] = [:]
        var pointData: [String: Data] = [:]
        for (key, route) in snapshot.routes {
            var item = route
            item.points = nil
            light[key] = item
            if let points = route.points { pointData[key] = try JSONEncoder().encode(points) }
        }
        let mapData = try JSONEncoder().encode(light)
        RouteStore.storageLock.lock()
        defer { RouteStore.storageLock.unlock() }
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("noop.workoutRoutePoints.") || key == RouteStore.defaultsKey {
            defaults.removeObject(forKey: key)
        }
        for (key, data) in pointData {
            defaults.set(data, forKey: RoutePointStore.defaultsKey(for: key))
        }
        defaults.set(mapData, forKey: RouteStore.defaultsKey)
    }
}
