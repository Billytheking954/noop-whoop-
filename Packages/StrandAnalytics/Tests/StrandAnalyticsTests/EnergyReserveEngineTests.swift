import XCTest
@testable import StrandAnalytics
import WhoopStore

final class EnergyReserveEngineTests: XCTestCase {
    private func day(_ key: String, sleep: Double? = 480, efficiency: Double? = 0.90,
                     deep: Double? = nil, rem: Double? = nil,
                     hrv: Double? = 60, rhr: Int? = 52, recovery: Double? = 75,
                     strain: Double? = 10, activeKcal: Double? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: sleep, efficiency: efficiency,
                    deepMin: deep, remMin: rem, lightMin: nil, disturbances: nil,
                    restingHr: rhr, avgHrv: hrv, recovery: recovery, strain: strain,
                    exerciseCount: nil, activeKcalEst: activeKcal)
    }

    private func history(today: DailyMetric) -> [DailyMetric] {
        var rows = (1...30).map { index in
            day(String(format: "2024-03-%02d", index),
                hrv: index.isMultiple(of: 2) ? 58 : 62,
                rhr: index.isMultiple(of: 2) ? 50 : 54)
        }
        rows.append(today)
        return rows
    }

    private let interval = Date(timeIntervalSince1970: 1_711_843_200)..<Date(timeIntervalSince1970: 1_711_929_600)

    func testRestoredNightAndLightLoadProduceBoundedEstimate() {
        let now = interval.lowerBound.addingTimeInterval(12 * 3600)
        let result = EnergyReserveEngine.estimate(
            days: history(today: day("2024-03-31", sleep: 510, hrv: 70, rhr: 48,
                                     recovery: 85, strain: 8)),
            targetDay: "2024-03-31", dayInterval: interval,
            wakeTime: interval.lowerBound.addingTimeInterval(7 * 3600),
            activities: [], currentStrain: 8, evaluatedAt: now)

        XCTAssertNotNil(result.value)
        XCTAssertGreaterThanOrEqual(result.value!, 0)
        XCTAssertLessThanOrEqual(result.value!, 100)
        XCTAssertGreaterThan(result.value!, 60)
        XCTAssertEqual(result.trend.map(\.source), [.wake, .current])
        XCTAssertEqual(result.trend.count, 2, "No minute-by-minute points may be fabricated")
    }

    func testMissingSleepAndRecoveryFailsClosed() {
        let result = EnergyReserveEngine.estimate(
            days: [day("2024-03-31", sleep: nil, efficiency: nil, hrv: nil,
                       rhr: nil, recovery: nil, strain: 20)],
            targetDay: "2024-03-31", dayInterval: interval, wakeTime: nil,
            activities: [], currentStrain: 20, evaluatedAt: interval.lowerBound)
        XCTAssertNil(result.value)
        XCTAssertTrue(result.trend.isEmpty)
        XCTAssertEqual(result.confidence, .calibrating)
    }

    func testIncompleteNightProducesExplicitPartialEstimate() {
        let result = EnergyReserveEngine.estimate(
            days: [day("2024-03-31", sleep: 320, efficiency: nil, hrv: nil,
                       rhr: nil, recovery: 60, strain: 5)],
            targetDay: "2024-03-31", dayInterval: interval, wakeTime: nil,
            activities: [], currentStrain: 5,
            evaluatedAt: interval.lowerBound.addingTimeInterval(10 * 3600))
        XCTAssertNotNil(result.value)
        XCTAssertEqual(result.confidence, .building)
        XCTAssertLessThan(result.completeness, 0.75)
        XCTAssertTrue(result.missingInputs.contains("sleepEfficiency"))
        XCTAssertTrue(result.missingInputs.contains("sleepStages"))
    }

    func testValidRestorativeStagesContributeWithoutReplacingRawStageValues() {
        let result = EnergyReserveEngine.estimate(
            days: history(today: day("2024-03-31", deep: 100, rem: 100)),
            targetDay: "2024-03-31", dayInterval: interval, wakeTime: nil,
            activities: [], currentStrain: 10,
            evaluatedAt: interval.lowerBound.addingTimeInterval(12 * 3600))
        XCTAssertEqual(result.factors.first { $0.key == "sleepStages" }?.value, 100)
    }

    func testDuplicateWorkoutIsAppliedOnce() {
        let wake = interval.lowerBound.addingTimeInterval(7 * 3600)
        let end = interval.lowerBound.addingTimeInterval(10 * 3600)
        let event = EnergyReserveEngine.ActivityEvent(
            id: "same-workout", start: end.addingTimeInterval(-3600), end: end,
            strain: 20, activeKilocalories: 500)
        let result = EnergyReserveEngine.estimate(
            days: history(today: day("2024-03-31", strain: 20)),
            targetDay: "2024-03-31", dayInterval: interval, wakeTime: wake,
            activities: [event, event], currentStrain: 20,
            evaluatedAt: interval.lowerBound.addingTimeInterval(12 * 3600))

        XCTAssertEqual(result.trend.filter { $0.source == .workout }.count, 1)
    }

    func testDuplicateDailyRowsDoNotChangeEstimate() {
        let days = history(today: day("2024-03-31", hrv: 68, rhr: 49, strain: 12))
        let now = interval.lowerBound.addingTimeInterval(12 * 3600)
        let once = EnergyReserveEngine.estimate(
            days: days, targetDay: "2024-03-31", dayInterval: interval,
            wakeTime: nil, activities: [], currentStrain: 12, evaluatedAt: now)
        let duplicated = EnergyReserveEngine.estimate(
            days: days + Array(days.reversed()), targetDay: "2024-03-31", dayInterval: interval,
            wakeTime: nil, activities: [], currentStrain: 12, evaluatedAt: now)
        XCTAssertEqual(once, duplicated)
    }

    func testActiveEnergyIsUsedOnlyAsActivityFallback() {
        let result = EnergyReserveEngine.estimate(
            days: history(today: day("2024-03-31", strain: nil, activeKcal: 400)),
            targetDay: "2024-03-31", dayInterval: interval, wakeTime: nil,
            activities: [], currentStrain: nil,
            evaluatedAt: interval.lowerBound.addingTimeInterval(12 * 3600))
        XCTAssertNotNil(result.value)
        XCTAssertEqual(result.factors.first { $0.key == "activity" }?.value, 60)
    }

    func testCalendarDayIntervalsRespectBothDaylightSavingTransitions() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let start = calendar.date(from: DateComponents(year: 2024, month: 3, day: 10))!
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        XCTAssertEqual(end.timeIntervalSince(start), 23 * 3600)
        let fallStart = calendar.date(from: DateComponents(year: 2024, month: 11, day: 3))!
        let fallEnd = calendar.date(byAdding: .day, value: 1, to: fallStart)!
        XCTAssertEqual(fallEnd.timeIntervalSince(fallStart), 25 * 3600)

        let inside = EnergyReserveEngine.ActivityEvent(
            id: "inside", start: end.addingTimeInterval(-1800), end: end.addingTimeInterval(-1),
            strain: 5, activeKilocalories: nil)
        let boundary = EnergyReserveEngine.ActivityEvent(
            id: "boundary", start: end.addingTimeInterval(-600), end: end,
            strain: 5, activeKilocalories: nil)
        let result = EnergyReserveEngine.estimate(
            days: history(today: day("2024-03-10")), targetDay: "2024-03-10",
            dayInterval: start..<end, wakeTime: start.addingTimeInterval(7 * 3600),
            activities: [inside, boundary], currentStrain: 10,
            evaluatedAt: end.addingTimeInterval(-0.5))

        XCTAssertEqual(result.trend.filter { $0.source == .workout }.count, 1)
    }

    func testImplausiblePhysiologyIsIgnoredInsteadOfClampedIntoAReading() {
        let today = day("2024-03-31", sleep: 2_000, efficiency: 4, hrv: 900,
                        rhr: 5, recovery: 300, strain: -4)
        let result = EnergyReserveEngine.estimate(
            days: history(today: today), targetDay: "2024-03-31", dayInterval: interval,
            wakeTime: nil, activities: [], currentStrain: -4,
            evaluatedAt: interval.lowerBound.addingTimeInterval(12 * 3600))
        XCTAssertNil(result.value)
        XCTAssertTrue(Set(result.missingInputs).isSuperset(of: ["sleep", "recovery", "hrv", "restingHr", "activity"]))
    }
}
