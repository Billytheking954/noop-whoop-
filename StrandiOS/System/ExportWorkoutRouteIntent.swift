#if os(iOS)
import Foundation
import AppIntents
import StrandImport
import UniformTypeIdentifiers

// MARK: - Export a recorded GPS route through Shortcuts (#2679)
//
// Route export already ships as a share sheet on the workout detail screen (`WorkoutDetailView`'s
// "GPX - Strava, Garmin, most apps"), and the same file is what Strava, Garmin Connect and the rest
// read back as a timed activity. What it could not do was run unattended: every workout needed the
// sheet opened by hand.
//
// This exposes the SAME renderer to Shortcuts, so an automation can take the file and hand it to
// whichever app the wearer already uses. NOOP gains no account, no credential and no network call:
// the file leaves only when the wearer's own automation moves it, exactly like the share sheet.
// Issue #2679 records why a direct Strava API client is a separate scope decision rather than this.
//
// It reads `RouteStore` (the UserDefaults side-store, since `WorkoutRow` has no route column on
// Apple) rather than the database, so it needs no store handle and cannot contend with a running
// sync. An App Intent declared in the app target runs in NOOP's own process, so the plain
// `UserDefaults` suite `RouteStore` writes is readable here.

/// Why an export can fail. Only one case: a route either carries the per-point measurements an
/// honest export needs, or it does not. Conforms to `CustomLocalizedStringResourceConvertible` so
/// Shortcuts shows the reason instead of a generic failure.
enum RouteExportIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case noExportableRoute

    var localizedStringResource: LocalizedStringResource {
        "NOOP has no recorded route with GPS measurements to export yet."
    }
}

/// The file format a route export produces. Mirrors `RouteExporter.Format` as a Shortcuts-visible
/// enum; kept separate because `AppEnum` conformance belongs to the iOS layer, not the pure package.
/// `CaseIterable` is spelled out rather than left to `AppEnum`'s refinement, so `allCases` is
/// synthesised explicitly instead of depending on conformance inference.
enum RouteExportFormatChoice: String, AppEnum, CaseIterable {
    case gpx
    case fit

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Route Format")

    // FIT carries a session summary that GPX has no element for, and the parts of it this path cannot
    // supply are named here rather than left for a wearer to discover in Strava. See the `render` call.
    static var caseDisplayRepresentations: [RouteExportFormatChoice: DisplayRepresentation] = [
        .gpx: DisplayRepresentation(title: "GPX", subtitle: "Recorded GPS positions and timestamps"),
        .fit: DisplayRepresentation(title: "FIT", subtitle: "Recorded GPS timestamps; no invented heart-rate samples"),
    ]

    var exporterFormat: RouteExporter.Format { self == .gpx ? .gpx : .fit }
}

/// Return the most recently recorded GPS route as a GPX or FIT file.
///
/// Only a route carrying trustworthy per-point measurements is exported. `WorkoutRoute`'s own
/// `hasExportableMeasurements` is the gate, and its contract is explicit that a legacy route without
/// point metadata "remain[s] drawable from [its] polyline but must never be exported with guessed
/// values" — so a route saved before that field existed is reported as unavailable rather than
/// shipped with an invented timeline.
struct ExportWorkoutRouteIntent: AppIntent {
    static var title: LocalizedStringResource = "Export Workout Route"
    static var description = IntentDescription(
        "Get the most recent recorded GPS route as a GPX or FIT file, ready to hand to Strava, Garmin Connect, or any other app.")
    /// No app UI is needed: the file is built from the on-device side-store and returned.
    static var openAppWhenRun = false

    @Parameter(title: "Format", default: .gpx)
    var format: RouteExportFormatChoice

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        guard let newest = Self.newestExportableRoute() else {
            // A real thrown error, not a parameter-resolution prompt: the format is already valid, it
            // is the data that is missing, and Shortcuts should surface that as a failed step rather
            // than asking the wearer to pick GPX again.
            throw RouteExportIntentError.noExportableRoute
        }
        // `energyKcal`, `avgHr` and `maxHr` are deliberately NOT passed, and GPX is unaffected either
        // way: `buildGpx` takes none of them, so a GPX from here is byte-identical to the share sheet's.
        // FIT does carry them as session fields, and the share sheet supplies them from the `WorkoutRow`.
        // This path has no row, and copying them into `RouteStore` to get them would plant a second copy
        // of a fact the database owns: the edit and merge paths re-store a route without touching them,
        // and a later offload fills heart rate for a window after the route was saved. A stored snapshot
        // would then disagree with the workout, which is the failure the project forbids outright. So the
        // FIT written here is a route plus its GPS distance, and the format picker says so.
        let data: Data
        switch format {
        case .fit:
            // The canonical encoder records only genuine timestamped fixes. A
            // route's display polyline is never enough to invent a FIT track.
            guard let canonical = CanonicalWorkoutExportBuilder.buildRouteOnly(
                startTs: newest.startTs, endTs: newest.endTs, sport: newest.sport,
                distanceM: newest.distanceM, points: newest.points
            ) else { throw RouteExportIntentError.noExportableRoute }
            let encoded = CanonicalFitExporter.render(canonical)
            guard encoded.stravaUploadReady else { throw RouteExportIntentError.noExportableRoute }
            data = encoded.data
        case .gpx:
            // Shortcuts only selects routes with real measured point metadata.
            // Preserve the actual timestamps rather than interpolate a false pace.
            let fixes = newest.points.map {
                RouteExporter.RecordedGpxPoint(lat: $0.lat, lon: $0.lon, timestampMs: $0.tMs)
            }
            guard let encoded = RouteExporter.buildGpxRecorded(route: fixes, sport: newest.sport)
            else { throw RouteExportIntentError.noExportableRoute }
            data = encoded
        }
        // Named by the workout's start, matching the share sheet's `noop-route-<startTs>.<ext>` so the
        // same session exports to the same filename whichever path produced it.
        let name = "noop-route-\(newest.startTs).\(format.rawValue)"
        // `.data` rather than a guessed media type: GPX and FIT have no system `UTType`, and the
        // receiving app keys off the extension. Declaring something more specific would be asserting
        // a type the system does not actually know.
        return .result(value: IntentFile(data: data, filename: name, type: .data),
                       dialog: "Exported your most recent route.")
    }

    /// One exportable route, resolved from the side-store without touching the database.
    struct Resolved {
        let startTs: Int
        let endTs: Int
        let sport: String
        let distanceM: Double
        let points: [WorkoutRoutePoint]
    }

    /// The newest route that carries exportable measurements, or nil when none does.
    ///
    /// `RouteStore`'s keys are "<startTs>|<sport>", so the greatest leading `startTs` is the most
    /// recent session without reading a workout row. `endTs` comes from the last point's own `tMs`
    /// rather than being assumed, which is why only routes with point metadata qualify.
    static func newestExportableRoute(from map: [String: WorkoutRoute]? = nil) -> Resolved? {
        let routes = map ?? RouteStore.loadMap()
        var candidates: [(key: String, startTs: Int, sport: String)] = []
        for key in routes.keys {
            guard let parsed = parseKey(key) else { continue }
            candidates.append((key, parsed.startTs, parsed.sport))
        }
        candidates.sort { lhs, rhs in
            if lhs.startTs == rhs.startTs { return lhs.key < rhs.key }
            return lhs.startTs > rhs.startTs
        }
        for candidate in candidates {
            guard var route = routes[candidate.key] else { continue }
            if route.points == nil, map == nil {
                route.points = RoutePointStore.load(for: candidate.key)
            }
            guard route.hasExportableMeasurements,
                  let points = route.points, let last = points.last else { continue }
            let endTs = Int(last.tMs / 1_000)
            guard endTs > candidate.startTs else { continue }
            return Resolved(startTs: candidate.startTs, endTs: endTs, sport: candidate.sport,
                            distanceM: route.distanceM, points: points)
        }
        return nil
    }

    /// Split a `RouteStore` key back into its parts. A sport may itself contain "|" in principle, so
    /// the split is bounded to the FIRST separator and the remainder is the sport, matching how
    /// `RouteStore.key(startTs:sport:)` composes it.
    static func parseKey(_ key: String) -> (startTs: Int, sport: String)? {
        let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let startTs = Int(parts[0]), !parts[1].isEmpty else { return nil }
        return (startTs, String(parts[1]))
    }
}
#endif
