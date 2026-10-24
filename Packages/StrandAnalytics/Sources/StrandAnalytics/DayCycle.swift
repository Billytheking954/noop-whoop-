import Foundation

public enum DayCycleMode: String, CaseIterable, Sendable {
    case sleepOnset = "sleep_onset"
    case midnight = "midnight"

    public static let storageKey = "noop.dayCycleMode"
    /// Kotlin twin: `DayCycleMode.fromPersisted`.
    public static func persisted(_ value: String?) -> DayCycleMode {
        value.flatMap(Self.init(rawValue:)) ?? .sleepOnset
    }
}

public struct DayCycleWindow: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case detectedSleep, editedSleep, syntheticMidnight, calendar }
    public let id: String
    public let startInclusive: Int
    public let endExclusive: Int
    public let displayDay: String
    public let source: Source

    public init(id: String, startInclusive: Int, endExclusive: Int, displayDay: String, source: Source) {
        self.id = id; self.startInclusive = startInclusive; self.endExclusive = endExclusive
        self.displayDay = displayDay; self.source = source
    }
}

public enum DayCycleResolver {
    public static let minSyntheticMidnightAgeSeconds = 18 * 3_600
    public static let absoluteMaxOpenSeconds = 40 * 3_600

    /// Resolve a cycle boundary using the time zone's actual calendar rules. The fixed-offset
    /// overload remains for legacy pure callers; production passes a time zone so a midnight on
    /// either side of a DST transition is never approximated as an 86,400-second block.
    public static func calendarWindow(now: Int, timeZone: TimeZone) -> DayCycleWindow {
        let instant = Date(timeIntervalSince1970: TimeInterval(now))
        let resolver = LocalDayWindows(timeZone: timeZone, referenceInstant: instant)
        let date = resolver.localDate(of: instant)
        guard let window = resolver.window(of: date) else {
            // Defensive fallback for an invalid platform time-zone database. This branch cannot be
            // reached with ordinary Foundation zones; keep the existing API's total return contract.
            return calendarWindow(now: now, offsetSec: timeZone.secondsFromGMT(for: instant))
        }
        let start = Int(window.start.timeIntervalSince1970)
        return DayCycleWindow(id: "calendar:\(window.date.key)", startInclusive: start,
                              endExclusive: now, displayDay: window.date.key, source: .calendar)
    }

    /// The first actual local midnight at or after the synthetic-boundary minimum. Both the minimum
    /// instant and each candidate date are resolved through the zone rules, so a transition day may
    /// correctly be 23 or 25 hours long.
    public static func fallbackMidnight(after start: Int, timeZone: TimeZone) -> Int {
        let minimum = start + minSyntheticMidnightAgeSeconds
        let instant = Date(timeIntervalSince1970: TimeInterval(minimum))
        let resolver = LocalDayWindows(timeZone: timeZone, referenceInstant: instant)
        let date = resolver.localDate(of: instant)
        if let sameDay = resolver.window(of: date) {
            let candidate = Int(sameDay.start.timeIntervalSince1970)
            if candidate >= minimum { return candidate }
            if let nextDay = resolver.window(of: date.adding(days: 1)) {
                return Int(nextDay.start.timeIntervalSince1970)
            }
        }
        // Defensive fallback only; keep a total API if Foundation cannot resolve an exotic zone date.
        return fallbackMidnight(after: start, offsetSec: timeZone.secondsFromGMT(for: instant))
    }

    /// Zone-aware overload used by production; existing fixed-offset callers remain source-compatible.
    public static func activeWindow(mode: DayCycleMode, latestSleep: DayCycleWindow?, now: Int,
                                    timeZone: TimeZone) -> DayCycleWindow {
        guard mode == .sleepOnset, let latestSleep else {
            return calendarWindow(now: now, timeZone: timeZone)
        }
        let age = now - latestSleep.startInclusive
        let fallback = fallbackMidnight(after: latestSleep.startInclusive, timeZone: timeZone)
        // Sleep-onset mode stays anchored across midnight unconditionally: only the absolute safety cap
        // may synthesize a fallback boundary. The fallback is a real local midnight, not a rounded
        // fixed-offset approximation.
        guard age < absoluteMaxOpenSeconds else {
            let instant = Date(timeIntervalSince1970: TimeInterval(fallback))
            let day = LocalDayWindows(timeZone: timeZone, referenceInstant: instant).dayKey(for: instant)
            return DayCycleWindow(id: "synthetic:\(day)", startInclusive: fallback, endExclusive: now,
                                  displayDay: day, source: .syntheticMidnight)
        }
        return DayCycleWindow(id: latestSleep.id, startInclusive: latestSleep.startInclusive,
                              endExclusive: now, displayDay: latestSleep.displayDay, source: latestSleep.source)
    }

    /// Kotlin twin: `DayCycleResolver.calendarWindow`.
    public static func calendarWindow(now: Int, offsetSec: Int) -> DayCycleWindow {
        let local = now + offsetSec
        let dayNumber = Int(floor(Double(local) / Double(SleepStageTotals.secondsPerDay)))
        let start = dayNumber * SleepStageTotals.secondsPerDay - offsetSec
        let day = AnalyticsEngine.dayString(start, offsetSec: offsetSec)
        return DayCycleWindow(id: "calendar:\(day)", startInclusive: start, endExclusive: now,
                              displayDay: day, source: .calendar)
    }

    /// Kotlin twin: `DayCycleResolver.fallbackMidnightAfter`.
    public static func fallbackMidnight(after start: Int, offsetSec: Int) -> Int {
        let minimum = start + minSyntheticMidnightAgeSeconds
        let local = minimum + offsetSec
        let dayNumber = Int(floor(Double(local) / Double(SleepStageTotals.secondsPerDay)))
        let midnight = dayNumber * SleepStageTotals.secondsPerDay - offsetSec
        return midnight >= minimum ? midnight : (dayNumber + 1) * SleepStageTotals.secondsPerDay - offsetSec
    }

    /// Kotlin twin: `DayCycleResolver.activeWindow`.
    public static func activeWindow(mode: DayCycleMode, latestSleep: DayCycleWindow?, now: Int,
                                    offsetSec: Int) -> DayCycleWindow {
        guard mode == .sleepOnset, let latestSleep else { return calendarWindow(now: now, offsetSec: offsetSec) }
        let age = now - latestSleep.startInclusive
        let fallback = fallbackMidnight(after: latestSleep.startInclusive, offsetSec: offsetSec)
        // Sleep-onset mode stays anchored across midnight unconditionally: only the absolute safety cap
        // may synthesize a fallback boundary. An earlier design gated this on whether awake coverage was
        // reliable and carried a `reliableAwakeCoverage` parameter for it; the gate was dropped but the
        // parameter survived, unread on both platforms and passed `false` by every one of its five call
        // sites. Removed rather than left looking like a switch someone could flip.
        guard age < absoluteMaxOpenSeconds else {
            let day = AnalyticsEngine.dayString(fallback, offsetSec: offsetSec)
            return DayCycleWindow(id: "synthetic:\(day)", startInclusive: fallback, endExclusive: now,
                                  displayDay: day, source: .syntheticMidnight)
        }
        return DayCycleWindow(id: latestSleep.id, startInclusive: latestSleep.startInclusive,
                              endExclusive: now, displayDay: latestSleep.displayDay, source: latestSleep.source)
    }
}
