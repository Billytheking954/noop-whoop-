import XCTest
import Foundation
import WhoopProtocol
import WhoopStore
@testable import Strand

final class CanonicalWorkoutExportBuilderTests: XCTestCase {

    func testBuildPreservesElapsedVersusPausedTimerAndFullHR() throws {
        let start = 1_723_000_000
        let row = WorkoutRow(
            startTs: start,
            endTs: start + 1_800,
            sport: "Running",
            source: "manual",
            durationS: 1_680,
            energyKcal: 280,
            avgHr: 99,       // deliberately stale; exported summary must follow the real series
            maxHr: 100,
            strain: 12.3,
            distanceM: 1_000,
            zonesJSON: nil,
            notes: nil,
            steps: nil
        )
        let gps = [
            WorkoutRoutePoint(lat: 51.5000, lon: -0.1200, accuracyM: 4, tMs: Int64(start) * 1_000 + 100),
            WorkoutRoutePoint(lat: 51.5001, lon: -0.1201, accuracyM: 4, tMs: Int64(start) * 1_000 + 900),
            WorkoutRoutePoint(lat: 51.5010, lon: -0.1190, accuracyM: 5, tMs: Int64(start + 60) * 1_000 + 250),
        ]
        let route = WorkoutRoute(
            polyline: RouteMath.encode(gps.map { RouteMath.LatLng($0.lat, $0.lon) }),
            distanceM: 1_000,
            points: gps
        )
        let hr = [
            HRSample(ts: start - 1, bpm: 130),        // outside workout
            HRSample(ts: start + 1, bpm: 141),
            HRSample(ts: start + 1, bpm: 199),        // duplicate second; first source value wins
            HRSample(ts: start + 2, bpm: 143),
            HRSample(ts: start + 3, bpm: 255),        // FIT uint8 invalid sentinel range
            HRSample(ts: start + 4, bpm: 145),
            HRSample(ts: start + 1_801, bpm: 150),    // outside workout
        ]

        let workout = try XCTUnwrap(CanonicalWorkoutExportBuilder.build(
            row: row,
            deviceID: "whoop-test",
            heartRateSamples: hr,
            route: route
        ))

        XCTAssertEqual(workout.startTimestamp, start)
        XCTAssertEqual(workout.endTimestamp, start + 1_800)
        XCTAssertEqual(workout.elapsedDurationS, 1_800)
        XCTAssertEqual(workout.movingDurationS, 1_680,
                       "persisted active duration excludes the two paused minutes")
        XCTAssertEqual(workout.heartRateSamples.map(\.timestamp), [start + 1, start + 2, start + 4])
        XCTAssertEqual(workout.heartRateSamples.map(\.bpm), [141, 143, 145])
        XCTAssertEqual(workout.averageHeartRate, 143)
        XCTAssertEqual(workout.maximumHeartRate, 145)
        XCTAssertEqual(workout.energyKcal, 280)
        XCTAssertEqual(workout.distanceM, 1_000)

        // FIT has one-second timestamps. Both first GPS fixes really happened in the start second, so the
        // latest one represents that second; the next real second is preserved exactly. No interpolation.
        XCTAssertEqual(workout.route.map(\.timestamp), [start, start + 60])
        XCTAssertEqual(workout.route.first?.latitude, gps[1].lat)
        XCTAssertEqual(workout.route.first?.longitude, gps[1].lon)
        XCTAssertNil(workout.route.first?.altitudeM)
        XCTAssertNil(workout.route.first?.speedMps)
        XCTAssertNil(workout.route.first?.cadenceRpm)
        XCTAssertNil(workout.route.first?.powerWatts)
        XCTAssertGreaterThan(workout.route.last?.distanceM ?? 0, 0)
    }

    func testMissingSeparateTimerDurationFallsBackToElapsedWithoutInventingPauseEvents() throws {
        let start = 1_723_010_000
        let row = WorkoutRow(
            startTs: start, endTs: start + 300,
            sport: "Strength Training", source: "manual", durationS: nil,
            energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
            distanceM: nil, zonesJSON: nil, notes: nil, steps: nil
        )
        let workout = try XCTUnwrap(CanonicalWorkoutExportBuilder.build(
            row: row,
            deviceID: "whoop-test",
            heartRateSamples: [HRSample(ts: start + 10, bpm: 132)],
            route: nil
        ))
        XCTAssertEqual(workout.elapsedDurationS, 300)
        XCTAssertEqual(workout.movingDurationS, 300)
        XCTAssertTrue(workout.route.isEmpty)
    }

    func testCorruptRouteIsOmittedWhileValidHRStillExports() throws {
        let start = 1_723_020_000
        let row = WorkoutRow(
            startTs: start, endTs: start + 120,
            sport: "Running", source: "manual", durationS: 120,
            energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
            distanceM: 500, zonesJSON: nil, notes: nil, steps: nil
        )
        let corrupt = WorkoutRoute(
            polyline: "abc",
            distanceM: 500,
            points: [
                WorkoutRoutePoint(lat: 51, lon: -0.1, accuracyM: 4, tMs: Int64(start + 10) * 1_000),
                WorkoutRoutePoint(lat: 51.1, lon: -0.2, accuracyM: 4, tMs: Int64(start + 9) * 1_000),
            ]
        )
        XCTAssertFalse(corrupt.hasExportableMeasurements)

        let workout = try XCTUnwrap(CanonicalWorkoutExportBuilder.build(
            row: row,
            deviceID: "whoop-test",
            heartRateSamples: [HRSample(ts: start + 30, bpm: 150)],
            route: corrupt
        ))
        XCTAssertTrue(workout.route.isEmpty)
        XCTAssertEqual(workout.heartRateSamples.count, 1)
    }

    func testEmptyOrInvalidCompletedWorkoutFailsSafely() {
        let start = 1_723_030_000
        let empty = WorkoutRow(
            startTs: start, endTs: start + 60,
            sport: "Running", source: "manual", durationS: 60,
            energyKcal: nil, avgHr: 140, maxHr: 150, strain: nil,
            distanceM: nil, zonesJSON: nil, notes: nil, steps: nil
        )
        XCTAssertNil(CanonicalWorkoutExportBuilder.build(
            row: empty, deviceID: "whoop-test", heartRateSamples: [], route: nil
        ))

        let badWindow = WorkoutRow(
            startTs: start, endTs: start,
            sport: "Running", source: "manual", durationS: 0,
            energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
            distanceM: nil, zonesJSON: nil, notes: nil, steps: nil
        )
        XCTAssertNil(CanonicalWorkoutExportBuilder.build(
            row: badWindow,
            deviceID: "whoop-test",
            heartRateSamples: [HRSample(ts: start, bpm: 140)],
            route: nil
        ))
    }

    func testFilenameIsStableSafeAndUTC() {
        XCTAssertEqual(
            CanonicalWorkoutExportBuilder.fitFilename(
                sport: "Trail / Run", startTimestamp: 1_723_000_000),
            "NOOP-Trail-Run-2024-08-07-0306.fit"
        )
        XCTAssertEqual(
            CanonicalWorkoutExportBuilder.fitFilename(
                sport: "Trail / Run", startTimestamp: 1_723_000_000),
            CanonicalWorkoutExportBuilder.fitFilename(
                sport: "Trail / Run", startTimestamp: 1_723_000_000)
        )
    }

    func testRouteOnlyIntentBuilderUsesTruePersistedTimestamps() throws {
        let start = 1_723_040_000
        let points = [
            WorkoutRoutePoint(lat: 51.5, lon: -0.12, accuracyM: 4,
                              tMs: Int64(start) * 1_000 + 400),
            WorkoutRoutePoint(lat: 51.501, lon: -0.119, accuracyM: 5,
                              tMs: Int64(start + 17) * 1_000 + 900),
        ]
        let workout = try XCTUnwrap(CanonicalWorkoutExportBuilder.buildRouteOnly(
            startTs: start,
            endTs: start + 17,
            sport: "Running",
            distanceM: 160,
            points: points
        ))
        XCTAssertEqual(workout.route.compactMap(\.timestamp), [start, start + 17])
        XCTAssertEqual(workout.distanceM, 160)
        XCTAssertTrue(workout.heartRateSamples.isEmpty)
    }
}
