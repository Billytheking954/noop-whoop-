import Foundation

public extension HealthWriteback {
    /// Only current, minute-bucket HR records written by NOOP are eligible for replacement.
    /// Source alone is insufficient: older and unrelated app-authored HR samples can coexist.
    static func isCurrentHeartRateKey(_ key: String) -> Bool {
        let prefix = "noop:heart-rate:"
        guard key.hasPrefix(prefix) else { return false }
        let identity = key.dropFirst(prefix.count)
        return !identity.isEmpty && identity.utf8.allSatisfy { (48...57).contains($0) }
    }

    /// Match the current timestamp-keyed workout scheme, excluding any future key formats.
    static func isCurrentWorkoutKey(_ key: String) -> Bool {
        let prefix = appleHealthWorkoutKeyPrefix
        guard key.hasPrefix(prefix) else { return false }
        let identity = key.dropFirst(prefix.count)
        return !identity.isEmpty && identity.utf8.allSatisfy { (48...57).contains($0) }
    }

    /// True only for the retired device-scoped key shape:
    /// `noop:<deviceId>:<kind>:<identity>`.
    ///
    /// Current keys are `noop:<kind>:<identity>`. The check is intentionally structural rather than
    /// matching one remembered device id, because a re-pair is exactly what made the historical id
    /// unreachable. HealthKit cleanup combines this with `HKSource.default()` before retiring objects.
    static func isLegacyDeviceScopedAppleHealthKey(_ key: String) -> Bool {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts.first == "noop" else { return false }
        // New identifiers currently have exactly three colon-delimited components. Require all of the
        // legacy structural slots to be non-empty so malformed metadata is never swept accidentally.
        return !parts[1].isEmpty && !parts[2].isEmpty && !parts[3].isEmpty
    }
}
