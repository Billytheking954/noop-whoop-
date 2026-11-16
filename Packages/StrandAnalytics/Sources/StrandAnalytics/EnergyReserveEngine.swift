import Foundation
import WhoopStore

/// A transparent, non-medical estimate of energy available for the day.
///
/// This deliberately is not a clone of any vendor score. It combines only observations already held
/// by NOOP, renormalises around missing inputs, and emits intraday checkpoints only when a real sleep,
/// workout, or current-strain timestamp exists. It never invents minute-by-minute samples.
public enum EnergyReserveEngine {
    public enum Direction: String, Sendable, Equatable {
        case restores, depletes, neutral
    }

    public enum TrendSource: String, Sendable, Equatable {
        case wake, workout, current
    }

    public struct Factor: Sendable, Equatable {
        public let key: String
        public let value: Double
        public let weight: Double
        public let direction: Direction

        public init(key: String, value: Double, weight: Double, direction: Direction) {
            self.key = key
            self.value = value
            self.weight = weight
            self.direction = direction
        }
    }

    public struct ActivityEvent: Sendable, Equatable {
        public let id: String
        public let start: Date
        public let end: Date
        public let strain: Double?
        public let activeKilocalories: Double?

        public init(id: String, start: Date, end: Date, strain: Double?, activeKilocalories: Double?) {
            self.id = id
            self.start = start
            self.end = end
            self.strain = strain
            self.activeKilocalories = activeKilocalories
        }
    }

    public struct TrendPoint: Sendable, Equatable {
        public let timestamp: Date
        public let value: Int
        public let source: TrendSource

        public init(timestamp: Date, value: Int, source: TrendSource) {
            self.timestamp = timestamp
            self.value = value
            self.source = source
        }
    }

    public struct Estimate: Sendable, Equatable {
        public let value: Int?
        public let morningValue: Int?
        public let completeness: Double
        public let confidence: ScoreConfidence
        public let factors: [Factor]
        public let trend: [TrendPoint]
        public let missingInputs: [String]

        public init(value: Int?, morningValue: Int?, completeness: Double,
                    confidence: ScoreConfidence, factors: [Factor], trend: [TrendPoint],
                    missingInputs: [String]) {
            self.value = value
            self.morningValue = morningValue
            self.completeness = completeness
            self.confidence = confidence
            self.factors = factors
            self.trend = trend
            self.missingInputs = missingInputs
        }
    }

    private static let baselineWindow = 30
    private static let minBaselineNights = 7

    /// Produces an estimate for one explicit local-day interval. `dayInterval` must be built with a
    /// calendar start-of-day plus one calendar day; callers must not assume every day is 86,400 seconds.
    public static func estimate(
        days: [DailyMetric],
        targetDay: String,
        dayInterval: Range<Date>,
        wakeTime: Date?,
        activities: [ActivityEvent],
        currentStrain: Double?,
        evaluatedAt: Date
    ) -> Estimate {
        let unique = deduplicated(days).sorted { $0.day < $1.day }
        guard let today = unique.first(where: { $0.day == targetDay }) else {
            return Estimate(value: nil, morningValue: nil, completeness: 0,
                            confidence: .calibrating, factors: [], trend: [],
                            missingInputs: ["sleep", "sleepEfficiency", "sleepStages", "recovery",
                                            "hrv", "restingHr", "activity"])
        }

        let history = Array(unique.filter { $0.day < targetDay }.suffix(baselineWindow))
        var factors: [Factor] = []
        var availableWeight = 0.0
        var weighted = 0.0

        func add(_ key: String, _ value: Double?, weight: Double, direction: Direction) {
            guard let value, value.isFinite else { return }
            let bounded = clamp(value, 0, 100)
            factors.append(Factor(key: key, value: bounded, weight: weight, direction: direction))
            weighted += bounded * weight
            availableWeight += weight
        }

        let sleep = today.totalSleepMin.flatMap { (30...960).contains($0) ? $0 : nil }
        let scoredSleep = sleep.map(sleepScore)
        add("sleep", scoredSleep, weight: 0.20, direction: direction(for: scoredSleep))

        let efficiency = today.efficiency.flatMap { (0.2...1.0).contains($0) ? $0 : nil }
        add("sleepEfficiency", efficiency.map { clamp(($0 - 0.60) / 0.30 * 100, 0, 100) },
            weight: 0.10, direction: (efficiency ?? 0) >= 0.85 ? .restores : .neutral)

        let deep = today.deepMin.flatMap { (0...720).contains($0) ? $0 : nil }
        let rem = today.remMin.flatMap { (0...720).contains($0) ? $0 : nil }
        let restorativeScore: Double? = {
            guard let sleep, sleep > 0, let deep, let rem, deep + rem <= sleep else { return nil }
            let share = (deep + rem) / sleep
            if share <= 0.40 { return clamp(share / 0.40 * 100, 0, 100) }
            return clamp(100 - (share - 0.55) * 100, 70, 100)
        }()
        add("sleepStages", restorativeScore, weight: 0.10, direction: direction(for: restorativeScore))

        let recovery = today.recovery.flatMap { (0...100).contains($0) ? $0 : nil }
        add("recovery", recovery, weight: 0.20,
            direction: (recovery ?? 0) >= 67 ? .restores : ((recovery ?? 100) < 34 ? .depletes : .neutral))

        let hrv = today.avgHrv.flatMap { (5...300).contains($0) ? $0 : nil }
        let hrvHistory = history.compactMap { $0.avgHrv }.filter { (5...300).contains($0) }
        let hrvScore = relativeScore(value: hrv, baseline: hrvHistory, higherIsBetter: true, logDomain: true)
        add("hrv", hrvScore, weight: 0.15,
            direction: direction(for: hrvScore))

        let rhr = today.restingHr.map(Double.init).flatMap { (25...220).contains($0) ? $0 : nil }
        let rhrHistory = history.compactMap { $0.restingHr.map(Double.init) }.filter { (25...220).contains($0) }
        let rhrScore = relativeScore(value: rhr, baseline: rhrHistory, higherIsBetter: false, logDomain: false)
        add("restingHr", rhrScore, weight: 0.15,
            direction: direction(for: rhrScore))

        // A small activity-context term keeps a real measured low-load day distinct from a hard day,
        // without allowing missing activity to masquerade as rest. Depletion itself is applied below.
        let boundedStrain = currentStrain.flatMap { (0...100).contains($0) ? $0 : nil }
            ?? today.strain.flatMap { (0...100).contains($0) ? $0 : nil }
        // Active-kcal is an explicitly approximate fallback only when the normal Strain input is absent.
        let kcalLoad = today.activeKcalEst.flatMap { (0...10_000).contains($0) ? min(100, $0 / 10) : nil }
        let activityLoad = boundedStrain ?? kcalLoad
        if let activityLoad {
            factors.append(Factor(key: "activity", value: 100 - activityLoad, weight: 0.10,
                                  direction: activityLoad > 35 ? .depletes : .neutral))
        }

        let completeness = clamp(availableWeight + (activityLoad == nil ? 0 : 0.10), 0, 1)
        let restorationCount = factors.filter { $0.key != "activity" }.count
        guard availableWeight >= 0.35, restorationCount >= 2 else {
            return Estimate(value: nil, morningValue: nil, completeness: completeness,
                            confidence: .calibrating, factors: factors, trend: [],
                            missingInputs: missingInputs(factors: factors))
        }

        let morning = Int(clamp(weighted / availableWeight, 0, 100).rounded())
        let current = Int(clamp(Double(morning) - (activityLoad ?? 0) * 0.45, 0, 100).rounded())
        let confidence: ScoreConfidence = completeness >= 0.85 && history.count >= baselineWindow
            ? .solid : .building
        let trend = trendPoints(morning: morning, current: current, dayInterval: dayInterval,
                                wakeTime: wakeTime, activities: activities,
                                evaluatedAt: evaluatedAt)

        return Estimate(value: current, morningValue: morning, completeness: completeness,
                        confidence: confidence, factors: factors, trend: trend,
                        missingInputs: missingInputs(factors: factors))
    }

    private static func trendPoints(morning: Int, current: Int, dayInterval: Range<Date>,
                                    wakeTime: Date?, activities: [ActivityEvent],
                                    evaluatedAt: Date) -> [TrendPoint] {
        var result: [TrendPoint] = []
        if let wakeTime, dayInterval.contains(wakeTime), wakeTime <= evaluatedAt {
            result.append(TrendPoint(timestamp: wakeTime, value: morning, source: .wake))
        }

        // Natural-key de-duplication prevents a repeated sync row from draining the estimate twice.
        var seen = Set<String>()
        let usable = activities
            .filter { seen.insert($0.id).inserted }
            .filter { $0.end >= dayInterval.lowerBound && $0.end < dayInterval.upperBound && $0.end <= evaluatedAt }
            .sorted { $0.end < $1.end }
        var running = Double(morning)
        for event in usable {
            let eventStrain = event.strain.flatMap { (0...100).contains($0) ? $0 : nil }
            let eventKcal = event.activeKilocalories.flatMap { (0...10_000).contains($0) ? $0 : nil }
            guard eventStrain != nil || eventKcal != nil else { continue }
            // Strain is preferred; calories are only a bounded fallback when the workout lacks strain.
            let cost = eventStrain.map { $0 * 0.45 } ?? min(18, (eventKcal ?? 0) / 60)
            running = clamp(running - cost, 0, 100)
            result.append(TrendPoint(timestamp: event.end, value: Int(running.rounded()), source: .workout))
        }

        if dayInterval.contains(evaluatedAt), result.last?.timestamp != evaluatedAt {
            result.append(TrendPoint(timestamp: evaluatedAt, value: current, source: .current))
        }
        return result
    }

    private static func relativeScore(value: Double?, baseline: [Double],
                                      higherIsBetter: Bool, logDomain: Bool) -> Double? {
        guard let value, baseline.count >= minBaselineNights else { return nil }
        let transformed = logDomain ? baseline.map(log) : baseline
        guard let mean = ReadinessEngine.mean(transformed),
              let sd = ReadinessEngine.sampleSD(transformed), sd > 0 else { return 50 }
        let v = logDomain ? log(value) : value
        let orientedZ = (higherIsBetter ? v - mean : mean - v) / max(sd, 0.05)
        return clamp(50 + orientedZ * 15, 0, 100)
    }

    private static func sleepScore(_ minutes: Double) -> Double {
        if minutes <= 480 { return clamp((minutes - 180) / 300 * 100, 0, 100) }
        // Long sleep is not treated as extra restoration; very long sleep gently reduces certainty/value.
        return clamp(100 - (minutes - 540) / 6, 70, 100)
    }

    private static func direction(for value: Double?) -> Direction {
        guard let value else { return .neutral }
        if value >= 60 { return .restores }
        if value < 40 { return .depletes }
        return .neutral
    }

    private static func missingInputs(factors: [Factor]) -> [String] {
        let present = Set(factors.map(\.key))
        return ["sleep", "sleepEfficiency", "sleepStages", "recovery", "hrv", "restingHr", "activity"]
            .filter { !present.contains($0) }
    }

    private static func deduplicated(_ days: [DailyMetric]) -> [DailyMetric] {
        var chosen: [String: DailyMetric] = [:]
        for day in days {
            guard !day.day.isEmpty else { continue }
            if let old = chosen[day.day] {
                let candidate = (quality(day), stableKey(day))
                let current = (quality(old), stableKey(old))
                if candidate.0 > current.0 || (candidate.0 == current.0 && candidate.1 > current.1) {
                    chosen[day.day] = day
                }
            } else {
                chosen[day.day] = day
            }
        }
        return Array(chosen.values)
    }

    private static func quality(_ day: DailyMetric) -> Int {
        var count = 0
        if let value = day.totalSleepMin, (30...960).contains(value) { count += 1 }
        if let value = day.efficiency, (0.2...1.0).contains(value) { count += 1 }
        if let value = day.deepMin, (0...720).contains(value) { count += 1 }
        if let value = day.remMin, (0...720).contains(value) { count += 1 }
        if let value = day.avgHrv, (5...300).contains(value) { count += 1 }
        if let value = day.recovery, (0...100).contains(value) { count += 1 }
        if let value = day.strain, (0...100).contains(value) { count += 1 }
        if let value = day.activeKcalEst, (0...10_000).contains(value) { count += 1 }
        if let value = day.restingHr, (25...220).contains(value) { count += 1 }
        return count
    }

    private static func stableKey(_ day: DailyMetric) -> String {
        [day.totalSleepMin, day.efficiency, day.deepMin, day.remMin, day.avgHrv, day.recovery, day.strain,
         day.activeKcalEst, day.restingHr.map(Double.init)]
            .map { $0.map { String(format: "%020.8f", $0) } ?? "-" }
            .joined(separator: "|")
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(upper, max(lower, value))
    }
}
