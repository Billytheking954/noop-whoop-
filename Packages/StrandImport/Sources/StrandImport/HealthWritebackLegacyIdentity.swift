import Foundation

public extension HealthWriteback {
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
