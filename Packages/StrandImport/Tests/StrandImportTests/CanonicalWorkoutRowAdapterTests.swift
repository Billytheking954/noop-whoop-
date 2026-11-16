import XCTest
import WhoopStore
@testable import StrandImport

final class CanonicalWorkoutRowAdapterTests: XCTestCase {
    func testWhoopImportRowMapsWithoutInventingTimeSeries() {
        let row = WorkoutRow(startTs: 1_800_100_000, endTs: 1_800_100_600,
                             sport: "Running", source: "whoop", durationS: 600,
                             energyKcal: 123, avgHr: 141, maxHr: 171, strain: 8.2,
                             distanceM: 2_000, zonesJSON: nil, notes: nil, steps: nil)
        let canonical = CanonicalWorkout(workoutRow: row, deviceID: "my-whoop")

        XCTAssertEqual(canonical.source, .whoopImport)
        XCTAssertEqual(canonical.startTimestamp, row.startTs)
        XCTAssertEqual(canonical.endTimestamp, row.endTs)
        XCTAssertEqual(canonical.distanceM, 2_000)
        XCTAssertEqual(canonical.energyKcal, 123)
        XCTAssertEqual(canonical.averageHeartRate, 141)
        XCTAssertEqual(canonical.maximumHeartRate, 171)
        XCTAssertEqual(canonical.strain, 8.2)
        XCTAssertTrue(canonical.heartRateSamples.isEmpty)
        XCTAssertTrue(canonical.route.isEmpty)
        XCTAssertEqual(canonical.provenance[.distance]?.status, .imported)
        XCTAssertTrue(canonical.externalID.hasPrefix("noop-w1-"))
    }

    func testManualRowDoesNotPretendMeasuredVersusManualProvenanceIsKnown() {
        let row = WorkoutRow(startTs: 1_800_200_000, endTs: 1_800_200_300,
                             sport: "Climbing", source: "manual", durationS: 300,
                             energyKcal: nil, avgHr: 150, maxHr: 175, strain: nil,
                             distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
        let canonical = CanonicalWorkout(workoutRow: row, deviceID: "my-whoop")

        XCTAssertEqual(canonical.source, .manual)
        XCTAssertNil(canonical.provenance[.heartRateSummary])
    }

    func testLegacyDetectedSourceIsExplicitlyDerived() {
        let row = WorkoutRow(startTs: 1_800_300_000, endTs: 1_800_300_120,
                             sport: "detected", source: "my-whoop-noop", durationS: 120,
                             energyKcal: nil, avgHr: nil, maxHr: nil, strain: 3.2,
                             distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
        let canonical = CanonicalWorkout(workoutRow: row, deviceID: "my-whoop-noop")

        XCTAssertEqual(canonical.source, .legacyDetected)
        XCTAssertEqual(canonical.provenance[.strain]?.status, .derived)
    }

    func testLegacyHealthKeyRecognitionDoesNotMatchCurrentKeys() {
        XCTAssertTrue(HealthWriteback.isLegacyDeviceScopedAppleHealthKey("noop:my-whoop:workout:1800000000"))
        XCTAssertTrue(HealthWriteback.isLegacyDeviceScopedAppleHealthKey("noop:whoop-abc:sleep:1800000000"))
        XCTAssertFalse(HealthWriteback.isLegacyDeviceScopedAppleHealthKey("noop:workout:1800000000"))
        XCTAssertFalse(HealthWriteback.isLegacyDeviceScopedAppleHealthKey("noop:sleep:1800000000"))
        XCTAssertFalse(HealthWriteback.isLegacyDeviceScopedAppleHealthKey("foreign:device:workout:1800000000"))
        XCTAssertFalse(HealthWriteback.isLegacyDeviceScopedAppleHealthKey("noop::workout:1800000000"))
    }
}
