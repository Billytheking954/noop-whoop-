import XCTest
@testable import StrandAnalytics

final class ScoreValidationTraceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_710_028_800)

    func testTraceIsVersionedDeterministicAndLabelsEstimates() {
        let end = start.addingTimeInterval(23 * 3_600)
        let energy = EnergyReserveEngine.Estimate(
            value: 74, morningValue: 82, completeness: 0.875, confidence: .solid,
            factors: [.init(key: "sleep", value: 88.125, weight: 0.2, direction: .restores)],
            trend: [.init(timestamp: start.addingTimeInterval(7 * 3_600), value: 82, source: .wake)],
            missingInputs: ["sleepStages"])
        let readiness = ReadinessEngine.Readiness(
            level: .primed, headline: "Ready", summary: "Signals aligned",
            signals: [.init(key: "hrv", label: "HRV", evidence: "72 vs 60 ms",
                            detail: "above baseline", flag: .good)],
            acwr: 1.01, monotony: nil, score: 81, dataCompleteness: 0.9, confidence: .building)
        let snapshot = ScoreValidationTrace.Snapshot(
            targetDay: "2024-03-10", generatedAt: start.addingTimeInterval(8 * 3_600),
            dayInterval: start..<end, dailyRowCount: 31, activityEventCount: 0,
            wakeTimeAvailable: true, energy: energy, readiness: readiness)

        let lines = ScoreValidationTrace.lines(snapshot)

        XCTAssertEqual(lines.first, "phase4ScoreContext schema=1 day=2024-03-10 generatedAtUnix=1710057600 dayLengthS=82800 dailyRows=31 activityEvents=0 wake=present")
        XCTAssertTrue(lines.contains("phase4Energy estimated=true value=74 morning=82 completeness=0.875 confidence=solid trendPoints=1"))
        XCTAssertTrue(lines.contains("phase4EnergyFactor key=sleep value=88.12 weight=0.200 direction=restores"))
        XCTAssertTrue(lines.contains("phase4EnergyTrend source=wake offsetS=25200 value=82"))
        XCTAssertTrue(lines.contains("phase4Readiness estimated=true score=81 level=primed completeness=0.900 confidence=building acwr=1.010 monotony=missing"))
        XCTAssertEqual(lines.last, "phase4Limitations medical=false energyEstimate=true readinessEstimate=true minuteByMinuteFabricated=false missingDataImputed=false")
    }

    func testMissingValuesRemainExplicitAndNoTrendIsInvented() {
        let end = start.addingTimeInterval(25 * 3_600)
        let energy = EnergyReserveEngine.Estimate(
            value: nil, morningValue: nil, completeness: 0, confidence: .calibrating,
            factors: [], trend: [], missingInputs: ["sleep", "hrv", "restingHr"])
        let readiness = ReadinessEngine.Readiness(
            level: .insufficient, headline: "Not enough data", summary: "Keep wearing your device",
            signals: [], acwr: nil, monotony: nil, score: nil,
            dataCompleteness: 0, confidence: .calibrating)
        let lines = ScoreValidationTrace.lines(.init(
            targetDay: "2024-11-03", generatedAt: start, dayInterval: start..<end,
            dailyRowCount: 0, activityEventCount: 0, wakeTimeAvailable: false,
            energy: energy, readiness: readiness))

        XCTAssertTrue(lines.contains("phase4Energy estimated=true value=missing morning=missing completeness=0.000 confidence=calibrating trendPoints=0"))
        XCTAssertTrue(lines.contains("phase4EnergyMissing inputs=sleep,hrv,restingHr"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("phase4EnergyTrend ") })
        XCTAssertTrue(lines.contains("phase4Readiness estimated=true score=missing level=insufficient completeness=0.000 confidence=calibrating acwr=missing monotony=missing"))
        XCTAssertTrue(lines.first?.contains("dayLengthS=90000") == true)
    }

    func testFreeTextCannotBreakTheLineProtocol() {
        let energy = EnergyReserveEngine.Estimate(
            value: 50, morningValue: 50, completeness: 0.5, confidence: .building,
            factors: [], trend: [], missingInputs: [])
        let readiness = ReadinessEngine.Readiness(
            level: .balanced, headline: "Balanced", summary: "Summary",
            signals: [.init(key: "custom key", label: "Custom", evidence: "a\n\"b\"",
                            detail: "line\rbreak", flag: .neutral)],
            acwr: nil, monotony: nil, score: 50, dataCompleteness: 0.5, confidence: .building)
        let lines = ScoreValidationTrace.lines(.init(
            targetDay: "bad day", generatedAt: start,
            dayInterval: start..<start.addingTimeInterval(86_400),
            dailyRowCount: -1, activityEventCount: -1, wakeTimeAvailable: false,
            energy: energy, readiness: readiness))

        XCTAssertTrue(lines.first?.contains("day=bad_day") == true)
        XCTAssertTrue(lines.first?.contains("dailyRows=0 activityEvents=0") == true)
        XCTAssertTrue(lines.contains("phase4ReadinessSignal key=custom_key flag=neutral evidence=\"a 'b'\" detail=\"line break\""))
        XCTAssertTrue(lines.allSatisfy { !$0.contains("\n") && !$0.contains("\r") })
    }
}
