import XCTest
#if os(iOS)
@testable import NOOPiOS
#else
@testable import Strand
#endif

final class WorkoutRouteBackupTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "route-backup-\(UUID().uuidString)")! }

    func testRecordedAndLegacyRoutesRoundTripIntoFreshPreferences() throws {
        let source = defaults(), destination = defaults()
        let points = [WorkoutRoutePoint(lat: 51, lon: -0.1, accuracyM: 4, tMs: 1_800_000_000_013),
                      WorkoutRoutePoint(lat: 51.001, lon: -0.101, accuracyM: 5, tMs: 1_800_000_004_917)]
        let line = RouteMath.encode(points.map { RouteMath.LatLng($0.lat, $0.lon) })
        try RouteStore.storeAllChecked([
            (WorkoutRoute(polyline: line, distanceM: 120, points: points), 1_800_000_000, "Running"),
            (WorkoutRoute(polyline: line, distanceM: 120, points: nil), 1_800_001_000, "Walking")
        ], into: source)
        let data = try WorkoutRouteBackup.encode(WorkoutRouteBackup.capture(from: source))
        try WorkoutRouteBackup.apply(WorkoutRouteBackup.decode(data), to: destination)
        XCTAssertEqual(RouteStore.loadWithPoints(startTs: 1_800_000_000, sport: "Running", from: destination)?.points, points)
        XCTAssertNil(RouteStore.loadWithPoints(startTs: 1_800_001_000, sport: "Walking", from: destination)?.points)
    }

    func testInvalidPayloadDoesNotRemoveExistingRoutes() throws {
        let destination = defaults()
        destination.set(Data("previous".utf8), forKey: RouteStore.defaultsKey)
        let invalid = WorkoutRouteBackup.Snapshot(version: 99, routes: [:])
        XCTAssertThrowsError(try WorkoutRouteBackup.apply(invalid, to: destination))
        XCTAssertEqual(destination.data(forKey: RouteStore.defaultsKey), Data("previous".utf8))
    }

    func testLegacyBackupClearDoesNotAttachUnrelatedRoute() throws {
        let destination = defaults()
        destination.set(Data("previous".utf8), forKey: RoutePointStore.defaultsKey(for: "1800000000|Running"))
        try WorkoutRouteBackup.apply(.init(routes: [:]), to: destination)
        XCTAssertNil(destination.data(forKey: RoutePointStore.defaultsKey(for: "1800000000|Running")))
    }
}
