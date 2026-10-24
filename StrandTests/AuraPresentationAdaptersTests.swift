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
        XCTAssertEqual(mapped.charge.kind, .unresolved)
        XCTAssertEqual(AuraTodayAdapter.map(day(), todayKey: "2026-10-24",
                                            chargeKind: .estimated).charge.kind, .estimated)
        XCTAssertEqual(mapped.charge.day, "2026-10-24")
        XCTAssertNil(mapped.charge.measuredAt)
        XCTAssertEqual(mapped.charge.sourceID, "whoop-export")
    }

    func testLogicalTodayDoesNotBecomeStaleBeforeFourAM() {
        // Before 04:00 a valid current dashboard row can carry yesterday's day key.
        let logicalKey = "2026-10-23"
        let localKey = "2026-10-24"
        let row = day(logicalKey)
        let chosen = Repository.resolveToday(days: [row], logicalKey: logicalKey, localKey: localKey)
        XCTAssertEqual(chosen?.day, logicalKey)
        let mapped = AuraTodayAdapter.map(chosen, todayKey: chosen?.day ?? logicalKey)
        XCTAssertEqual(mapped.hrv.state, .available)
        XCTAssertEqual(mapped.charge.state, .available)
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
        XCTAssertEqual(mapped.effort.kind, .unresolved)
        XCTAssertEqual(mapped.effort.unit, "/100")
    }

    func testTrendsNeverFillMissingDays() {
        let source = [day("2026-10-20"), day("2026-10-24")]
        let series = AuraTrendsAdapter.map(source, metric: .hrv, sourceID: "V2")
        XCTAssertEqual(series.map(\.day), ["2026-10-20", "2026-10-24"])
        XCTAssertEqual(series.map(\.value), [68.4, 68.4])
        XCTAssertEqual(series.map(\.sourceID), ["V2", "V2"])
    }

    func testBatteryPercentAcceptsV2NativeUnitsWithoutFractionMistake() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let timestamp = now.addingTimeInterval(-20)
        let present = AuraDeviceAdapter.mapBatteryPercent(86.00000, connected: true,
                              measuredAt: timestamp, now: now, sourceID: "whoop-5")
        XCTAssertEqual(present.batteryLabel, "86%")
        XCTAssertEqual(present.state, .available)
        XCTAssertEqual(present.batterySourceID, "whoop-5")
        XCTAssertEqual(present.batteryMeasuredAt, timestamp)
        let rounded = AuraDeviceAdapter.mapBatteryPercent(86.6, connected: true,
                              measuredAt: timestamp, now: now, sourceID: "whoop-5")
        XCTAssertEqual(rounded.batteryLabel, "87%")
        let missing = AuraDeviceAdapter.mapBatteryPercent(101, connected: true,
                              measuredAt: timestamp, now: now, sourceID: "whoop-5")
        XCTAssertEqual(missing.state, .unavailable)
        let stale = AuraDeviceAdapter.mapBatteryPercent(86, connected: false,
                              measuredAt: timestamp, now: now, sourceID: "whoop-5")
        XCTAssertEqual(stale.state, .stale)
    }

    func testAuraShellVisibleTabTagsAndAdjacentSwipes() {
        XCTAssertEqual(AuraShellTabs.visibleIDs(auraEnabled: false), [0, 1, 2, 4])
        XCTAssertEqual(AuraShellTabs.visibleIDs(auraEnabled: true), [0, 1, 2, 3, 4])
        XCTAssertEqual(AuraShellTabs.adjacent(to: 2, towardsNext: true, auraEnabled: false), 4)
        XCTAssertEqual(AuraShellTabs.adjacent(to: 2, towardsNext: true, auraEnabled: true), 3)
        XCTAssertEqual(AuraShellTabs.adjacent(to: 3, towardsNext: true, auraEnabled: true), 4)
        XCTAssertEqual(AuraShellTabs.adjacent(to: 4, towardsNext: false, auraEnabled: false), 2)
        XCTAssertNil(AuraShellTabs.adjacent(to: 0, towardsNext: false, auraEnabled: true))
        XCTAssertNil(AuraShellTabs.adjacent(to: 4, towardsNext: true, auraEnabled: false))
        XCTAssertNil(AuraShellTabs.adjacent(to: 3, towardsNext: true, auraEnabled: false))
    }

    func testMissingRestAndFitnessDisplayUnavailableInsteadOfInventedValues() {
        let rest = AuraRestAdapter.map(nil, todayKey: "2026-10-24")
        let activity = AuraFitnessAdapter.map(nil, todayKey: "2026-10-24")
        XCTAssertNil(rest.sleepMinutes.value)
        XCTAssertNil(rest.sleepMinutes.measuredAt)
        XCTAssertEqual(rest.sleepMinutes.state, .unavailable)
        XCTAssertNil(activity.effort.value)
        XCTAssertNil(activity.steps.value)
        XCTAssertNil(activity.effort.sourceID)
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

    func testAuraHistoryRejectsInvalidSleepWindowsAndKeepsNewest() {
        let older = CachedSleepSession(startTs: 100, endTs: 220,
            efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)
        let newest = CachedSleepSession(startTs: 300, endTs: 720,
            efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)
        let invalid = CachedSleepSession(startTs: 900, endTs: 800,
            efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)
        XCTAssertEqual(AuraSessionHistory.sleep([older, invalid, newest]).map(\.startTs), [300, 100])
        XCTAssertEqual(AuraSessionHistory.sleep([older, newest], limit: 1).map(\.startTs), [300])
    }

    func testAuraTimedStagesPreserveRealTimestampsAndTrimToEditedWindow() {
        let segments = #"[{"start":80,"end":160,"stage":"deep"},{"start":160,"end":260,"stage":"rem"},{"start":260,"end":310,"stage":"unknown"}]"#
        let session = CachedSleepSession(startTs: 80, endTs: 250,
            efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: segments,
            startTsAdjusted: 100, deviceId: "whoop-source")
        let mapped = AuraSessionHistory.timedStages(session)
        XCTAssertEqual(mapped.map(\.start), [100, 160])
        XCTAssertEqual(mapped.map(\.end), [160, 250])
        XCTAssertEqual(mapped.map(\.stage), ["deep", "rem"])
        XCTAssertEqual(session.deviceId, "whoop-source")
    }

    func testAuraImportedStageTotalsCannotBecomeFabricatedTimeline() {
        let imported = CachedSleepSession(startTs: 100, endTs: 460,
            efficiency: nil, restingHr: nil, avgHrv: nil,
            stagesJSON: #"{"deep":42,"rem":70,"light":185,"awake":15}"#)
        XCTAssertTrue(AuraSessionHistory.timedStages(imported).isEmpty)
        XCTAssertTrue(AuraSessionHistory.timedStages(
            CachedSleepSession(startTs: 100, endTs: 460,
                efficiency: nil, restingHr: nil, avgHrv: nil, stagesJSON: nil)).isEmpty)
    }

    func testAuraWorkoutHistoryRejectsInvalidRows() {
        func workout(_ start: Int, _ end: Int) -> WorkoutRow {
            WorkoutRow(startTs: start, endTs: end, sport: "Run", source: "manual",
                durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil,
                strain: nil, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
        }
        XCTAssertEqual(AuraSessionHistory.workouts(
            [workout(100, 150), workout(200, 250), workout(300, 290)], limit: 1)
            .map(\.startTs), [200])
    }

}
