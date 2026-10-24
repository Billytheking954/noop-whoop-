import XCTest
import WhoopStore
@testable import Strand

final class AuraPresentationAdaptersTests: XCTestCase {
    private func day(_ key: String = "2026-10-24", temp: Double? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: 420, efficiency: 0.92,
                    deepMin: 93, remMin: 108, lightMin: 219, disturbances: nil,
                    restingHr: 52, avgHrv: 68.4, recovery: 73, strain: 23,
                    exerciseCount: nil, skinTempDevC: nil, skinTempC: temp)
    }

    func testMissingValuesNeverBecomeZero() {
        let empty = AuraTodayAdapter.map(nil, todayKey: "2026-10-24")
        XCTAssertNil(empty.charge.value)
        XCTAssertEqual(empty.charge.state, .unavailable)
        XCTAssertNil(empty.hrv.measuredAt)
        XCTAssertNil(empty.hrv.sourceID)
    }

    func testDailyChargeIsEstimateWithDayKeyNotInventedTimestamp() {
        let mapped = AuraTodayAdapter.map(day(), todayKey: "2026-10-24",
                                          sourceID: "whoop-export")
        XCTAssertEqual(mapped.charge.value, 73)
        XCTAssertEqual(mapped.charge.kind, .estimated)
        XCTAssertEqual(mapped.charge.day, "2026-10-24")
        XCTAssertNil(mapped.charge.measuredAt)
        XCTAssertEqual(mapped.charge.sourceID, "whoop-export")
    }

    func testOldDailyAggregateMarkedStaleEvenWhenValueExists() {
        let mapped = AuraTodayAdapter.map(day("2026-10-20"), todayKey: "2026-10-24")
        XCTAssertEqual(mapped.hrv.state, .stale)
        XCTAssertEqual(mapped.restingHeartRate.value, 52)
    }

    func testSleepEfficiencyStoredFractionConvertsToPercentOnce() throws {
        let rest = AuraRestAdapter.map(day(), todayKey: "2026-10-24")
        XCTAssertEqual(try XCTUnwrap(rest.sleepEfficiency.value), 92, accuracy: 0.001)
        XCTAssertEqual(rest.deepMinutes.kind, .estimated)
        let imported = AuraRestAdapter.map(day(), todayKey: "2026-10-24",
                                           stagesAreVendorDerived: true)
        XCTAssertEqual(imported.deepMinutes.kind, .vendorDerived)
    }

    func testEffortIsV2ScaleAndNotWHOOPTwentyOnePointScale() {
        let mapped = AuraFitnessAdapter.map(day(), todayKey: "2026-10-24")
        XCTAssertEqual(mapped.effort.value, 23)
        XCTAssertEqual(mapped.effort.unit, "/100")
    }

    func testTrendsNeverFillMissingDays() {
        let source = [day("2026-10-20"), day("2026-10-24")]
        let series = AuraTrendsAdapter.map(source, metric: .hrv, sourceID: "V2")
        XCTAssertEqual(series.map(\.day), ["2026-10-20", "2026-10-24"])
        XCTAssertEqual(series.map(\.value), [68.4, 68.4])
        XCTAssertEqual(series.map(\.sourceID), ["V2", "V2"])
    }

    func testBatteryFormattingAndSourceStaleness() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = AuraDeviceAdapter.mapBattery(0.86, connected: true,
                                                  measuredAt: now.addingTimeInterval(-30),
                                                  now: now, sourceID: "whoop-5")
        XCTAssertEqual(recent.batteryLabel, "86%")
        XCTAssertEqual(recent.state, .available)
        let old = AuraDeviceAdapter.mapBattery(0.86, connected: true,
                                               measuredAt: now.addingTimeInterval(-3600),
                                               now: now, sourceID: "whoop-5")
        XCTAssertEqual(old.state, .stale)
        let disconnected = AuraDeviceAdapter.mapBattery(0.86, connected: false,
                                                        measuredAt: now, now: now,
                                                        sourceID: "whoop-5")
        XCTAssertEqual(disconnected.state, .stale)
        let unknown = AuraDeviceAdapter.mapBattery(nil, connected: true,
                                                   measuredAt: nil, now: now,
                                                   sourceID: "whoop-5")
        XCTAssertEqual(unknown.batteryLabel, "—")
        XCTAssertEqual(unknown.state, .unavailable)
    }
}
