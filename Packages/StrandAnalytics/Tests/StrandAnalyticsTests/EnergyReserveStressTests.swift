import Foundation
import XCTest
import WhoopStore
@testable import StrandAnalytics

/// Deterministic adversarial regression cases for the Phase 4 Energy Reserve timeline.
/// These are software tests, not physiological validation or a physical-device BLE test.
final class EnergyReserveStressTests: XCTestCase {
    private let target = "2026-10-26"

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func dayWindow() -> Range<Date> {
        let calendar = calendar()
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26))!
        return start..<calendar.date(byAdding: .day, value: 1, to: start)!
    }

    private func metric(_ key: String, strain: Double? = 40, hrv: Double? = 65,
                        recovery: Double? = 78) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: 480, efficiency: 0.90, deepMin: 100,
                    remMin: 120, lightMin: 260, disturbances: 1, restingHr: 52,
                    avgHrv: hrv, recovery: recovery, strain: strain,
                    exerciseCount: nil, spo2Pct: nil, skinTempDevC: nil,
                    respRateBpm: 14, steps: nil, activeKcalEst: nil)
    }

    private func workout(id: String, end: Date, strain: Double? = 25) -> EnergyReserveEngine.ActivityEvent {
        EnergyReserveEngine.ActivityEvent(id: id, start: end.addingTimeInterval(-1200),
                                          end: end, strain: strain, activeKilocalories: nil)
    }

    func testStaleOffDayDuplicateCannotMaskSameIdWorkoutInsideToday() {
        let range = dayWindow()
        let inside = workout(id: "sync-id", end: range.lowerBound.addingTimeInterval(10 * 3600))
        let stale = workout(id: "sync-id", end: range.lowerBound.addingTimeInterval(-3600))
        let result = EnergyReserveEngine.estimate(
            days: [metric(target)], targetDay: target, dayInterval: range,
            wakeTime: nil, activities: [stale, inside], currentStrain: 40,
            evaluatedAt: range.lowerBound.addingTimeInterval(18 * 3600))
        XCTAssertEqual(result.trend.filter { $0.source == .workout }.count, 1,
                       "Filter the relevant date before deduplicating a workout's natural key")
    }

    func testManyWorkoutEventsCannotFabricateReboundAtCurrentSample() {
        let range = dayWindow()
        let activities = (0..<120).map {
            workout(id: "workout-\($0)", end: range.lowerBound.addingTimeInterval(Double(3600 * 8 + $0 * 30)),
                    strain: 50)
        }
        let result = EnergyReserveEngine.estimate(
            days: [metric(target)], targetDay: target, dayInterval: range,
            wakeTime: range.lowerBound.addingTimeInterval(6 * 3600),
            activities: activities, currentStrain: 40,
            evaluatedAt: range.lowerBound.addingTimeInterval(18 * 3600))
        XCTAssertNotNil(result.value)
        let values = result.trend.map(\.value)
        XCTAssertGreaterThan(values.count, 100)
        for pair in zip(values, values.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.0, pair.1,
                "No restorative input occurred, so an apparent instant recharge is artificial")
        }
        XCTAssertEqual(result.trend.last?.value, result.value)
    }

    func testWorkoutExactlyAtEvaluationTimeStillEndsAtReportedScore() {
        let range = dayWindow()
        let now = range.lowerBound.addingTimeInterval(14 * 3600)
        let result = EnergyReserveEngine.estimate(
            days: [metric(target)], targetDay: target, dayInterval: range, wakeTime: nil,
            activities: [workout(id: "end-now", end: now, strain: 1)],
            currentStrain: 40, evaluatedAt: now)
        XCTAssertEqual(result.trend.last?.value, result.value)
        XCTAssertEqual(result.trend.filter { $0.timestamp == now }.count, 1,
                       "Do not duplicate timestamps with contradictory energy values")
    }

    func testMultiYearImportDuplicateStormAndInvalidStrainsStayBounded() {
        let range = dayWindow()
        let cal = calendar()
        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.timeZone = cal.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        var days: [DailyMetric] = []
        for offset in -3099...0 {
            let date = cal.date(byAdding: .day, value: offset, to: range.lowerBound)!
            days.append(metric(formatter.string(from: date), strain: Double(10 + (offset + 3100) % 30),
                               hrv: Double(55 + (offset + 3100) % 15)))
        }
        // Corrupted and repeated history is a normal recovery scenario after interrupted sync.
        let repeatedDays = days + days.reversed()
        let valid = (0..<1_000).map {
            workout(id: "e\($0)", end: range.lowerBound.addingTimeInterval(Double(8 * 3600 + $0)),
                    strain: Double(($0 % 8) + 1))
        }
        let now = range.lowerBound.addingTimeInterval(18 * 3600)
        let original = EnergyReserveEngine.estimate(
            days: days, targetDay: target, dayInterval: range, wakeTime: nil,
            activities: valid, currentStrain: 40, evaluatedAt: now)
        let duplicated = EnergyReserveEngine.estimate(
            days: repeatedDays, targetDay: target, dayInterval: range, wakeTime: nil,
            activities: Array(valid.reversed()) + valid,
            currentStrain: 40, evaluatedAt: now)

        XCTAssertEqual(original, duplicated, "Replayed sync rows must not alter score or timeline")
        XCTAssertNotNil(duplicated.value)
        XCTAssertTrue((0...100).contains(duplicated.value!))
        XCTAssertTrue((0...1).contains(duplicated.completeness))
        XCTAssertLessThanOrEqual(duplicated.trend.count, 1_002)
        XCTAssertEqual(duplicated.trend.last?.value, duplicated.value)
    }

    func testAdversarialInvalidInputsDoNotEscapeScoreBounds() {
        let range = dayWindow()
        let now = range.lowerBound.addingTimeInterval(18 * 3600)
        let values: [Double?] = [nil, .nan, .infinity, -.infinity, -100, 0, 0.1, 5, 50, 100, 101, 1_000_000]
        for i in 0..<values.count * 20 {
            let strain = values[i % values.count]
            let event = workout(id: "bad-\(i)", end: range.lowerBound.addingTimeInterval(10 * 3600),
                                strain: values[(i * 7) % values.count])
            let result = EnergyReserveEngine.estimate(
                days: [metric(target, strain: strain)], targetDay: target, dayInterval: range,
                wakeTime: nil, activities: [event], currentStrain: strain, evaluatedAt: now)
            XCTAssertTrue(result.completeness.isFinite)
            XCTAssertTrue((0...1).contains(result.completeness))
            if let score = result.value { XCTAssertTrue((0...100).contains(score)) }
            XCTAssertTrue(result.trend.allSatisfy { (0...100).contains($0.value) })
            XCTAssertEqual(result.trend.last?.value, result.value)
        }
    }
}
