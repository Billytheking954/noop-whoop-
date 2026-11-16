import Foundation
import WhoopStore

public extension CanonicalWorkout {
    /// Honest interpretation of the persisted workout `source` column.
    ///
    /// `manual` is intentionally returned without a measured/derived status: the current store uses that
    /// same token for both a live app-recorded session and a retro/manual entry, so the row alone cannot
    /// prove how each metric was obtained. Callers with richer capture context may add field provenance.
    static func storedSource(_ raw: String) -> (source: DataSource, status: ValueStatus?) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix("-noop") { return (.legacyDetected, .derived) }
        switch value {
        case "whoop":
            return (.whoopImport, .imported)
        case "apple-health", "apple_health":
            return (.appleHealth, .imported)
        case "lifting":
            return (.lifting, .imported)
        case "activity-file":
            return (.activityFile, .imported)
        case "manual":
            return (.manual, nil)
        default:
            if value.contains("whoop") { return (.whoopImport, .imported) }
            return (.unknown, nil)
        }
    }

    /// Loss-aware adapter from the real `WhoopStore.WorkoutRow` read model into the canonical seam.
    ///
    /// `deviceID` is supplied by the caller because `WorkoutRow` deliberately carries no device id; the
    /// store's natural key is `(deviceId, startTs, sport)`. Optional time-series/route data is accepted
    /// separately because it lives outside the workout row and must not be invented from summary values.
    init(workoutRow row: WorkoutRow,
         deviceID: String,
         heartRateSamples: [HRSample] = [],
         route: [TrackPoint] = [],
         timeZoneIdentifier: String? = nil,
         recordingCoverage: Double? = nil) {
        let classified = Self.storedSource(row.source)
        var fieldProvenance: [Field: Provenance] = [:]
        if let status = classified.status {
            let p = Provenance(source: classified.source, status: status, detail: "workout.source=\(row.source)")
            fieldProvenance[.identity] = p
            fieldProvenance[.sport] = p
            fieldProvenance[.timing] = p
            if row.durationS != nil { fieldProvenance[.duration] = p }
            if row.avgHr != nil || row.maxHr != nil { fieldProvenance[.heartRateSummary] = p }
            if row.distanceM != nil { fieldProvenance[.distance] = p }
            if row.energyKcal != nil { fieldProvenance[.energy] = p }
            if row.strain != nil { fieldProvenance[.strain] = p }
        }

        self.init(
            stableID: Self.persistedStableID(deviceID: deviceID,
                                             startTimestamp: row.startTs,
                                             sport: row.sport),
            source: classified.source,
            sport: row.sport,
            startTimestamp: row.startTs,
            endTimestamp: row.endTs,
            timeZoneIdentifier: timeZoneIdentifier,
            elapsedDurationS: row.durationS,
            movingDurationS: nil,
            heartRateSamples: heartRateSamples,
            averageHeartRate: row.avgHr,
            maximumHeartRate: row.maxHr,
            distanceM: row.distanceM,
            energyKcal: row.energyKcal,
            route: route,
            ascentM: nil,
            descentM: nil,
            averageCadenceRpm: nil,
            averagePowerWatts: nil,
            laps: [],
            strain: row.strain,
            proprietaryMetrics: [:],
            recordingCoverage: recordingCoverage,
            provenance: fieldProvenance
        )
    }
}
