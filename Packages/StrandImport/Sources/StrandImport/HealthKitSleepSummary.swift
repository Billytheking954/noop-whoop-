import Foundation

/// Resolves the overlapping category samples returned by an iOS HealthKit sleep query.
/// This is a read-side HealthKit adapter, not a physiological sleep classifier. Android's
/// Health Connect and file import paths have different inputs and do not use this adapter.
/// Callers supply one wake-day bucket; this helper does not infer nights or source priority.
public enum HealthKitSleepSummary {
    public struct Interval: Sendable, Equatable {
        public let stage: SleepStage
        public let start: Date
        public let end: Date

        public init(stage: SleepStage, start: Date, end: Date) {
            self.stage = stage
            self.start = start
            self.end = end
        }
    }

    public enum Status: Sendable, Equatable {
        case noSleep
        case completeStages
        case incompleteStages
        case conflictingSleepWake
    }

    public struct Result: Sendable, Equatable {
        public let asleepMin: Double?
        public let deepMin: Double?
        public let remMin: Double?
        public let coreMin: Double?
        /// Union of intervals with an asleep assertion, including disputed sleep/wake spans.
        /// Diagnostic evidence only: use `asleepMin` for a displayable sleep total.
        public let observedAsleepMin: Double
        /// Sleep whose explicit stage is absent or disputed; never assigned to core/light.
        public let unspecifiedAsleepMin: Double
        /// Overlap between awake and any asleep assertion. A positive value withholds totals.
        public let conflictingMin: Double
        /// Overlap between different explicit asleep stages, counted as unspecified sleep.
        public let stageConflictMin: Double
        public let rejectedIntervalCount: Int
        public let status: Status
    }

    /// Counts each observed half-open interval once. An unspecified sleep overlay does not
    /// erase a known stage. Different explicit stages produce unspecified sleep; awake/sleep
    /// disagreement withholds the total. Gaps are neither sleep nor wake and are never filled.
    /// Stage totals are exposed only when every observed asleep span has one explicit stage.
    public static func summarize(_ intervals: [Interval], window: DateInterval? = nil) -> Result {
        struct Event {
            let time: Double
            let stage: String
            let delta: Int
        }
        var events: [Event] = []
        var rejected = 0
        let lower = window?.start.timeIntervalSinceReferenceDate ?? -.infinity
        let upper = window?.end.timeIntervalSinceReferenceDate ?? .infinity
        let windowValid = window == nil || (lower.isFinite && upper.isFinite && upper > lower)
        for interval in intervals {
            let start = interval.start.timeIntervalSinceReferenceDate
            let end = interval.end.timeIntervalSinceReferenceDate
            guard windowValid, start.isFinite, end.isFinite, end > start else {
                rejected += 1
                continue
            }
            // In-bed is not evidence of sleep. An unrecognised category supplies no state.
            guard interval.stage != .inBed, interval.stage != .unknown else { continue }
            let lo = max(start, lower), hi = min(end, upper)
            guard hi > lo else { continue }
            events.append(Event(time: lo, stage: interval.stage.rawValue, delta: 1))
            events.append(Event(time: hi, stage: interval.stage.rawValue, delta: -1))
        }
        events.sort { $0.time < $1.time }
        var active: [String: Int] = [:]
        var asleep = 0.0, unspecified = 0.0, conflicting = 0.0, stageConflict = 0.0
        var deep = 0.0, rem = 0.0, core = 0.0
        var i = 0
        while i < events.count {
            let time = events[i].time
            // Apply all events at a boundary together: touching intervals never overlap.
            while i < events.count, events[i].time == time {
                let event = events[i]
                active[event.stage, default: 0] += event.delta
                i += 1
            }
            guard i < events.count else { break }
            let minutes = (events[i].time - time) / 60
            let hasDeep = active[SleepStage.asleepDeep.rawValue, default: 0] > 0
            let hasRem = active[SleepStage.asleepREM.rawValue, default: 0] > 0
            let hasCore = active[SleepStage.asleepCore.rawValue, default: 0] > 0
            let explicitCount = [hasDeep, hasRem, hasCore].filter { $0 }.count
            let hasUnspecified = active[SleepStage.asleepUnspecified.rawValue, default: 0] > 0
            guard explicitCount > 0 || hasUnspecified else { continue }
            asleep += minutes
            if active[SleepStage.awake.rawValue, default: 0] > 0 {
                conflicting += minutes
            }
            if explicitCount != 1 {
                unspecified += minutes
                if explicitCount > 1 { stageConflict += minutes }
            } else if hasDeep {
                deep += minutes
            } else if hasRem {
                rem += minutes
            } else {
                core += minutes
            }
        }
        let status: Status = conflicting > 0 ? .conflictingSleepWake
            : asleep == 0 ? .noSleep
            : unspecified > 0 ? .incompleteStages : .completeStages
        let complete = status == .completeStages
        return Result(asleepMin: asleep > 0 && conflicting == 0 ? asleep : nil,
                      deepMin: complete ? deep : nil, remMin: complete ? rem : nil,
                      coreMin: complete ? core : nil, observedAsleepMin: asleep,
                      unspecifiedAsleepMin: unspecified, conflictingMin: conflicting,
                      stageConflictMin: stageConflict, rejectedIntervalCount: rejected,
                      status: status)
    }
}
