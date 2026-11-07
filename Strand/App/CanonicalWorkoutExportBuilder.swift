import Foundation
import StrandImport
import WhoopProtocol
import WhoopStore

/// Builds the one canonical, export-only representation of a completed NOOP workout.
///
/// This is intentionally a READ-ONLY seam. It consumes values already persisted by the workout,
/// raw-HR and GPS pipelines and derives only representation values that are deterministic from those
/// measurements (for example cumulative route distance). It never writes back to the workout, score,
/// BLE, HealthKit, GPS, recovery, strain, stress or sleep paths.
enum CanonicalWorkoutExportBuilder {
    private static let fitMaximumHeartRate = 254

    /// Build a FIT-ready canonical workout from the completed workout row plus the two time-series
    /// stores that already back the workout detail screen.
    ///
    /// Timing contract:
    ///   - elapsedDurationS = wall-clock end - start, so pauses remain represented in elapsed time;
    ///   - movingDurationS = the row's persisted duration when valid. Live NOOP workouts persist this
    ///     from ActiveWorkoutClock with pauses removed. If a source has no separate timer duration,
    ///     timer time deterministically equals elapsed time; no pause/resume interval is invented.
    static func build(
        row: WorkoutRow,
        deviceID: String,
        heartRateSamples rawHeartRate: [WhoopProtocol.HRSample],
        route storedRoute: WorkoutRoute?
    ) -> CanonicalWorkout? {
        guard row.startTs > 0, row.endTs > row.startTs else { return nil }

        let elapsed = Double(row.endTs - row.startTs)
        let timer = timerDuration(row.durationS, elapsed: elapsed)
        let hr = canonicalHeartRate(rawHeartRate, from: row.startTs, to: row.endTs,
                                    provenance: heartRateProvenance(row.source))
        // RouteStore is persisted data, so re-apply its complete integrity gate here rather than relying
        // on the UI's earlier visibility probe. A corrupt/legacy route is omitted wholesale; HR can still
        // make the workout exportable without laundering bad GPS into FIT.
        let routePoints = storedRoute?.hasExportableMeasurements == true
            ? (storedRoute?.points ?? []) : []
        let track = canonicalTrackPoints(routePoints,
                                         from: row.startTs, to: row.endTs,
                                         provenance: routeProvenance(row.source))

        // A completed file with no timed measurement records is not useful to Strava. Keep the builder
        // stricter than CanonicalFitExporter itself, which can still encode summary-only FIT for tests
        // and other callers.
        guard !hr.isEmpty || !track.isEmpty else { return nil }

        var workout = CanonicalWorkout(
            workoutRow: row,
            deviceID: deviceID,
            heartRateSamples: hr,
            route: track
        )

        workout.elapsedDurationS = elapsed
        workout.movingDurationS = timer

        // Keep the persisted workout summary when it is valid. For a local GPS workout this value was
        // written directly from capturedRoute().distanceM. Fall back to that measured route total only
        // when the row has no usable distance.
        if let rowDistance = finiteNonnegative(row.distanceM) {
            workout.distanceM = rowDistance
        } else if let routeDistance = finiteNonnegative(storedRoute?.distanceM), !track.isEmpty {
            workout.distanceM = routeDistance
            workout.provenance[.distance] = CanonicalWorkout.Provenance(
                source: routeProvenance(row.source).source,
                status: routeProvenance(row.source).status,
                detail: "persisted route distance"
            )
        } else {
            workout.distanceM = nil
        }

        // The FIT summary must describe the exact HR records in the same file. Once a real time series
        // exists, calculate avg/max from that stream instead of trusting a possibly stale row summary.
        if !hr.isEmpty {
            let bpms = hr.map(\.bpm)
            workout.averageHeartRate = Int(
                (Double(bpms.reduce(0, +)) / Double(bpms.count)).rounded()
            )
            workout.maximumHeartRate = bpms.max()
            workout.provenance[.heartRateSummary] = CanonicalWorkout.Provenance(
                source: heartRateProvenance(row.source).source,
                status: .derived,
                detail: "derived from exported HR records"
            )
        } else {
            workout.averageHeartRate = validFitHeartRate(row.avgHr)
            workout.maximumHeartRate = validFitHeartRate(row.maxHr)
        }

        if let energy = finiteNonnegative(row.energyKcal) {
            workout.energyKcal = energy
        } else {
            workout.energyKcal = nil
        }

        let timingSource = CanonicalWorkout.storedSource(row.source).source
        workout.provenance[.timing] = .init(
            source: timingSource,
            status: CanonicalWorkout.storedSource(row.source).status ?? .manual,
            detail: "WorkoutRow startTs/endTs"
        )
        workout.provenance[.duration] = .init(
            source: timingSource,
            status: row.durationS == nil ? .derived : (CanonicalWorkout.storedSource(row.source).status ?? .manual),
            detail: row.durationS == nil ? "timer time equals elapsed time; no separate timer duration persisted"
                                         : "WorkoutRow durationS"
        )
        if !hr.isEmpty {
            workout.provenance[.heartRateSamples] = heartRateProvenance(row.source)
        }
        if !track.isEmpty {
            workout.provenance[.route] = routeProvenance(row.source)
        }
        return workout
    }

    /// Canonical route-only workout used by the existing Shortcuts route export. FIT goes through the
    /// same CanonicalFitExporter as the full workout UI, while GPX remains on RouteExporter.
    static func buildRouteOnly(
        startTs: Int,
        endTs: Int,
        sport: String,
        distanceM: Double?,
        points: [WorkoutRoutePoint]
    ) -> CanonicalWorkout? {
        guard startTs > 0, endTs > startTs else { return nil }
        let provenance = CanonicalWorkout.Provenance(source: .coreLocation, status: .measured,
                                                     detail: "persisted RouteStore point")
        let track = canonicalTrackPoints(points, from: startTs, to: endTs, provenance: provenance)
        guard !track.isEmpty else { return nil }

        return CanonicalWorkout(
            stableID: "route-\(startTs)-\(stableSportToken(sport))",
            source: .coreLocation,
            sport: sport,
            startTimestamp: startTs,
            endTimestamp: endTs,
            elapsedDurationS: Double(endTs - startTs),
            movingDurationS: Double(endTs - startTs),
            distanceM: finiteNonnegative(distanceM),
            route: track,
            provenance: [
                .identity: provenance,
                .sport: provenance,
                .timing: provenance,
                .duration: provenance,
                .distance: provenance,
                .route: provenance,
            ]
        )
    }

    /// Stable, filesystem-safe user-facing filename. UTC keeps repeat exports byte/name deterministic
    /// even if the phone later travels to another time zone.
    static func fitFilename(sport: String, startTimestamp: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let stamp = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(startTimestamp)))
        return "NOOP-\(filenameSportToken(sport))-\(stamp).fit"
    }

    // MARK: - Representation helpers

    private static func canonicalHeartRate(
        _ samples: [WhoopProtocol.HRSample],
        from startTs: Int,
        to endTs: Int,
        provenance: CanonicalWorkout.Provenance
    ) -> [CanonicalWorkout.HRSample] {
        // Preserve the source resolver's precedence by taking the first value for a duplicate second.
        // Then sort by timestamp for deterministic FIT records.
        var firstByTimestamp: [Int: Int] = [:]
        for sample in samples {
            guard sample.ts >= startTs, sample.ts <= endTs,
                  (1...fitMaximumHeartRate).contains(sample.bpm),
                  firstByTimestamp[sample.ts] == nil else { continue }
            firstByTimestamp[sample.ts] = sample.bpm
        }
        return firstByTimestamp.keys.sorted().compactMap { ts in
            firstByTimestamp[ts].map {
                CanonicalWorkout.HRSample(timestamp: ts, bpm: $0, provenance: provenance)
            }
        }
    }

    /// Convert persisted millisecond GPS fixes to FIT's one-second timestamp resolution without
    /// interpolating anything. Multiple real fixes in one FIT second collapse to the latest fix in that
    /// second; cumulative distance still walks every retained fix before the collapse.
    private static func canonicalTrackPoints(
        _ points: [WorkoutRoutePoint],
        from startTs: Int,
        to endTs: Int,
        provenance: CanonicalWorkout.Provenance
    ) -> [CanonicalWorkout.TrackPoint] {
        let valid = points.filter { point in
            let second = Int(point.tMs / 1_000)
            return point.tMs > 0
                && point.lat.isFinite && (-90...90).contains(point.lat)
                && point.lon.isFinite && (-180...180).contains(point.lon)
                && point.accuracyM.isFinite && point.accuracyM >= 0
                && second >= startTs && second <= endTs
        }
        guard !valid.isEmpty else { return [] }

        var cumulative = 0.0
        var previous: WorkoutRoutePoint?
        var bySecond: [Int: CanonicalWorkout.TrackPoint] = [:]

        for point in valid {
            if let previous {
                cumulative += RouteMath.haversineMeters(
                    RouteMath.LatLng(previous.lat, previous.lon),
                    RouteMath.LatLng(point.lat, point.lon)
                )
            }
            let second = Int(point.tMs / 1_000)
            bySecond[second] = CanonicalWorkout.TrackPoint(
                timestamp: second,
                latitude: point.lat,
                longitude: point.lon,
                altitudeM: nil,          // altitude is not persisted by WorkoutRoutePoint
                distanceM: cumulative,
                speedMps: nil,           // no stored speed; do not fabricate it
                heartRateBpm: nil,       // merged from the canonical HR stream by the FIT exporter
                cadenceRpm: nil,
                powerWatts: nil,
                provenance: provenance
            )
            previous = point
        }
        return bySecond.keys.sorted().compactMap { bySecond[$0] }
    }

    private static func timerDuration(_ stored: Double?, elapsed: Double) -> Double {
        guard elapsed.isFinite, elapsed >= 0 else { return 0 }
        guard let stored, stored.isFinite, stored >= 0 else { return elapsed }
        // Integer persisted start/end timestamps can differ from the original Date interval by under
        // one second. Clamp only that representational edge; grossly invalid durations fall back to the
        // wall-clock interval instead of writing contradictory FIT summaries.
        guard stored <= elapsed + 1 else { return elapsed }
        return min(stored, elapsed)
    }

    private static func finiteNonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func validFitHeartRate(_ value: Int?) -> Int? {
        guard let value, (1...fitMaximumHeartRate).contains(value) else { return nil }
        return value
    }

    private static func heartRateProvenance(_ rawSource: String) -> CanonicalWorkout.Provenance {
        switch CanonicalWorkout.storedSource(rawSource).source {
        case .activityFile:
            return .init(source: .activityFile, status: .imported)
        case .appleHealth:
            return .init(source: .appleHealth, status: .imported)
        case .whoopImport:
            return .init(source: .whoopImport, status: .imported)
        default:
            return .init(source: .whoopBLE, status: .measured)
        }
    }

    private static func routeProvenance(_ rawSource: String) -> CanonicalWorkout.Provenance {
        switch CanonicalWorkout.storedSource(rawSource).source {
        case .activityFile:
            return .init(source: .activityFile, status: .imported)
        case .appleHealth:
            return .init(source: .appleHealth, status: .imported)
        default:
            return .init(source: .coreLocation, status: .measured)
        }
    }

    private static func filenameSportToken(_ sport: String) -> String {
        let cleaned = sport.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let token = String(cleaned)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return token.isEmpty ? "Activity" : token
    }

    private static func stableSportToken(_ sport: String) -> String {
        filenameSportToken(sport).lowercased()
    }
}
