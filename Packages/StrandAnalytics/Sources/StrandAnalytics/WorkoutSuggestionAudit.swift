import Foundation

/// A real, user-labelled workout used as local ground truth for the opt-in suggestion audit.
/// Labels come from manual/imported workout rows; detector-created rows must not be fed back as truth.
public struct LabeledWorkoutSession: Equatable, Sendable {
    public let startSec: Int
    public let endSec: Int
    public let activity: String

    public init(startSec: Int, endSec: Int, activity: String) {
        self.startSec = startSec
        self.endSec = endSec
        self.activity = activity
    }
}

/// One detector result plus the advisory coarse classification computed from its stored signals.
public struct AuditedWorkoutSuggestion: Equatable, Sendable {
    public let workout: DetectedWorkout
    public let predictedClass: CoarseWorkoutClass

    public init(workout: DetectedWorkout, predictedClass: CoarseWorkoutClass) {
        self.workout = workout
        self.predictedClass = predictedClass
    }
}

/// Per-activity errors. `falsePrompts` are grouped under the suggested coarse activity because they
/// have no real label; misses, duplicates and sport mistakes are grouped under the real label.
public struct WorkoutSuggestionActivityAudit: Equatable, Sendable {
    public var labelled = 0
    public var matched = 0
    public var missed = 0
    public var falsePrompts = 0
    public var duplicates = 0
    public var sportMistakes = 0

    public init() {}
}

/// Observable processing/battery proxy for one local audit. iOS exposes no trustworthy per-operation
/// battery-energy counter, so the report states that direct energy is unavailable and pins what can be
/// measured: wall time, rows read, an approximate in-memory byte floor, and zero added BLE/sensor work.
public struct WorkoutSuggestionAuditCost: Equatable, Sendable {
    public let wallMilliseconds: Int
    public let hrSamples: Int
    public let gravitySamples: Int
    public let stepSamples: Int
    public let approximateInputBytes: Int

    public init(wallMilliseconds: Int, hrSamples: Int, gravitySamples: Int, stepSamples: Int) {
        self.wallMilliseconds = max(0, wallMilliseconds)
        self.hrSamples = max(0, hrSamples)
        self.gravitySamples = max(0, gravitySamples)
        self.stepSamples = max(0, stepSamples)
        // Conservative payload-only floor; SQLite/object overhead is intentionally not presented as exact.
        self.approximateInputBytes = max(0, hrSamples) * 8
            + max(0, gravitySamples) * 32
            + max(0, stepSamples) * 16
    }
}

public struct WorkoutSuggestionAuditReport: Equatable, Sendable {
    public let byActivity: [String: WorkoutSuggestionActivityAudit]
    public let cost: WorkoutSuggestionAuditCost

    public init(byActivity: [String: WorkoutSuggestionActivityAudit],
                cost: WorkoutSuggestionAuditCost) {
        self.byActivity = byActivity
        self.cost = cost
    }

    public var totals: WorkoutSuggestionActivityAudit {
        byActivity.values.reduce(into: WorkoutSuggestionActivityAudit()) { total, row in
            total.labelled += row.labelled
            total.matched += row.matched
            total.missed += row.missed
            total.falsePrompts += row.falsePrompts
            total.duplicates += row.duplicates
            total.sportMistakes += row.sportMistakes
        }
    }

    /// Stable, local-only Test Centre lines. Activity is a normalized coarse key, never free text.
    public func traceLines() -> [String] {
        var lines = byActivity.keys.sorted().map { activity -> String in
            let row = byActivity[activity] ?? WorkoutSuggestionActivityAudit()
            return "workout audit activity=\(activity) labelled=\(row.labelled) matched=\(row.matched) "
                + "missed=\(row.missed) falsePrompts=\(row.falsePrompts) duplicates=\(row.duplicates) "
                + "sportMistakes=\(row.sportMistakes)"
        }
        let total = totals
        lines.append("workout audit total labelled=\(total.labelled) matched=\(total.matched) "
            + "missed=\(total.missed) falsePrompts=\(total.falsePrompts) duplicates=\(total.duplicates) "
            + "sportMistakes=\(total.sportMistakes)")
        lines.append("workout audit cost wallMs=\(cost.wallMilliseconds) hrSamples=\(cost.hrSamples) "
            + "gravitySamples=\(cost.gravitySamples) stepSamples=\(cost.stepSamples) "
            + "approxInputBytes=\(cost.approximateInputBytes) extraBLEReads=0 extraSensorSamplingS=0 "
            + "directBatteryEnergy=n/a")
        return lines
    }
}

/// Offline evaluator for the existing detector/classifier against real manual/imported labels.
/// Matching is deterministic: positive-overlap pairs are considered by greatest overlap first, then
/// stable timestamp order. A second candidate overlapping an already matched label is a duplicate;
/// an unmatched candidate with no labelled overlap is a false prompt.
public enum WorkoutSuggestionAudit {

    public static func evaluate(labels: [LabeledWorkoutSession],
                                suggestions: [AuditedWorkoutSuggestion],
                                cost: WorkoutSuggestionAuditCost) -> WorkoutSuggestionAuditReport {
        let labels = labels.filter { $0.endSec > $0.startSec }.sorted {
            $0.startSec == $1.startSec ? $0.endSec < $1.endSec : $0.startSec < $1.startSec
        }
        let suggestions = suggestions.sorted {
            $0.workout.startSec == $1.workout.startSec
                ? $0.workout.endSec < $1.workout.endSec
                : $0.workout.startSec < $1.workout.startSec
        }
        struct Pair {
            let suggestion: Int
            let label: Int
            let overlap: Int
        }
        var pairs: [Pair] = []
        for (si, suggestion) in suggestions.enumerated() {
            for (li, label) in labels.enumerated() {
                let overlap = min(suggestion.workout.endSec, label.endSec)
                    - max(suggestion.workout.startSec, label.startSec)
                if overlap > 0 { pairs.append(Pair(suggestion: si, label: li, overlap: overlap)) }
            }
        }
        pairs.sort {
            if $0.overlap != $1.overlap { return $0.overlap > $1.overlap }
            if $0.suggestion != $1.suggestion { return $0.suggestion < $1.suggestion }
            return $0.label < $1.label
        }

        var matchedSuggestions = Set<Int>()
        var matchedLabels = Set<Int>()
        var matchedPairs: [Pair] = []
        for pair in pairs where !matchedSuggestions.contains(pair.suggestion)
            && !matchedLabels.contains(pair.label) {
            matchedSuggestions.insert(pair.suggestion)
            matchedLabels.insert(pair.label)
            matchedPairs.append(pair)
        }

        var rows: [String: WorkoutSuggestionActivityAudit] = [:]
        func mutate(_ key: String, _ body: (inout WorkoutSuggestionActivityAudit) -> Void) {
            var row = rows[key] ?? WorkoutSuggestionActivityAudit()
            body(&row)
            rows[key] = row
        }
        for label in labels {
            mutate(activityKey(for: label.activity)) { $0.labelled += 1 }
        }
        for pair in matchedPairs {
            let label = labels[pair.label]
            let key = activityKey(for: label.activity)
            mutate(key) {
                $0.matched += 1
                if suggestions[pair.suggestion].predictedClass != expectedClass(for: label.activity) {
                    $0.sportMistakes += 1
                }
            }
        }
        for (index, label) in labels.enumerated() where !matchedLabels.contains(index) {
            mutate(activityKey(for: label.activity)) { $0.missed += 1 }
        }
        for (index, suggestion) in suggestions.enumerated() where !matchedSuggestions.contains(index) {
            let overlappingLabel = labels.indices
                .filter {
                    min(suggestion.workout.endSec, labels[$0].endSec)
                        - max(suggestion.workout.startSec, labels[$0].startSec) > 0
                }
                .max { lhs, rhs in
                    let a = min(suggestion.workout.endSec, labels[lhs].endSec)
                        - max(suggestion.workout.startSec, labels[lhs].startSec)
                    let b = min(suggestion.workout.endSec, labels[rhs].endSec)
                        - max(suggestion.workout.startSec, labels[rhs].startSec)
                    return a < b
                }
            if let overlappingLabel {
                mutate(activityKey(for: labels[overlappingLabel].activity)) { $0.duplicates += 1 }
            } else {
                mutate(activityKey(for: suggestion.predictedClass)) { $0.falsePrompts += 1 }
            }
        }
        return WorkoutSuggestionAuditReport(byActivity: rows, cost: cost)
    }

    /// Coarse ground-truth mapping. Unsupported activities remain `.other`; a specific classifier guess
    /// for one is therefore counted as a mistake instead of pretending the model knows that sport.
    public static func expectedClass(for activity: String) -> CoarseWorkoutClass {
        let key = activityKey(for: activity)
        switch key {
        case "walk": return .walk
        case "run": return .run
        case "strength": return .strength
        case "cycle": return .cycle
        case "ski": return .ski
        default: return .other
        }
    }

    public static func activityKey(for activity: String) -> String {
        let value = activity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["walking", "walk", "hiking", "treadmill walk", "nordic walking"].contains(value) { return "walk" }
        if ["running", "run", "treadmill run"].contains(value) { return "run" }
        if ["strength", "strength training", "bodybuilding", "weightlifting", "powerlifting",
            "calisthenics", "crossfit"].contains(value) { return "strength" }
        if ["cycling", "cycle", "indoor cycle", "mountain biking", "spinning"].contains(value) { return "cycle" }
        if ["skiing", "ski", "snowboarding"].contains(value) { return "ski" }
        return "other"
    }

    public static func activityKey(for prediction: CoarseWorkoutClass) -> String {
        prediction.rawValue
    }
}
