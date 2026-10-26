import Combine
import XCTest
@testable import Strand

/// Regression cases for WHOOP 4.0 command and WHOOP 5/MG standard 0x2A19 readings.
/// Does not simulate physical Bluetooth behaviour or measure actual battery life.
@MainActor
final class BatteryReadingSafetyTests: XCTestCase {
    func testPackAttachmentDoesNotFalselyReportCharging() {
        // A connected pack can be flat or poorly seated: never show a
        // confirmed green charging state until the strap says charging.
        XCTAssertNil(StrapChargingEvidence.statusUpdate(
            event: "BATTERY_PACK_CONNECTED(21)", gaugeBit: nil))
        XCTAssertNil(StrapChargingEvidence.statusUpdate(
            event: "BATTERY_LEVEL(26)", gaugeBit: nil))
        XCTAssertEqual(StrapChargingEvidence.statusUpdate(
            event: "BATTERY_LEVEL(26)", gaugeBit: 0), false)
        XCTAssertEqual(StrapChargingEvidence.statusUpdate(
            event: "BATTERY_LEVEL(26)", gaugeBit: 1), true)
        XCTAssertEqual(StrapChargingEvidence.statusUpdate(
            event: "CHARGING_ON(7)", gaugeBit: nil), true)
        XCTAssertEqual(StrapChargingEvidence.statusUpdate(
            event: "CHARGING_OFF(8)", gaugeBit: nil), false)
        XCTAssertEqual(StrapChargingEvidence.statusUpdate(
            event: "BATTERY_PACK_REMOVED(22)", gaugeBit: nil), false)
        XCTAssertNil(StrapChargingEvidence.statusUpdate(
            event: "WRIST_ON(9)", gaugeBit: nil))
    }

    func testInvalidPercentNeverPollutesUIEstimatorOrAlertHook() {
        let live = LiveState()
        var notified: [Double] = []
        live.onBatteryUpdate = { notified.append($0) }

        live.setBattery(73)
        for invalid in [Double.nan, .infinity, -.infinity, -1, 100.01, 255] {
            live.setBattery(invalid)
        }

        XCTAssertEqual(live.batteryPct, 73)
        XCTAssertEqual(live.batterySamples.count, 1)
        XCTAssertEqual(live.batterySamples.first?.soc, 73)
        XCTAssertEqual(notified, [73], "Rejected readings must not trigger alerts or history changes")
        live.setBattery(0)
        live.setBattery(100)
        XCTAssertEqual(live.batteryPct, 100, "Valid boundary percentages must survive")
    }

    func testRepeatedUnchangedPollDoesNotNotifySwiftUISubscribers() {
        let live = LiveState()
        var publications: [Double?] = []
        let observation = live.$batteryPct.sink { publications.append($0) }
        defer { observation.cancel() }

        live.setBattery(42.5)
        for _ in 0..<100 { live.setBattery(42.5) }
        live.setBattery(42.4)

        XCTAssertEqual(publications.compactMap { $0 }, [42.5, 42.4],
                       "No new displayed information means no unnecessary published refresh")
    }

    func testIdenticalPercentStillRebanksAfterTenMinutesForBatteryRuntime() {
        let live = LiveState()
        live.bankBatterySample(80, now: 1000)
        live.bankBatterySample(80, now: 1599)
        XCTAssertEqual(live.batterySamples.count, 1)
        live.bankBatterySample(80, now: 1600)
        XCTAssertEqual(live.batterySamples.count, 2,
                       "Do not break existing long-window slope and runtime estimation")
    }

    func testDirectBankRejectsCorruptOutOfRangeAndNonFiniteValues() {
        let live = LiveState()
        for value in [Double.nan, .infinity, -.infinity, -0.001, 100.001, 255] {
            live.bankBatterySample(value, now: 1000)
        }
        XCTAssertTrue(live.batterySamples.isEmpty)
        live.bankBatterySample(10, now: 1000)
        XCTAssertEqual(live.batterySamples.count, 1)
    }

    func testPersistedSeedSkipsInvalidRowsAndRepeatedTimestamps() {
        let live = LiveState()
        live.bankBatterySample(77, now: 1000)
        live.seedBatterySamples([
            (ts: 1000, soc: 12), // Must not overwrite already-banked current sample
            (ts: 2000, soc: Double.nan),
            (ts: 3000, soc: 255),
            (ts: 4000, soc: -5),
            (ts: 5000, soc: 55),
            (ts: 5000, soc: 2), // Same timestamp must not count twice
            (ts: 6000, soc: 0),
            (ts: 7000, soc: 100)
        ])
        XCTAssertEqual(live.batterySamples.map { $0.ts }, [1000, 5000, 6000, 7000])
        XCTAssertEqual(live.batterySamples.map { $0.soc }, [77, 55, 0, 100])
        live.seedBatterySamples([(ts: 5000, soc: 90)])
        XCTAssertEqual(live.batterySamples.count, 4, "Seed must be idempotent")
    }
}
