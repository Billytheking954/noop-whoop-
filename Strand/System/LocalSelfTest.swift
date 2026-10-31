import Foundation
import WhoopStore
import os.signpost

/// Local-only timing of the first successful repository cache publication. This is NOT a measurement of when
/// individual Today cards finish loading. One sample per app process, stored as small scalars.
@MainActor
enum ColdLaunchTrace {
    private static let performanceLog = OSLog(subsystem: "com.noopapp.noop", category: "Startup")

    struct Phase {
        let name: String
        let id: OSSignpostID
        let start: TimeInterval
    }

    /// Local Instruments intervals; names and durations only, never health values.
    static func beginPhase(_ name: String) -> Phase {
        let phase = Phase(name: name, id: OSSignpostID(log: performanceLog),
                          start: ProcessInfo.processInfo.systemUptime)
        os_signpost(.begin, log: performanceLog, name: "Saved dashboard", signpostID: phase.id,
                    "%{public}@", name)
        return phase
    }

    static func endPhase(_ phase: Phase) {
        let seconds = ProcessInfo.processInfo.systemUptime - phase.start
        os_signpost(.end, log: performanceLog, name: "Saved dashboard", signpostID: phase.id,
                    "%{public}@ %.3f seconds", phase.name, seconds)
        // Keep just the first duration for each phase of THIS launch, so the
        // Test Centre can identify a slow stage without connecting Instruments.
        let key = prefix + "phase." + phase.name
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(seconds, forKey: key)
        }
    }

    static let phaseNames = ["source-setup", "repository-refresh", "repository-reads",
                             "repository-merge", "today-day", "today-sleep", "today-stress", "today-history"]
    struct Snapshot {
        let seconds: Double
        let cacheLoaded: Bool
        let cachedDays: Int
        let todayDataLoadSeconds: Double?
    }

    private static var processStartUptime: TimeInterval?
    private static var firstTodayStartUptime: TimeInterval?
    private static let prefix = "noop.diagnostics.coldRootLoad."

    static func begin() {
        let start = ProcessInfo.processInfo.systemUptime
        processStartUptime = start
        firstTodayStartUptime = start
        // A failed new launch must not display an older launch's timing as current.
        for suffix in ["seconds", "cacheLoaded", "cachedDays", "todayDataLoadSeconds"] {
            UserDefaults.standard.removeObject(forKey: prefix + suffix)
        }
        for name in phaseNames {
            UserDefaults.standard.removeObject(forKey: prefix + "phase." + name)
        }
    }

    /// First completed Today data computation, not the first drawn frame or
    /// a promise that every card is populated. One value per app process.
    static func finishTodayDataLoad() {
        guard let started = firstTodayStartUptime else { return }
        firstTodayStartUptime = nil
        let seconds = ProcessInfo.processInfo.systemUptime - started
        guard seconds.isFinite, seconds >= 0 else { return }
        UserDefaults.standard.set(seconds, forKey: prefix + "todayDataLoadSeconds")
    }

    static func finish(cacheLoaded: Bool, cachedDays: Int) {
        guard let started = processStartUptime else { return }
        processStartUptime = nil
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        guard elapsed.isFinite, elapsed >= 0 else { return }
        let defaults = UserDefaults.standard
        defaults.set(elapsed, forKey: prefix + "seconds")
        defaults.set(cacheLoaded, forKey: prefix + "cacheLoaded")
        defaults.set(max(0, cachedDays), forKey: prefix + "cachedDays")
    }

    static func latest() -> Snapshot? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: prefix + "seconds") != nil else { return nil }
        let seconds = defaults.double(forKey: prefix + "seconds")
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let todaySeconds = defaults.object(forKey: prefix + "todayDataLoadSeconds") == nil
            ? nil : defaults.double(forKey: prefix + "todayDataLoadSeconds")
        return Snapshot(seconds: seconds,
                        cacheLoaded: defaults.bool(forKey: prefix + "cacheLoaded"),
                        cachedDays: defaults.integer(forKey: prefix + "cachedDays"),
                        todayDataLoadSeconds: todaySeconds)
    }
}

/// On-demand read-only diagnostic. No BLE command, HealthKit request, database mutation,
/// backup modification, refresh or forced connection. This does not prove that all health
/// cards are accurate; it distinguishes a stored-day/cache gap from absence of stored days.
@MainActor
enum LocalSelfTest {
    enum CacheVerdict: Equatable {
        case present
        case storedDaysNotInCache
        case inconclusive
    }

    static func cacheVerdict(persistedDays: Set<String>?, cachedDays: Set<String>,
                             cacheLoaded: Bool) -> CacheVerdict {
        guard cacheLoaded, let persistedDays else { return .inconclusive }
        // Apple-only vital and activity-step days can legitimately appear in cache
        // without having an imported/computed WHOOP daily row.
        if persistedDays.isEmpty { return .inconclusive }
        if !persistedDays.subtracting(cachedDays).isEmpty { return .storedDaysNotInCache }
        return .present
    }

    struct Result {
        let text: String
        let needsAttention: Bool
    }

    static func run(repo: Repository, now: Date = Date()) async -> Result {
        let start = ProcessInfo.processInfo.systemUptime
        // Calendar arithmetic preserves the intended local-day range across DST.
        let fromDay = Repository.dayString(Calendar.current.date(byAdding: .day, value: -120, to: now) ?? now)
        let toDay = Repository.dayString(Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now)
        let loadedAtStart = repo.loaded
        let cachedAtStart = repo.days.filter { $0.day >= fromDay && $0.day <= toDay }.count

        var lines = [
            "NOOP local self-test (read only)",
            "Recent-day comparison: last 120 days",
            "Cache loaded at test start: \(loadedAtStart ? "yes" : "no")",
            "Recent days in dashboard cache: \(cachedAtStart)"
        ]
        if let trace = ColdLaunchTrace.latest() {
            lines.append(String(format: "Time to first successful local cache publication: %.2fs", trace.seconds))
            lines.append("First cache publication completed with cache loaded: \(trace.cacheLoaded ? "yes" : "no")")
            lines.append("First cache publication cached days (all available history): \(trace.cachedDays)")
            if let today = trace.todayDataLoadSeconds {
                lines.append(String(format: "Time to first completed Today data calculation: %.2fs", today))
            } else {
                lines.append("Time to first completed Today data calculation: not recorded yet")
            }
            lines.append("Note: these times do not measure first frame paint or prove every card is populated.")
            for name in ColdLaunchTrace.phaseNames {
                let key = "noop.diagnostics.coldRootLoad.phase." + name
                if let seconds = UserDefaults.standard.object(forKey: key) as? Double {
                    lines.append(String(format: "First %@ interval: %.3fs", name, seconds))
                }
            }
        } else {
            lines.append("Time to first local cache publication: not recorded")
        }

        guard let store = repo.existingStoreForDiagnostics() else {
            lines.append("LOCAL STORE: NOT OPEN YET. Re-run after dashboard loading; no database was opened by this test.")
            lines.append("This diagnostic initiated no Bluetooth sync, HealthKit read, reset or backup change.")
            return Result(text: lines.joined(separator: "\n"), needsAttention: true)
        }

        // Match the two WHOOP daily source unions that refresh() merges into
        // dashboard days. Apple daily vitals populate the separate vitalRows cache
        // and activity-file steps can be absent/filtered, so treating those as
        // required dashboard days would create false missing-history alarms.
        let ids = Array(Set(repo.importedReadIds + repo.computedReadIds)).sorted()
        var persistedDays = Set<String>()
        var failedReads = 0
        for id in ids {
            do {
                let rows = try await store.dailyMetrics(deviceId: id, from: fromDay, to: toDay)
                persistedDays.formUnion(rows.map(\.day))
            } catch {
                failedReads += 1
            }
        }

        let cachedDayKeys = Set(repo.days.filter { $0.day >= fromDay && $0.day <= toDay }.map(\.day))
        let cachedNow = cachedDayKeys.count
        let missingCount = persistedDays.subtracting(cachedDayKeys).count
        let verdict = cacheVerdict(persistedDays: failedReads == 0 ? persistedDays : nil,
                                   cachedDays: cachedDayKeys, cacheLoaded: repo.loaded)
        lines.append("Local daily-metric read: \(failedReads == 0 ? "completed" : "INCOMPLETE (\(failedReads) source errors)")")
        lines.append("Recent distinct imported/computed WHOOP days in local storage: \(failedReads == 0 ? String(persistedDays.count) : "unknown")")
        lines.append("Recent days currently in dashboard cache: \(cachedNow)")
        if failedReads == 0 { lines.append("Stored WHOOP days not in cache: \(missingCount)") }
        switch verdict {
        case .present:
            lines.append("CACHE CHECK: PASS for sampled imported/computed WHOOP days; individual cards remain unverified.")
        case .storedDaysNotInCache:
            lines.append("CACHE CHECK: INVESTIGATE. Saved imported/computed WHOOP days are absent from the dashboard cache.")
        case .inconclusive:
            lines.append("CACHE CHECK: INCONCLUSIVE. Loading or source reads could not be compared.")
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        if elapsed.isFinite && elapsed >= 0 {
            lines.append(String(format: "Self-test runtime: %.2fs", elapsed))
        }
        lines.append("This diagnostic initiated no Bluetooth sync, HealthKit read, reset or backup change.")
        lines.append("No SQLite integrity scan or full-history verification was performed.")
        lines.append("Blank cards or a recent-day mismatch are NOT by themselves proof of data loss.")
        return Result(text: lines.joined(separator: "\n"),
                      needsAttention: failedReads > 0 || verdict != .present)
    }
}
