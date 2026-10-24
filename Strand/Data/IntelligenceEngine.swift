Warning: truncated output (original token count: 70854)
Total output lines: 3619

import Dispatch
import Foundation
import Combine
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// On-device "intelligence": computes recovery / day-strain / sleep from the raw strap streams using
/// the same model shape WHOOP uses (HRV vs personal baseline ~60%, resting HR ~20%, sleep ~15%,
/// respiration ~5%; strain 0–21 from cardiovascular load). This is what makes NOOP independent of
/// WHOOP's cloud , for any day the strap collected raw data with NOOP connected, NOOP scores it
/// itself rather than relying on the values WHOOP computed in the imported CSV.
@MainActor
final class IntelligenceEngine: ObservableObject {
    /// Minimum raw HR samples a day needs before it is scored at all. Mirrors the Kotlin
    /// `IntelligenceEngine.MIN_HR_SAMPLES`, which has been a named constant there while this side carried
    /// the literal in more than one place — so a threshold change had to find every copy on this platform
    /// and exactly one on the other.
    /// Spelled `IntelligenceEngine.minHrSamples` at both use sites rather than `Self.` — both are inside
    /// the `Task.detached` @Sendable closure, and the explicit type name cannot raise a dynamic-`Self` or
    /// closure-capture question there. No app-target Swift compiles outside app-build, so the boring form
    /// is worth the few characters.
    static let minHrSamples = 200

    private let dayCycleCache = DayCycleIntelligenceIntegration.Cache()
    private let repo: Repository
    private let profile: ProfileStore
    /// The CANONICAL id under whose `-noop` sibling this engine WRITES the computed daily rows, and from
    /// which it reads the imported-only baseline (`hist`). STABLE on "my-whoop", it must NOT follow the
    /// active strap, or a remove+re-add would orphan the computed history banked under the canonical id
    /// (the #814 follow-up union model). The engine still reads + scores a re-added strap's RAW streams:
    /// per-day owner resolution (`resolveDayOwner`) reads the registry's OWN active id directly (`regActiveId`
    /// below) and pulls each day's raw under the resolved owner, then persists the result to this STABLE
    /// canonical `-noop` sibling. The Repository's union read then surfaces both the canonical computed
    /// history and the active strap's live data together. So this never moves after construction.
    private let deviceId: String

    @Published var results: [Computed] = []      // newest first
    @Published var computing = false
    @Published var note: String?

    /// #899-A re-arm: a `force: true` recompute (a post-backfill rescore AppModel kicks off after a sync)
    /// that arrives while an idle-tick pass already holds the `computing` lock would otherwise be SILENTLY
    /// dropped, so a freshly-synced night intermittently never gets re-scored until the next cycle and Today
    /// falls back to the last scored day. Instead the dropped force sets this flag; the in-flight pass's
    /// `defer` re-invokes `analyzeRecent(force: true)` ONCE when it clears. A single re-arm (the flag is
    /// cleared BEFORE the re-invoke) bounds it to one extra pass , no recompute storm.
    private var pendingForcedRescore = false
    /// Uptime the pass holding `computing` started at, and how many days it covers; nil when none is running.
    private var runningPassStart: UInt64?
    private var runningPassDays = 0
    /// #899 heal bound: true while the last heal already re-armed a rescore, so a heal firing again on
    /// the very next pass cannot re-arm a second time (the Android twin is hard-bounded to exactly one
    /// re-pass; this mirrors it). Reset by any pass whose heal finds nothing, restoring the budget.
    private var healRearmedThisCycle = false

    /// #1005 BATTERY: in-memory per-day reuse for `analyzeRecent`'s pass-1 loop, keyed by day → (per-day
    /// cache key, the scored `DayScan`). On a heavy user (21 nights, ~178 k HR rows/night, a 1.26 GB store)
    /// every `newData` re-score re-read *every* night's raw streams and re-ran `analyzeDay`, even though a
    /// post-offload only ever adds rows to the 1–2 most-recent days — median ~4.6 min / pass, all CPU, fired
    /// back-to-back through an offload storm. Pass 1 already keeps only each night's small result (NOT the
    /// raw streams) and every field except recovery is baseline-independent, so a night whose scored inputs
    /// are unchanged since it was last scored re-produces a byte-identical `DayScan`: reuse it and skip the 7
    /// stream reads + `analyzeDay`. FAIL-SAFE — a miss, any un-cacheable owner, any active Test-Centre
    /// trace, or a config change all fall through to the identical full path; the cache only ever skips the
    /// analyzeDay STAGE, so pass 2 (baselines, recovery recompute, stale-day eviction, heal) is byte-
    /// unaffected and there is no banking / data-loss surface. In-memory + per-device; never persisted,
    /// never crosses `.noopbak`. The engine is a single long-lived instance (AppModel), so this survives the
    /// storm's back-to-back passes the drain is made of. See `AnalyzeRecentDayCache` (StrandAnalytics).
    private var dayScanCache: [String: (key: String, scan: DayScan)] = [:]
    /// UserDefaults key holding the persisted `stepsMotionCache` payload. Versioned in the key as well as
    /// in the payload header so a format change cannot even be read, let alone half-parsed.
    private static let stepsMotionCacheDefaultsKey = "analyzeRecent.stepsMotionCache.v1"
    /// Whether this process has already seeded `stepsMotionCache` from `stepsMotionCacheDefaultsKey`. The
    /// read happens once per process, not once per pass: after the first pass the in-memory cache is at
    /// least as fresh as the payload, so re-reading it could only ever put back what we just pruned.
    private var stepsMotionCacheLoaded = false
    /// The payload currently in UserDefaults, so an unchanged cache does not rewrite it. A pass that reused
    /// every day renders the string it read, and the passes that do so are the back-to-back ones an offload
    /// storm is made of — writing ~4 KB on each of them to store what is already there is the cost this
    /// avoids. Not an assumption about what the store does with an identical value: it simply is not asked.
    private var stepsMotionCachePersisted = ""
    /// Per-day steps-calibration motion folds, `[day: (key, motion)]`, keyed by `StepsMotionCache.cacheKey`.
    /// In-memory and per-process exactly like `dayScanCache`; see `StepsMotionCache` for why this one needs
    /// no config signature. Pruned to the calibration window each pass so it cannot grow without bound.
    private var stepsMotionCache: [String: (key: String, motion: Double)] = [:]
    /// The scoring-config signature the `dayScanCache` entries were produced under (profile / baselines1 /
    /// tz / sleep need+consistency / habitual midsleep / stager toggles). Those feed `analyzeDay` but are
    /// pass-global, not in the per-day key, so when the current pass's signature differs every cached scan is
    /// potentially stale and the whole cache is dropped. Empty until the first pass.
    private var dayScanCacheConfigSig = ""

    /// Names of the config-signature fields, in the exact order `dayCacheConfigSig` builds them.
    ///
    /// Kept beside the reader rather than at the construction site so that site stays a plain value list.
    /// The cost is that the two must stay in step, which `changedConfigField` refuses to guess about when
    /// they are not. Kotlin twin: `IntelligenceEngine.DAY_CACHE_CONFIG_FIELDS`.
    ///
    /// `nonisolated` for the same reason the reader below is: the engine is @MainActor, so a plain
    /// `static let` inherits that isolation, and neither a nonisolated function nor a synchronous test
    /// could then touch it. `[String]` is Sendable, so sharing it is safe.
    nonisolated static let dayCacheConfigFields: [String] = [
        "hrvBaseline", "rhrBaseline", "age", "sex", "stepTicksPerStep", "maxHROverride",
        "timeZone", "tzOffset", "sleepNeedHours", "sleepConsistency", "habitualMidsleep",
        "experimentalSleepV2", "motionAwareWake", "deepHrvWindow", "spo2CandidateDisplay",
        "effortMethod", "dayCycleMode",
    ]

    /// Which config field(s) moved between two signatures, for the `configDropped` tally.
    ///
    /// `configDropped` said a 21-day re-score happened because the pass-global config changed, and stopped
    /// there. A field log pointed at a rolling BASELINE as the likeliest mover, but naming it from the
    /// outside is a guess; this names it from the data.
    ///
    /// Never guesses: "first" on the first drop of a process, because the signature starts EMPTY rather
    /// than nil and there is nothing to diff against, and "unknown" when the two signatures do not have
    /// the field count this list describes, because a mislabelled field sends a reader somewhere the data
    /// never pointed.
    ///
    /// `nonisolated` because it is a pure function of its arguments: the engine is @MainActor, and without
    /// this the rule would inherit that isolation and could not be driven from a synchronous test.
    /// Kotlin twin: `IntelligenceEngine.changedConfigField`.
    nonisolated static func changedConfigField(previous: String, current: String) -> String {
        if previous.isEmpty { return "first" }
        let a = previous.split(separator: "|", omittingEmptySubsequences: false)
        let b = current.split(separator: "|", omittingEmptySubsequences: false)
        guard a.count == b.count, b.count == dayCacheConfigFields.count else { return "unknown" }
        let moved = b.indices.filter { a[$0] != b[$0] }.map { dayCacheConfigFields[$0] }
        return moved.isEmpty ? "none" : moved.joined(separator: "+")
    }

    /// Who supplies the dashboard headline for a By-Day row. The By-Day card always shows NOOP's OWN
    /// on-device numbers, but the WHOLE-DASHBOARD value for the same day can come from an IMPORTED row
    /// that won the per-day merge (imports win field-by-field over computed , see Repository.mergeDaily).
    /// We resolve the REAL provenance so the card's badge tells a strap-scored night apart from an
    /// imported one, instead of always claiming "NOOP-computed". (Sleep overhaul §2.6 honesty fix.)
    /// The `stages=` token of the per-day sleep diagnostic line (#386): `<deep>+<rem>+<light>=<sum>` in
    /// rounded minutes when the day carries a full banked stage split, `nil` when any component is
    /// absent (an unstaged night, or an imported day that only brought a total). The sum is printed
    /// rather than left to the reader so a rollup-vs-stages divergence — the exact identity a "homepage
    /// disagrees with the Sleep tab" report hinges on — is a one-line visual check against the
    /// `totalSleepMin=` field beside it. Pure; mirrors the Android `sleepStagesLogToken` byte-for-byte.
    static func sleepStagesLogToken(deep: Double?, rem: Double?, light: Double?) -> String {
        guard let deep, let rem, let light else { return "nil" }
        return "\(Int(deep.rounded()))+\(Int(rem.rounded()))+\(Int(light.rounded()))=\(Int((deep + rem + light).rounded()))"
    }

    enum DaySource: Equatable {
        /// NOOP scored this day itself from the raw strap streams; no import covers it.
        case computed
        /// A WHOOP export covers this day and wins the dashboard merge.
        case whoopImport
        /// An Apple Health import covers this day and wins the dashboard merge.
        case appleHealth

        /// The badge shown on the By-Day card. Brand wording matches the rest of the app
        /// (SleepView "On-device"/"Whoop", Today "Apple Health"). NO em-dashes.
        var badge: String {
            switch self {
            case .computed:    return String(localized: "On-device")
            case .whoopImport: return "Whoop"
            case .appleHealth: return "Apple Health"
            }
        }

        /// The short token for the per-day strap-log diagnostic (privacy-safe; no device ids leak).
        var logToken: String {
            switch self {
            case .computed:    return "computed"
            case .whoopImport: return "imported:whoop"
            case .appleHealth: return "imported:apple"
            }
        }

        /// Resolve a day's provenance from the imported day-key sets. A WHOOP export covering the day
        /// WINS the dashboard merge over our computed row (imports win field-by-field , Repository
        /// .mergeDaily), so it takes precedence; Apple Health is next; otherwise the day is purely
        /// computed. WHOOP-over-Apple matches the merge's source priority (whoopImport 0 < appleHealth 2
        /// in DailyMetricSource.vitalPriority). Pure + set-based so it's unit-tested directly and is the
        /// SAME logic `analyzeRecent` ships. Mirrors the Android `IntelligenceEngine.daySourceToken`. (§2.6)
        static func classify(day: String, importedWhoopDays: Set<String>,
                             appleHealthDays: Set<String>) -> DaySource {
            if importedWhoopDays.contains(day) { return .whoopImport }
            if appleHealthDays.contains(day) { return .appleHealth }
            return .computed
        }
    }

    /// One day's off-actor scan output (FIX 1). Carries the pure `AnalyticsEngine.DayResult` produced by
    /// the off-main scan loop plus the pre-computed RHR floor-vs-mean diagnostic line (#691) , computed
    /// inside the detached task from pure inputs so the main actor can replay it through the
    /// MainActor-bound `diagnosticSink` in the SAME per-day order. Deliberately NOT marked `Sendable`:
    /// its `AnalyticsEngine.DayResult` member isn't formally `Sendable` either, and the per-day loop ALREADY
    /// returned a `DayResult` across the `Task.detached` boundary under this project's `minimal` strict-
    /// concurrency setting (SWIFT_STRICT_CONCURRENCY: minimal, Swift 5 mode) , this wraps the same value
    /// type the same way, so it crosses the boundary identically.
    private struct DayScan {
        let result: AnalyticsEngine.DayResult
        let rhrLine: String?
        /// #1943 measure-only bin-population line (see `SleepStager.rhrBinGateLogLine`); nil on a clean
        /// night, replayed with `rhrLine` so the two read together.
        let rhrBinLine: String?
        /// #1331 respiratory diagnostic line (see `respRateLogLine`); replayed with `rhrLine`.
        let respLine: String?
        /// CAPTURE-B (#814/#799): the resolved READ owner id this day was scored from, and how many HR rows
        /// that owner returned for the night window, carried out of the off-actor loop so the main-actor
        /// fold can emit the universal `dayOwner …` self-diagnostic line (it needs the registry active id +
        /// provenance sets, which are resolved on the main actor).
        let readOwner: String
        let hrRows: Int
        /// Sleep & Rest test-mode gate-trace + Rest sub-score lines for this day, collected off the main
        /// actor and replayed through `diagnosticSink` tagged `.sleep` in per-day order. Empty unless the
        /// Sleep mode is active (the gate is read once before the loop), so the default path is unchanged.
        let sleepTrace: [String]
        /// Steps test-mode raw-counter trace lines (5/MG cumulative @57 series + wrap-aware deltas + dropped
        /// deltas) for this day, collected off the main actor and replayed tagged `.steps` in per-day order.
        /// Empty unless the Steps mode is active (the gate is read once before the loop), so the default path
        /// is byte-identical: the trace recomputes the SAME wrap-aware sum analyzeDay already computed.
        let stepsTrace: [String]
        /// HRV test-mode nightly trace lines (per-5-min-window RMSSD by sleep stage + the whole-night vs
        /// deep-only vs last-SWS summary) for this day, collected off the main actor and replayed tagged
        /// `.hrv` in per-day order. Empty unless the HRV mode is active. (#141)
        let hrvTrace: [String]
        /// #195: the ALWAYS-ON whole-night HRV cleaning summary (`hrv diag …`), built off the main actor
        /// where `rr` is in scope and replayed through `diagnosticSink` in pass 2 (which is main-actor
        /// isolated). nil when the night has no in-sleep R-R.
        let hrvDiag: String?
        /// #103/queue-11a: the nightly SpO₂ candidate mean for this day, computed off the main actor when
        /// the SpO₂ candidate display toggle is ON. A WHOOP owner gets the `spo2_candidate_82` V18Aux
        /// byte mean (unchanged); an Oura owner gets the ring's ceiling@100 `0x6F` mean
        /// (`AnalyticsEngine.nightlySpo2CeilingMean`, queue 11a). nil when the toggle is OFF or the
        /// night has no in-band reading for its owner's device. Written to metricSeries as
        /// "spo2_candidate" under the "-noop" device ID in pass 2 — same key for both devices, since the
        /// series is always read scoped to one device's own computed ID.
        let spo2Candidate: Int?
        /// #1118: whether this night's in-sleep R-R is OVER-COUNTED (`crossSecondOverCount` /
        /// `sameSecondOverCount`) — the WHOOP-4.0 two-optical-channel artifact that inflates R-R and
        /// contaminates the displayed HRV. nil when the night has no in-sleep R-R (no HRV to caveat).
        /// Persisted to metricSeries as "hrv_rr_overcount" (1/0) in pass 2 so the HRV card can flag the
        /// reading "unverified" until the de-dup fix lands. Same verdict the always-on `hrv diag` logs.
        let hrvOverCounted: Bool?
        /// #1169 SHADOW METRIC: the primary-session MEAN resting HR (PrimarySessionRestingHR, #1174) for this
        /// day, computed off the main actor beside the shipped nightly HR FLOOR (`daily.restingHr`). nil when
        /// no session clears the coverage gate. Written to metricSeries as "rhr_primary_session" in pass 2 —
        /// instrumentation only, never shown and never fed to any score.
        let primarySessionRHR: Double?
        /// #1169 coverage inputs for the shadow mean above (valid-sample count + primary-session duration),
        /// written as "rhr_primary_session_valid_samples" / "rhr_primary_session_duration_s" in pass 2. nil
        /// in lockstep with `primarySessionRHR`.
        let primarySessionRHRCoverage: PrimarySessionRestingHR.Coverage?
    }

    /// Exact pre-upgrade R-R-derived cells retained only while an unlabelled WHOOP 5 window is withheld.
    private struct LegacyScoreSnapshot {
        let avgHrv: Double
        let recovery: Double?
        let respRateBpm: Double?
        let avgSdnn: Double?
        let recoverySource: String?
    }

    struct Computed: Identifiable {
        let day: String
        let recovery: Double?
        let strain: Double?
        let sleepMin: Double?
        let hrv: Double?
        let rhr: Int?
        /// REAL provenance of the day's dashboard headline (computed vs an import that won the merge), so
        /// the By-Day badge is honest. Defaults to `.computed` (the engine always writes a computed row);
        /// set per day from the imported day-key sets resolved in `analyzeRecent`.
        var source: DaySource = .computed
        /// Charge (recovery) confidence for the day. Defaults `.solid` for a strap-scored night (the gauge
        /// already gates on the HRV baseline being usable); the Apple-Watch fold below sets this to the
        /// `WatchRecovery` confidence so a watch-only recovery reads "calibrating" until it has enough nights.
        var confidence: ScoreConfidence = .solid
        /// SHARED CONTRACT (engine <-> UI): the ordered "what shaped it" Charge driver list, biggest mover
        /// first. One row per term that actually fed the score (`RecoveryScorer.chargeDrivers`); empty when
        /// there is no score (cold-start) or for a non-strap row whose drivers we don't recompute. The UI
        /// renders one row per driver under the Charge ring and gates gracefully when this is empty.
        var drivers: [ChargeDriver] = []
        /// The night's skin temperature expressed as a RELATIVE deviation from the personal baseline
        /// (`RecoveryScorer.skinTempRelative`), or nil when no deviation is available. Surfaced as
        /// "+0.3 C vs your normal" with a relative tier tag; never a fake clinical absolute.
        var skinTempRel: SkinTempRelative? = nil
        var id: String { day }

        func withLegacyScore(hrv: Double, recovery: Double?) -> Computed {
            Computed(day: day, recovery: recovery, strain: strain, sleepMin: sleepMin, hrv: hrv, rhr: rhr,
                     source: source, confidence: confidence, drivers: drivers, skinTempRel: skinTempRel)
        }
    }

    /// Optional sink for the per-day scoring diagnostic, fed line-by-line into the SAME shareable strap
    /// log the user already exports (PII-scrubbed by `LiveState.append(log:)`). Defaults to nil so the
    /// engine stays testable with no UI. Each line is a concise, counts-only summary ("sleep day=…
    /// totalSleepMin=… matched=… source=…") so the next bug report ships proof of what was computed per
    /// day, addressing the project's log-failures-not-successes blind spot and the data needed to settle
    /// "Rest repeats across days". (Sleep overhaul §2.5.)
    /// `AppModel` wires it to `live.append(log:domain:)`. Each line is a concise, counts-only summary,
    /// optionally tagged with the TestDomain so the Sleep/Battery emitters land under their profile tag.
    var diagnosticSink: ((String, TestDomain?) -> Void)?

    init(repo: Repository, profile: ProfileStore, deviceId: String) {
        self.repo = repo; self.profile = profile; self.deviceId = deviceId
    }

    // NOTE (#814 union-model follow-up): the engine intentionally has NO `adoptActiveDeviceId`. Its write
    // target (`deviceId + "-noop"`) and imported-baseline read (`hist` under `deviceId`) stay STABLE on the
    // canonical "my-whoop" so a remove+re-add never orphans the computed history. The active strap's raw is
    // still read + scored per day via `resolveDayOwner` (which uses the registry's own active id), and the
    // result lands on the canonical `-noop` sibling; the Repository unions the canonical history with the
    // active strap's live data at read time.

    /// Median of a list (0 when empty) , used to denoise the 7-day resting-HR for Fitness Age.
    static func medianOf(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// The per-day RHR floor-vs-mean diagnostic line (#691). NOOP's `floor` is the WHOOP-style resting
    /// HR , the lowest SUSTAINED 5-min in-bed level (SleepStager picks the min 5-min rolling-mean HR per
    /// session, the day takes the .min() across them) , whereas a "sleeping HR" app reports the night MEAN
    /// over the whole asleep span. The mean always sits at-or-above the floor, so NOOP reading lower is BY
    /// DESIGN, not a bug; logging both makes a "NOOP RHR is lower than my other app" report explainable
    /// from the strap log. `inBedBpms` is the bpm of every HR sample inside a matched in-bed session (the
    /// SAME span the floor came from, so the two numbers are directly comparable). Empty in-bed → nightMean
    /// is "nil". Counts/bpm only , no timestamps or PII. Pure so it's unit-tested directly and is the SAME
    /// line `analyzeRecent` ships. Byte-identical to the Android `rhrFloorMeanLogLine`.
    /// #1331 diagnostic line: the night's computed respiratory rate (breaths/min) or "nil".
    ///
    /// When the rate is nil the line now carries WHY, because "nil" on its own sent an investigation
    /// across two subsystems to find out. The RSA estimate needs per-beat-accurate R-R, so
    /// `HRVAnalyzer.beatValuesAreTrustworthy` refuses a stream whose intervals are not beat-to-beat
    /// measurements — and on a WHOOP 4.0 carrying the #1008/#1118 over-count that gate is what empties
    /// the card, on nearly every night, silently. Printing the fraction beside the boundary turns
    /// "Respiratory: No data" from a mystery into a reading.
    ///
    /// It distinguishes the two cases rather than asserting one: below the boundary the gate refused the
    /// R-R; at or above it the gate passed and the cause is one of the estimator's other exits (too few
    /// beats, too short a span, too coarse a grid), which this deliberately does not guess between.
    /// Omitting `beatAccurate` restores the original one-field line exactly, so a night that never
    /// reached the HRV block reads as it always did.
    ///
    /// Byte-identical to the Android `respRateLogLine`.
    nonisolated static func respRateLogLine(day: String,
                                            respRateBpm: Double?,
                                            beatAccurate: Double? = nil,
                                            rrIntegrity: String? = nil) -> String {
        let base = "resp day=\(day) rpm=\(respRateBpm.map { String(format: "%.1f", $0) } ?? "nil")"
        guard respRateBpm == nil, let beatAccurate else { return base }
        // "NaN" explicitly rather than via %.2f: C-style %f renders a non-finite as "nan" while the
        // JVM renders it "NaN", so leaving it to the formatter would make the twin lines differ on
        // exactly the input the gate treats specially. One spelling, chosen here, on both platforms.
        let acc = beatAccurate.isNaN ? "NaN" : String(format: "%.2f", beatAccurate)
        let gate = String(format: "%.2f", HRVAnalyzer.beatAccuracyMinFraction)
        let integrity = rrIntegrity ?? "unknown"
        if beatAccurate < HRVAnalyzer.beatAccuracyMinFraction {
            return "\(base) beatAccurate=\(acc)<\(gate) rrIntegrity=\(integrity) — RSA gate refused the R-R"
        }
        return "\(base) beatAccurate=\(acc)>=\(gate) rrIntegrity=\(integrity) — gate passed, cause is elsewhere"
    }

    nonisolated static func rhrFloorMeanLogLine(day: String, floor: Int, inBedBpms: [Int]) -> String {
        let meanLog: String = inBedBpms.isEmpty ? "nil"
            : String(Int((Double(inBedBpms.reduce(0, +)) / Double(inBedBpms.count)).rounded()))
        return "rhr day=\(day) floor=\(floor) nightMean=\(meanLog) inBedSamples=\(inBedBpms.count) "
            + "(floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)"
    }

    /// #1244: one line for a day that CLEARED the ≥200-HR gate yet detected NO in-bed session, so the
    /// dashboard shows "HR tracked but no sleep". Today only the summary `sleep day=… totalSleepMin=nil`
    /// rides the log — with no clue WHY, since every other night trace (`rhr`/`rrsample`/`hrv diag`) only
    /// emits once a session exists. This names the raw inputs the stager was handed so the next capture
    /// separates the causes: `grav=0` = no motion offloaded (the in-bed detector can't gate — the WHOOP
    /// 4.0 sparse-motion path has no HR-only fallback); a large `hr` with a night still empty = coverage
    /// gap or the sleep hours fell outside `window`; `provided=` = a persisted hypnogram was (not) available.
    /// The END of the window the sleep pipeline reads for the night that finishes on `dayStart`'s day.
    ///
    /// A PAST day reads through to the next local midnight: the night may end any time before it — late
    /// sleepers, weekend lie-ins, shift workers who wake well after noon. A hard `dayStart + 18h` (6 PM)
    /// bound truncated the read at exactly 18:00 and reported a flat 18:00 wake (#500).
    ///
    /// **#500 follow-up — the half that was left broken.** TODAY kept the 18:00 cap, on the reasoning that
    /// "the store clamps to `now` anyway". That holds only for someone who wakes in the MORNING. A
    /// day-sleeper — asleep ~12:00, awake ~20:00 — is still inside today when they wake, so the cap cut the
    /// read three hours short and reported a flat 18:00 wake for the entire evening. At the next local
    /// midnight the day became PAST, the other branch took over, and the SAME night silently re-scored to
    /// the real time. That is exactly the reported symptom: *"it shows 18:00 every day no matter what time
    /// I wake up, then as soon as it hits 00:01 it updates to the actual wake time."* Not offload lag, not
    /// a stager gate, not clock drift — this bound.
    ///
    /// Today is now capped at `now`, which keeps the only property the old bound was there for — never read
    /// past the present — and is what that original comment already assumed was happening. It stops the
    /// window from asserting that nobody wakes after 6 PM.
    nonisolated static func sleepReadWindowEnd(dayStart: Int, nextDayStart: Int? = nil,
                                               nowLocalMidnight: Int, now: Int) -> Int {
        let nextMidnight = nextDayStart ?? (dayStart + 86_400)
        return dayStart < nowLocalMidnight ? nextMidnight : min(nextMidnight, now)
    }

    /// The provided session the NO-NIGHT line reports as `providedLongest` / `providedLongestEnd`: the
    /// longest, ties broken by the later END.
    ///
    /// The tie-break is the point. Selecting on duration alone left the OUTPUT undefined whenever two
    /// sessions ran the same length, because `Array.max(by:)` and Kotlin's `maxByOrNull` do not agree on
    /// which of two equal elements they keep, and the field actually printed is the END day. Two equal
    /// sessions ending on different days would then render differently on the two platforms from
    /// identical input, on a line whose whole contract is being byte-identical across them.
    ///
    /// Equal-length sessions are not a corner case: the HR-only spine works in fixed epochs, so
    /// durations are quantised and repeat. Ordering by (duration, end) makes any surviving tie one where
    /// both printed fields are equal anyway, so the output is deterministic even where the choice of
    /// element is not.
    ///
    /// Pure and `nonisolated` so both the picked duration and its day key are unit-tested directly;
    /// byte-identical twin of the Kotlin `longestProvidedForDiag`.
    nonisolated static func longestProvidedForDiag(_ sessions: [SleepSession]) -> SleepSession? {
        return sessions.max(by: { ($0.end - $0.start, $0.end) < ($1.end - $1.start, $1.end) })
    }

    /// Counts, a window length and day keys only — same privacy class as the sibling `sleep day=` line,
    /// no PII. Pure so
    /// it's unit-tested directly; byte-identical to the Android `sleepDetectNoNightLogLine`.
/// Fold the per-day diagnostic lines onto the one channel that already replays them.
    ///
    /// `hrvDiag` is not really "the HRV line" any more — it is the loop-1 diagnostic channel, replayed
    /// on the main actor by splitting on newlines. The Effort funnel rides it for the same reason the
    /// NO-NIGHT line does: built where the inputs are in scope, emitted where the sink is safe to touch.
    nonisolated static func mergedDayDiag(_ hrvDiag: String?, _ extra: [String]) -> String? {
        var parts: [String] = []
        if let hrvDiag, !hrvDiag.isEmpty { parts.append(hrvDiag) }
        parts.append(contentsOf: extra)
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    nonisolated static func sleepDetectNoNightLogLine(day: String, hrCount: Int, rrCount: Int,
                                                      respCount: Int, gravCount: Int, stepCount: Int,
                                                      providedCount: Int, providedEndingOnDay: Int,
                                                      providedLongestMin: Int?,
                                                      providedLongestEndDay: String?,
                                                      windowHours: Int,
                                                      skinCount: Int) -> String {
        // `reason` names WHICH absence this is, because grav=0 is printed but its consequence is not.
        //
        // `no-motion` USED to mean "and therefore nothing further was attempted" — the stager had no
        // HR-only fallback, so no quantity of HR could stage a night. Since #1801 it does: a day with no
        // gravity now also runs `SleepStager.hrOnlySessions`.
        //
        // Which is why grav=0 alone can no longer name the outcome. A 5/MG overnight capture showed this
        // line reading `no-motion` while the HR-only spine on the SAME pass kept four sessions, the
        // longest 311 minutes, and handed them over as `provided=3`. The reader was told nothing could
        // stage a night while the log above said something had. So the no-gravity case splits by whether
        // anything was actually provided:
        //
        //   no-motion                 no gravity, and nothing was provided either
        //   no-motion-provided-unused no gravity, sessions WERE provided, and the night is still empty —
        //                             they went in and no night came out, which is a question about what
        //                             dropped them rather than about the strap
        //
        // Note "provided", not "HR-only". With no gravity `providedSleep` is the HR-only spine's output
        // in the no-hypnogram branch, but it is STORED sessions in the stored-hypnogram one, and from
        // here the two are indistinguishable. Naming the source would repeat the very over-claim this
        // split exists to remove. The `[sleep] hr-only gate` trace is what says which branch ran.
        //
        // With motion present the inputs were there and staging still produced nothing, which remains the
        // case most worth investigating.
        let reason: String
        if gravCount > 0 {
            reason = "staged-none"
        } else {
            reason = providedCount > 0 ? "no-motion-provided-unused" : "no-motion"
        }
        // #1118 follow-up: name any stream that came back AT its read cap. A read that returns exactly the
        // limit is the definition of truncated everywhere else here (`full.count >= limit`), and it is the
        // one thing a reader cannot infer from the counts alone — `grav=192698` looks healthy until you
        // know the cap it is 96% of.
        //
        // GRAVITY is why this exists. HR and R-R ride a SlidingStreamWindow, which counts its own
        // truncations; gravity is a plain read with no counter at all, so a night clipped of its newest
        // motion staged badly and said nothing. That is the difference between "this release fixes your
        // night" and "your offload never ran", and a log could not tell them apart.
        var atCap: [String] = []
        // ONLY the plain reads. Gravity and skin are read whole, so a result of exactly the cap IS the
        // truncation — the same `count >= limit` test used everywhere else here, and neither stream has a
        // counter of its own, which is why this marker exists.
        //
        // HR and R-R are deliberately absent even though their counts are printed. They arrive through
        // `SlidingStreamWindow.rows`, which returns `full.filter { ts in from...to }` — a SLICE of a read
        // that usually spans more than this night. A spliced window that WAS truncated still hands back a
        // slice under the cap, so the marker would silently fail to fire: a false negative on a line whose
        // only value is that its absence means "not clipped". Their exact truncation count is already
        // printed unconditionally once per pass by `WindowedStreamPlan.logLine` (`hrTruncated=`), so
        // nothing is lost by declining to guess it per night.
        //
        // resp and steps are plain reads too, and equally judgeable, but stay unmarked on purpose: neither
        // is a staging input, so clipping one cannot be the reason a night is missing. Their counts are
        // printed as context. The marker answers "did a stream that could explain this get cut short",
        // not "was every read complete".
        if gravCount >= StreamReadCap.gravity { atCap.append("grav") }
        if skinCount >= StreamReadCap.skin { atCap.append("skin") }
        let capNote = atCap.isEmpty ? "" : " atCap=" + atCap.joined(separator: ",")
        // WHERE the provided sessions fall, which `provided=` alone does not say and which is the next
        // question every time this line reads `no-motion-provided-unused`.
        //
        // A session is attributed to a day by where it ENDS (`AnalyticsEngine.analyzeDay`, the
        // `tsInDay(it.end)` filter), so `provided=3` with an empty night means those three ended
        // somewhere else. Without that, the line stops one field short of its own conclusion: a real
        // 5/MG capture showed `provided=3` beside an HR-only spine reporting a 240-minute session, on a
        // night the wearer demonstrably slept, and a reader still could not tell whether the spine had
        // missed the night or the attribution had moved it. Those two want opposite fixes.
        //
        // `providedHere` is the count that DID end on this day, and is therefore the number the night
        // was built from: seeing 0 next to a non-zero `provided` is the whole diagnosis. The longest
        // session and its end day come along because the longest is the one that should have matched,
        // and naming its day says which neighbour absorbed it.
        //
        // Self-checking on purpose: `providedLongestEnd` equal to `day` while `providedHere` is 0 is a
        // contradiction, and points at the filter rather than at the spine.
        //
        // Only when something was actually provided. With `provided=0` the three fields say nothing
        // that `reason=no-motion` has not already said, and the sibling `atCap` note sets the precedent
        // for a suffix that appears only when it carries information.
        let providedNote: String
        if providedCount > 0 {
            providedNote = " providedHere=\(providedEndingOnDay)"
                + " providedLongest=\(providedLongestMin.map(String.init) ?? "nil")"
                + " providedLongestEnd=\(providedLongestEndDay ?? "nil")"
        } else {
            providedNote = ""
        }
        return "sleep-detect day=\(day) NO-NIGHT hr=\(hrCount) rr=\(rrCount) resp=\(respCount) "
            + "grav=\(gravCount) skin=\(skinCount) steps=\(stepCount) provided=\(providedCount)"
            + providedNote + " "
            + "window=\(windowHours)h reason=\(reason)" + capNote
    }

    /// #674/#1244: the "sleep total with no matched session" divergence line. A COMPUTED day whose fresh
    /// scoring pass matched ZERO detected sleep sessions yet still carries a non-nil totalSleepMin — the
    /// value comes from a folded edited/hand-logged block (sleepEditedDaily) on a day the detector staged
    /// nothing (often a day absorbed into a neighbour's coupled window, so it never got its own pass). That
    /// total leaks to Today/Coupled while the Sleep tab (session-backed) shows nothing. `editFold` = how
    /// many edited/manual rows folded a total onto this session-less day, so the next capture proves whether
    /// it's an orphaned edit. Counts only, no PII. Pure; byte-identical to the Kotlin `sleepDivergenceLogLine`.
    nonisolated static func sleepDivergenceLogLine(day: String, totalSleepMin: Int, editFold: Int) -> String {
        return "sleep divergence day=\(day) totalSleepMin=\(totalSleepMin) matched=0 editFold=\(editFold)"
    }

    /// #1248: the device ids the banked-sleep heal (#899) must sweep — the computed-scores id AND every
    /// registered device id. A live source (an Oura ring) banks its OWN hypnogram under its OWN device id,
    /// so a computedId-only heal never sees (or collapses) those rows, and they are re-read as
    /// `providedSleep` and re-detected every pass — one night ballooned to 14 stored rows / 9 phantom
    /// "naps". The de-duplicated union, sorted for a deterministic sweep order. Pure so it's unit-tested
    /// directly; byte-identical to the Android `healDeviceIds`.
    nonisolated static func healDeviceIds(computedId: String, registeredIds: [String]) -> [String] {
        Set([computedId] + registeredIds).sorted()
    }

    /// The Saturday on-or-before a "yyyy-MM-dd" local-day string , the weekly key Fitness Age writes to.
    static func saturdayKey(onOrBefore dayStr: String) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let fmt = DateFormatter(); fmt.calendar = cal; fmt.timeZone = cal.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        guard let d = fmt.date(from: dayStr) else { return dayStr }
        let back = cal.component(.weekday, from: d) % 7   // Sat(7)→0, Sun(1)→1 … Fri(6)→6
        let sat = cal.date(byAdding: .day, value: -back, to: d) ?? d
        return fmt.string(from: sat)
    }

    /// Assess Fitness Age readiness from `gateDays` (the merged last-7 the readiness card counts) and, when
    /// ready, build the fitness_age (+ optional vo2max) points for `satKey`. Empty when not ready. The
    /// SINGLE source of the gate + compute , shared by the recompute pass and the manual "refresh Fitness
    /// Age" button so the two can never drift. Profile passed as primitives (no cross-actor object read).
    /// Mirrors the Android `IntelligenceEngine.fitnessAgeRows`.
    static func fitnessAgeRows(
        gateDays: [DailyMetric], age: Int, sex: String, waistCm: Double, heightCm: Double, weightKg: Double,
        computedId: String, satKey: String,
    ) -> [MetricPoint] {
        let rhrs = gateDays.compactMap { $0.restingHr }.map(Double.init)
        let strains = gateDays.compactMap { $0.strain }.filter { $0 >= 30 }
        let meanStrain = strains.isEmpty ? 0 : strains.reduce(0, +) / Double(strains.count)
        let waist: Double? = waistCm > 0 ? waistCm : nil
        let ready = FitnessAgeEngine.assessReadiness(
            hasAge: age > 0, hasSex: !sex.isEmpty,
            rhrDays: rhrs.count, activityDays: gateDays.compactMap { $0.strain }.count,
            hasHeightWeight: heightCm > 0 && weightKg > 0, hasWaist: waist != nil)
        guard ready.canCompute,
              let res = FitnessAgeEngine.compute(
                age: Double(age), sex: sex,
                restingHR: medianOf(rhrs),
                paIndex: FitnessAgeEngine.physicalActivityIndexFromStrain(
                    activeDaysPerWeek: strains.count, meanActiveStrain: meanStrain),
                waistCm: waist) else { return [] }
        var rows = [MetricPoint(day: satKey, key: "fitness_age", value: res.fitnessAge)]
        // #1391: offer a VO₂max even without a waist. res.vo2max is the Nes 2011 waist-based estimate (nil
        // when no waist is set). Fall back to the Uth 2004 HR-ratio estimate (15.3·HRmax/RHR — waist-free,
        // the SAME formula the calorie path already uses), so any user past the age+RHR fitness-age gate gets
        // a (rougher) VO₂max instead of a blank. HRmax via the shared Tanaka estimator (no HR history here →
        // age-predicted); RHR = the same median the Nes value used. Both persist under "vo2max_est"; the card
        // labels it "Estimated". Mirrors the Android twin.
        let vo2 = res.vo2max
            ?? Calories.vo2maxFor(hrmax: StrainScorer.estimateHRmax([], age: Double(age)).0, restingHR: medianOf(rhrs))
        if let v = vo2 { rows.append(MetricPoint(day: satKey, key: "vo2max_est", value: v)) }
        return rows
    }

    /// Method metadata for a newly computed VO₂max point. Empty when `points` contains no VO₂max value.
    /// Method selection is captured at compute time; UI readers must never reconstruct it from today's
    /// profile because changing/removing a waist is a legitimate transition between estimators.
    static func vo2MaxProvenance(
        points: [MetricPoint], waistCm: Double
    ) -> [ScoreInputProvenanceRow] {
        guard let point = points.first(where: { $0.key == "vo2max_est" }) else { return [] }
        return [ScoreInputProvenanceRow(
            day: point.day,
            key: point.key,
            sourceId: Vo2MaxEstimator.forWaistCm(waistCm).rawValue
        )]
    }

    /// Manual "refresh Fitness Age" (the button on the not-ready card): recompute the weekly Fitness Age NOW
    /// from the PERSISTED merged daily history , NO raw-HR rescoring , and upsert it. Same gate
    /// (`fitnessAgeRows`) + date/window logic as the recompute pass, so it reads exactly what the readiness
    /// card shows. Light + works offline (stored data only). Returns true if a value was written. Mirrors
    /// the Android `recomputeFitnessAgeOnly`.
    func recomputeFitnessAgeOnly(maxDays: Int = 21) async -> Bool {
        guard let store = await repo.storeHandle() else { return false }
        let computedId = deviceId + "-noop"
        let nowDate = Date()
        let now = Int(nowDate.timeIntervalSince1970)
        let timeZone = TimeZone.current
        let windows = Self.localDayWindows(now: now, maxDays: maxDays, timeZone: timeZone)
        guard let newestWindow = windows.first, let oldestWindow = windows.last else { return false }
        let newestDay = newestWindow.date.key
        let oldestDay = oldestWindow.date.key
        let gate7 = Array((await repo.dailyMetrics(fromDay: oldestDay, toDay: newestDay))
            .sorted { $0.day < $1.day }.suffix(7))
        let rows = Self.fitnessAgeRows(
            gateDays: gate7, age: profile.age, sex: profile.sex, waistCm: profile.waistCm,
            heightCm: profile.heightCm, weightKg: profile.weightKg, computedId: computedId,
            satKey: Self.saturdayKey(onOrBefore: newestDay))
        if !rows.isEmpty {
            try? await store.persistMetricSeriesWithProvenance(
                points: rows,
                provenance: Self.vo2MaxProvenance(points: rows, waistCm: profile.waistCm),
                deviceId: computedId
            )
        }
        return !rows.isEmpty
    }

    /// Completion flag for the shared full-history Effort and sleep-wear repair pass.
    static let effortRescoreFlagKey = "intelligence.effortRescore.v313.done"

    /// One-shot, on-upgrade FULL-history Effort rescore (#313 PART B). The Effort hero gauge + numbers
    /// moved from the old 0–21 axis to NOOP's own 0–100 axis. On-device computed rows since v2.6.1
    /// already store 0–100, but rows the engine computed on an OLDER build (capped at `maxDays` per run,
    /// so deep history was never revisited) may still hold 0–21 strain.
    ///
    /// The SAFE fix is to recompute strain FROM SOURCE for every day with raw HR , those regenerate at
    /// 0–100 with NO double-rescale risk , rather than a blind `strain*21→100` multiply that would
    /// double-rescale the large population already on 0–100 (→ ~0–476). We do that by running the normal
    /// `analyzeRecent` once with the `maxDays` cap lifted to the full history, then persist a flag so it
    /// runs exactly once. IMPORTED rows are never rewritten here (the engine only ever writes under the
    /// "-noop" computed source) , those are handled by re-import. A day already on 0–100 is recomputed
    /// from the same raw HR and lands on 0–100 again: UNCHANGED axis (verified by test). This entry point
    /// now shares a pass with sleep-wear repair; cached-only days are preserved in both repairs.
    func runEffortRescoreIfNeeded(historyDays: Int = 4000) async {
        await runHistoryRepairIfNeeded(historyDays: historyDays)
    }

    /// Upgrade repair for nights rejected by an unmatched WRIST_OFF, including history older than
    /// the normal 21-day window. Reuses the full-history scoring path, including edited/dismissed
    /// sleep protection and dependent daily metrics. Both flags describe this shared pass: either
    /// pending flag triggers one run, and both are set only after every required write succeeds.
    /// Cached-only days are preserved, changing the old Effort-only repair from broad-window writes to
    /// writes only for days that were recomputed.
    static let sleepWearRescoreFlagKey = "intelligence.sleepWearRescore.v1.done"
    private var sleepWearRescoreRunning = false

    static func historyRepairIsPending(effortDone: Bool, sleepWearDone: Bool) -> Bool {
        !effortDone || !sleepWearDone
    }

    func runSleepWearRescoreIfNeeded(historyDays: Int = 4000) async {
        await runHistoryRepairIfNeeded(historyDays: historyDays)
    }

    private func runHistoryRepairIfNeeded(historyDays: Int) async {
        guard Self.historyRepairIsPending(
                  effortDone: UserDefaults.standard.bool(forKey: Self.effortRescoreFlagKey),
                  sleepWearDone: UserDefaults.standard.bool(forKey: Self.sleepWearRescoreFlagKey)),
              !sleepWearRescoreRunning, !computing, !Task.isCancelled,
              !RescoreBackgroundScheduler.isBackgrounded else { return }
        // Launch and scene activation can overlap while the store handle is being awaited.
        sleepWearRescoreRunning = true
        defer { sleepWearRescoreRunning = false }
        await analyzeRecent(maxDays: historyDays, triggerLabel: "sleep-wear-history-repair",
                            preserveUnscoredHistory: true) {
            UserDefaults.standard.set(true, forKey: Self.effortRescoreFlagKey)
            UserDefaults.standard.set(true, forKey: Self.sleepWearRescoreFlagKey)
        }
    }

    /// UserDefaults flag guarding the one-shot #547 implausible-timestamp DB heal (below). Set once the
    /// heal completes so it never re-runs.
    static let timestampHealFlagKey = "intelligence.timestampHeal.v547.done"

    /// #547 RE-POLLUTION re-arm: a one-shot heal isn't enough when a strap with a WANDERING clock keeps
    /// re-sending bad-dated records across syncs. Whenever a sync's ingest gate drops implausible records
    /// (the strap demonstrably has a bad clock THIS session), `BLEManager` sets this pending flag so the
    /// next analyze tick re-runs the purge , clearing any pollution that slipped in on an OLDER build whose
    /// gate was weaker, rather than permanently gating behind the one-shot `done` flag. Cleared once the
    /// re-heal runs. Pure UserDefaults so the BLE layer can set it without an engine reference.
    static let timestampHealPendingKey = "intelligence.timestampHeal.v547.pending"

    /// Mark the #547 heal as needing a re-run because a sync just dropped implausible (bad-clock) records.
    /// Called from `BLEManager.exitBackfilling` (no engine handle there); the next `runTimestampHealIfNeeded`
    /// honours it even after the one-shot `done` flag is set.
    static func requestTimestampReheal() {
        UserDefaults.standard.set(true, forKey: timestampHealPendingKey)
    }

    /// One-shot, on-upgrade heal of a database polluted by a bad-clock strap (#547, pikapik). The ingest
    /// gate now keeps garbage-timestamped records out, but a user who synced on an older build already has
    /// rows dated to scattered garbage (far-past, a bogus 2027, FUTURE dates) , which made one ~12h block
    /// re-attribute to every day (the repeated totalSleepMin=721 across many days) and a future row surface
    /// as the Today "last night" carry-over. This purges those rows ONCE, then rescores from the surviving
    /// real raw data so the genuine days recompute cleanly. Idempotent (a clean DB deletes nothing) and
    /// re-running is harmless, but a persisted flag skips it on every later launch. Runs BEFORE the normal
    /// `analyzeRecent` loop so the rescore it triggers operates on an already-cleaned DB.
    func runTimestampHealIfNeeded(historyDays: Int = 4000) async {
        // Run when the one-shot heal hasn't run yet OR a sync just flagged a re-heal (#547 re-pollution): a
        // wandering-clock strap re-sends bad-dated records across syncs, so a single on-upgrade pass can't
        // be the only line of defence. The pending flag is cleared below once the re-heal completes.
        let pending = UserDefaults.standard.bool(forKey: Self.timestampHealPendingKey)
        guard pending || !UserDefaults.standard.bool(forKey: Self.timestampHealFlagKey) else { return }
        guard let store = await repo.storeHandle() else { return }   // no store yet → retry next launch
        let result: WhoopStore.TimestampHealResult
        do {
            result = try await store.healImplausibleTimestamps()
        } catch {
            NSLog("IntelligenceEngine: timestamp heal (#547) FAILED , \(error); will retry next launch")
            return   // leave the flag unset so a transient failure retries
        }
        if result.didChange {
            diagnosticSink?("Heal(#547): purged \(result.rawRowsDeleted) raw + \(result.computedRowsDeleted) computed row(s) with implausible (bad-clock) timestamps; rescoring the real days.", nil)
            // Recompute the affected real days from the surviving raw rows so the polluted (e.g. 721)
            // blocks regenerate cleanly. The dashboard refresh happens inside analyzeRecent on persist.
            await analyzeRecent(maxDays: historyDays)
            // Only mark done once the rescore actually ran (wasn't skipped by a concurrent tick holding
            // the `computing` lock), so a skipped pass retries next launch , correctness over a one-time cost.
            guard !computing else { return }
        }
        UserDefaults.standard.set(true, forKey: Self.timestampHealFlagKey)
        // Clear the re-pollution request now that this re-heal has run , a future bad-clock sync re-arms it.
        UserDefaults.standard.set(false, forKey: Self.timestampHealPendingKey)
    }

    /// Compute on-device scores for each of the last `maxDays` that actually has raw HR data.
    /// Personal baselines (HRV / resting HR) are folded from the imported history, so even the first
    /// live night can be scored against your norm.
    func analyzeRecent(maxDays: Int = 21, force: Bool = true, skipIfUnchanged: Bool = false,
                       triggerLabel: String? = nil, preserveUnscoredHistory: Bool = false,
                       onPersisted: (() -> Void)? = nil) async {
        // #899-A: a concurrent pass already holds the lock. A NON-forced idle tick is safe to drop (the
        // in-flight pass already covers the same window). But a FORCED call is a real update path (a
        // post-backfill rescore after a sync) , dropping it would leave a freshly-synced night unscored
        // until the next cycle. Re-arm instead: flag it so the running pass's `defer` re-invokes once.
        guard !computing else {
            if force {
                // Said once per running pass, not per trigger: a pass that holds the lock for hours otherwise
                // turns every post-offload re-score into a silent no-op, and the log shows syncs but no scores.
                if !pendingForcedRescore, let started = runningPassStart {
                    let heldFor = Int(Double(DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000_000)
                    diagnosticSink?("re-score: queued behind a \(runningPassDays)-day pass running for \(heldFor) s", nil)
                }
                pendingForcedRescore = true
            }
            return
        }
        // #2607: claim the pass before either store await can admit another MainActor caller.
        // Even a pass that exits through a gate must release the claim and honor a forced
        // trigger queued while that gate was suspended.
        computing = true
        runningPassStart = DispatchTime.now().uptimeNanoseconds
        runningPassDays = maxDays
        defer {
            computing = false
            runningPassStart = nil
            if pendingForcedRescore {
                pendingForcedRescore = false
                // A forced update queued during the upgrade repair owes a normal recent pass,
                // not another full-history repair (#2606). Its completion belongs to this pass.
                let followUpDays = preserveUnscoredHistory ? 21 : maxDays
                Task {
                    await self.analyzeRecent(maxDays: followUpDays, force: true)
                }
            }
        }
        guard let store = await repo.storeHandle() else { note = String(localized: "No on-device store yet."); return }
        guard let hrvCfg = Baselines.metricCfg["hrv"],
              let rhrCfg = Baselines.metricCfg["resting_hr"],
              let respCfg = Baselines.metricCfg["resp"],
              let skinCfg = Baselines.metricCfg["skin_temp"] else { return }

        // #836 (idle-tick gate): re-scoring a 21-day window re-reads ~21×54 h of raw data and re-runs
        // analyzeDay over it. After a big Apple Health import (a reporter's: 2.1 M rows, ~190 k HR/day) that
        // is multi-second, memory-heavy work, and the 15-minute steady-state tick (AppModel) repeats it
        // every tick even when NOTHING new landed — the ongoing lag/crash in #836. A cheap whole-history HR
        // fingerprint (HR count+maxTs plus indexed row frontiers, no rows materialized) lets a NON-forced
        // caller short-circuit when the raw streams are unchanged since the last successful run. All-or-nothing: it
        // never produces a PARTIAL pass, so the window-wide reconciliation (stale-day eviction, detected-
        // workout delete) is untouched and no computed history is dropped. Every real update path (sync
        // backfill, import, sleep/workout edit, baseline recalibrate, timestamp heal) calls with the default
        // `force: true` and always rescores, so a skipped tick can never hide new data.
        // #1392: fingerprint raw scoring streams ACROSS ALL DEVICES, not the engine's construction-time
        // `deviceId` (a `let` pinned to "my-whoop", never re-pointed when the active strap changes). On an
        // Oura / Apple Watch / re-added-WHOOP install the per-device read returned 0, so this gate never
        // fired and a night finishing after launch stayed unscored until relaunch. Scoring below still reads
        // the registry's ACTIVE device (`owner`); only this change-detector needed to be cross-device.
        let wmKey = (try? await store.analysisFingerprint()) ?? ""
        // #1538: read the stored watermark ONCE for both gates and the attribution line below. There is no
        // suspension point between them, so the three reads this replaces could not disagree — but the log
        // line asserting `newData` and the gate deciding whether to run must be the SAME comparison by
        // construction, not by the reader checking for an `await`. Twin of the Android AppViewModel hoist.
        let storedWatermark = UserDefaults.standard.string(forKey: Self.analyzeWatermarkKey)
        if !force, !wmKey.isEmpty, storedWatermark == wmKey {
            return
        }
        // #1196/#1146: a FORCED post-offload pass can opt into the same fingerprint gate. An empty/duplicate
        // offload (fingerprint already == the watermark the last successful run advanced) has no new raw data to
        // score, so a re-score would reproduce IDENTICAL rows; skip the whole pass rather than churn the
        // window. Over a flapping-link offload storm that churn made the reactive Trends/streak reads
        // flicker between full and empty — a scare that looked like data loss (#1196). Scoped via
        // `skipIfUnchanged` to the post-offload caller (refreshAfterCompletedBackf…40854 tokens truncated…epsManualOverride) {
            // Estimate + upsert for each recent scored day that has motion but NO real phone step count.
            // (Days the phone DID count keep their real value , surfaced directly by the Today tile, not
            // overwritten by an estimate.) This runs AFTER any timestamp-heal upstream, so the motion it
            // reads is the healed-day motion, never pre-heal.
            var estPts: [MetricPoint] = []
            for dm in dailies where refStepsByDay[dm.day] == nil {
                guard let motion = motionByDay[dm.day],
                      let est = StepsEstimateEngine.estimate(motion: motion, calibration: cal) else { continue }
                estPts.append(MetricPoint(day: dm.day, key: "steps_est", value: Double(est)))
            }
            if !estPts.isEmpty { _ = try? await store.upsertMetricSeries(estPts, deviceId: computedId) }
            // Mirror the fit into ProfileStore so the Settings/Steps screen can show + adjust it.
            profile.stepsCalibrationCoefficient = cal.coefficient
            profile.stepsCalibrationSampleDays = cal.sampleDays
            profile.stepsCalibrationConfidence = cal.confidence
            profile.stepsCalibrationManual = cal.manual
        } else {
            // Not yet calibrated (too few overlapping phone-counted days, no manual override). Classify the
            // STATE (#589) and persist the PROGRESS so the Today tile/Settings can say how many more days are
            // needed rather than going silently blank. `status` uses the SAME usable-day filter the fit does.
            // Coefficient stays 0 (the "not calibrated" gate the UI already keys off); sampleDays carries the
            // usable-day count so the message can compute "need N more".
            let stepsStatus = StepsEstimateEngine.status(calPoints, manualOverride: profile.stepsManualOverride)
            if case let .needsMoreDays(have, _) = stepsStatus {
                profile.stepsCalibrationCoefficient = 0
                profile.stepsCalibrationSampleDays = have
                profile.stepsCalibrationConfidence = 0
                profile.stepsCalibrationManual = false
            }
        }

        // Steps test mode: emit the WHOOP-4 motion-volume calibration trace (per-day points + the fitted /
        // manual / withheld calibration state) and a per-day estimate line, tagged `.steps`. Only when the
        // mode is on (the gate was read once before the scan loop), so the default path emits zero `.steps`
        // lines here. The trace reuses StepsEstimateEngine.calibrate/estimate VERBATIM, so it cannot diverge
        // from the coefficient + steps_est just written above.
        if stepsTraceActive {
            for line in StepsEstimateEngine.calibrationTrace(points: calPoints,
                                                             manualOverride: profile.stepsManualOverride) {
                diagnosticSink?(line, .steps)
            }
            if let cal = StepsEstimateEngine.calibrate(calPoints, manualOverride: profile.stepsManualOverride) {
                for dm in dailies where refStepsByDay[dm.day] == nil {
                    guard let motion = motionByDay[dm.day],
                          let est = StepsEstimateEngine.estimate(motion: motion, calibration: cal) else { continue }
                    diagnosticSink?("stepsEst day=\(dm.day) steps=\(est) "
                        + "motion=\((motion * 100).rounded() / 100) (motion-volume estimate)", .steps)
                }
            }
        }

        markPostLoopPhase("steps")
        // Drop any freshly-detected session that overlaps a night the user has already hand-corrected.
        // A detected onset can drift second-to-second as more raw data arrives, so without this the
        // re-detected night would upsert as a SECOND row beside the edited one (different startTs ⇒ no
        // ON CONFLICT match), and mergeDay would DOUBLE-COUNT both into an inflated time-in-bed. The
        // edited row is already stored (preserved by the upsert guard), so we simply don't re-insert its
        // detected twin. Sleep has no delete-reinsert pass (unlike dailyMetric/workout), so this is the
        // idempotency guard for the edited case. (#318)
        let editedWindows = editedRows.map { (start: $0.effectiveStartTs, end: $0.endTs) }
        // #68: also drop any re-detected night the user has DELETED , a dismissedSleep tombstone keeps it
        // from regenerating, mirroring the dismissed-WORKOUT guard above. Overlap (not exact startTs)
        // because a re-detected onset drifts as more raw data arrives. (Android twin: dismissedWindows.)
        let dismissedWindows = repo.dismissedSleepWindows()
        let skipWindows = editedWindows + dismissedWindows
        let cachedSleepKept = cachedSleep.filter { s in
            !skipWindows.contains { s.startTs < $0.end && $0.start < s.endTs }   // time-overlap test
        }
        do {
            if !cachedSleepKept.isEmpty {
                _ = try await store.upsertSleepSessions(cachedSleepKept, deviceId: computedId)
            }
        } catch {
            diagnosticSink?("re-score: sleep persistence failed; history repair remains pending", nil)
            return
        }
        // ── Persist per-epoch motion (H8) beside each kept session's stagesJSON ──────────────────────────
        // The sleepSession rows exist now (just upserted), so the targeted motion UPDATE lands. Persist ONLY
        // for the sessions actually kept (not edited/dismissed), keyed by the detected start `analyzeDay`
        // returned. A session whose gravity wouldn't grid was omitted from the map and is left as NULL , an
        // absent motion series stays absent, never a fabricated zero array.
        let keptStarts = Set(cachedSleepKept.map { $0.startTs })
        var motionByStart: [Int: [Double]] = [:]
        for night in scoredNights {
            for (start, motion) in night.sessionMotion where keptStarts.contains(start) {
                motionByStart[start] = motion
            }
        }
        for (start, motion) in motionByStart {
            _ = try? await store.persistSessionMotion(deviceId: computedId, sessionStart: start, motionEpochs: motion)
        }
        // ── Persist per-epoch BAND sleep_state (#175) beside each kept session's stagesJSON ──────────────
        // This is the source `sessionSleepStateJSON` lacked (v7.7.0 finding: the write path had no producer
        // because the raw stream was dropped at extraction). Now analyzeDay grids the RAW `sleepStateSample`
        // stream per session; persist it here so the NEXT pass's `bandSleepStateSamples` read (the H7 confirm)
        // and the display can see the strap's OWN scored band. ONLY for kept (not edited/dismissed) sessions;
        // a session with no band samples was omitted (no key) and stays NULL — an absent signal stays absent.
        var sleepStateByStart: [Int: [Int]] = [:]
        for night in scoredNights {
            for (start, states) in night.sessionSleepState where keptStarts.contains(start) {
                sleepStateByStart[start] = states
            }
        }
        for (start, states) in sleepStateByStart {
            _ = try? await store.persistSessionSleepState(deviceId: computedId, sessionStart: start, states: states)
        }
        markPostLoopPhase("sleepWrite")
        // ── Overlap-aware banked-sleep heal (#899) ────────────────────────────────────────────────────
        // An unstable strap clock re-banks the SAME night under a shifted timebase, so successive passes
        // detect it at shifted bounds and the upsert above lands a SECOND row beside the stale one (the
        // (deviceId, startTs) key differs, and sleep has no delete-reinsert reconcile like dailyMetric /
        // workout). Collapse the window's stored sessions with the overlap rule, treating the rows THIS
        // pass just banked as the bank-recency witness (the strap's current timebase), and delete the
        // stale copies. Scoped to sessions whose wake day lies inside the [oldestDay, newestDay] daily
        // reconcile window: exactly the days this pass re-scored/evicted, so a session row is never
        // deleted out from under a daily row the pass did not refresh. Edited rows are never dropped.
        // #1248: heal EVERY device that banks sleep in this window, not just `computedId`. A live source
        // (an Oura ring) banks its OWN hypnogram under its device id; a night re-banked there accumulates
        // overlapping copies the computedId-only heal never saw — and, worse, those un-healed ring rows are
        // re-read as `providedSleep` and re-detected every pass, so one night ballooned to 14 rows / 9
        // "naps". Dedup each device's rows AMONG THEMSELVES and delete stale copies under that SAME id
        // (never across ids, so a survivor is never orphaned under an id the day-owner read skips).
        // `freshStarts` (this pass's computed bank witness) is handed ONLY to the computedId sweep; every
        // other id falls back to longest-wins, the read-side dedup's own default. It used to be passed to
        // every id on the claim that it "only matches the computedId rows" — false on an Oura day, where the
        // pass's sessions ARE the ring's `providedSleep` rows with `startTs` copied verbatim. The ring row
        // the pass had READ was then ranked "fresh" in the ring's own sweep and outranked every fuller
        // re-serve the ring banked while the pass was in flight (hours, when iOS suspends the app between
        // the read and this heal): on 09-19/20 the heal deleted the 598-min full night one second after it
        // landed and kept the 337-min row read at 04:14, so the day ended at 04:48 instead of 08:21.
        // `SleepSessionDedup.healWitness` is the one shared rule (twin of Kotlin's). Sorted for a
        // deterministic order.
        let healDeviceIds = Self.healDeviceIds(computedId: computedId, registeredIds: regDevices.map { $0.id })
        // Compact shape of a row for the #1284 heal log — the two measures that adjudicate WHICH copy is
        // fuller (stage-segment count + decoded JSON length), in the SAME format as the dup-gen diagnostic
        // (`dupGenShape`) so the two lines parse identically. Window + shape counts only, never stage content
        // or vitals; the strap log stays local and is shared only when the user exports it (as dup-gen does).
        func sleepShape(_ s: CachedSleepSession) -> String {
            let json = s.stagesJSON ?? ""
            let segs = json.components(separatedBy: "\"stage\"").count - 1
            return "[\(s.startTs) -> \(s.endTs)] min=\((s.endTs - s.effectiveStartTs) / 60) segs=\(segs) json=\(json.utf8.count)"
        }
        var healDropped: [CachedSleepSession] = []
        for healId in healDeviceIds {
            let storedSessions = (try? await store.sleepSessions(deviceId: healId, from: windowStart,
                                                                 to: now, limit: 4000)) ?? []
            let healable = storedSessions.filter {
                $0.endTs >= oldestAnalysisStart && $0.endTs <= now
            }
            let witness = SleepSessionDedup.healWitness(for: healId, computedId: computedId, keptStarts: keptStarts)
            let sweep = SleepSessionDedup.dedupe(healable, freshStarts: witness)
            for stale in sweep.dropped {
                _ = try? await store.deleteSleepSession(deviceId: healId, startTs: stale.startTs)
                // #1284: log which copy was dropped and which survived, so the corpus can confirm the heal
                // keeps the fuller / end-correct row (the survivor the collapse resolved this stale into).
                if let survivor = sweep.kept.first(where: { SleepSessionDedup.isDuplicate($0, stale) }) {
                    diagnosticSink?("Dedup(#1284): dropped \(sleepShape(stale)) kept \(sleepShape(survivor)) - heal", nil)
                }
            }
            healDropped.append(contentsOf: sweep.dropped)
        }
        // #1284: log the sweep ALWAYS, even at zero removals — a heal that collapsed rows was previously
        // silent (the line below only fired on a non-empty drop), so from the strap log alone it was
        // indistinguishable from never having run. Counts only, no PII.
        diagnosticSink?("Dedup(#899): swept \(healDeviceIds.count) device id(s), removed "
            + "\(healDropped.count) overlapping duplicate session(s).", nil)
        if !healDropped.isEmpty {
            diagnosticSink?("Dedup(#899): removed \(healDropped.count) overlapping duplicate sleep "
                + "session(s) re-banked under a shifted strap timebase; re-scoring the affected days.", nil)
            // Re-score against the cleaned store via the existing #899-A re-arm: the days scored THIS
            // pass consumed the read-side deduped view, but that view had no bank-recency witness (the
            // fresh detections weren't banked yet), so its survivor can differ from the heal's. One
            // forced re-pass reconciles them. HARD-BOUNDED: if the re-pass's own heal drops rows
            // again (detection oscillating under its own feedback), it does NOT re-arm a second time,
            // matching the Android one-re-pass bound; the budget restores once a pass heals nothing.
            if !healRearmedThisCycle {
                healRearmedThisCycle = true
                pendingForcedRescore = true
            }
        } else {
            healRearmedThisCycle = false
        }
        // #1735/#2187: never delete/reinsert legacy detected history during scoring. A disabled toggle,
        // rescoring pass, missing stream or failed insert must not erase a workout the user already saw.
        // #510: still write back any real (manual/imported) rows an analytics bout backfilled, one upsert
        // per owning deviceId.
        for (devId, rows) in backfilledByDevice {
            _ = try? await store.upsertWorkouts(rows, deviceId: devId)
        }

        markPostLoopPhase("sleepHeal")
        // #137: a manually-started workout is scored from sparse live HR at save time , near-zero
        // calories/strain on a 5/MG. Now that offloaded HR may cover the window, re-score the
        // under-sampled ones from that denser data.
        // #950: score the workout against the wearer's MEASURED resting HR, not the hardcoded 60 —
        // the day total above already uses the measured value, and the mismatch is what made a workout's
        // Effort incomparable to its own day's. The most recent scored day that has one is the best
        // available estimate; nil (cold start) keeps the old default. Twin of the Kotlin derivation.
        // FIRST, not last: `out` is NEWEST-FIRST, because the scoring loop counts backwards from today
        // (`for offset in 0..<maxDays` with `dayStart = nowLocalMidnight - offset * 86_400`), so out[0] is
        // today and the tail is the oldest day in the window. Taking the last match would have scored
        // today's workout against a resting HR up to `maxDays` old.
        let measuredResting = out.first(where: { $0.rhr != nil })?.rhr.map(Double.init)
        await rescoreManualWorkouts(store: store, profile: up, restingHR: measuredResting,
                                    effortMethod: effortMethodGlobal)

        results = out
        note = out.isEmpty
            ? "No scored nights yet. Wear the strap with NOOP connected overnight and the engine will score your charge, effort and rest itself, no WHOOP cloud required."
            : nil

        // Reload the dashboard caches so the freshly computed scores show up immediately. A heal-only
        // pass (#899 dedup deleted stale session rows but no daily changed) must refresh too, so the
        // Sleep tab stops showing the removed duplicates right away.
        if !dailies.isEmpty || !healDropped.isEmpty { await repo.refresh() }

        markPostLoopPhase("workouts")
        // #836/#sleep-sync: record the complete raw-analysis fingerprint this run scored against, so a later
        // NON-forced tick can short-circuit while it's unchanged. Written ONLY at the end of a completed run (never on an
        // early guard-return), so an interrupted/failed run can't advance the watermark past unscored data.
        if !wmKey.isEmpty { UserDefaults.standard.set(wmKey, forKey: Self.analyzeWatermarkKey) }
        markPostLoopPhase("tail")
        diagnosticSink?(AnalysisPhaseTally.logLine(scope: "postLoop", postLoopPhases), nil)
        // #1538: clear the started-mark and bank how long a COMPLETED pass costs on this install. The
        // measurement is what lets `RescoreBackgroundPolicy` tell an install that finishes comfortably in a
        // background wake from one that never could, instead of guessing from a constant — the cost varies
        // by more than an order of magnitude with history size.
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- reScoreStart) / 1_000_000_000
        let settled = RescoreBackgroundScheduler.markRescoreCompleted(seconds: elapsed, owedToken: owedToken)
        diagnosticSink?("re-score: done — scored \(scoredNights.count) night(s) in \(Int(elapsed * 1000)) ms (#1005)", nil)
        diagnosticSink?(RescoreBackgroundScheduler.passCostLogLine(
            cpuSeconds: RescoreBackgroundScheduler.processCPUSeconds().flatMap { end in reScoreCPUStart.map { end - $0 } },
            elapsedSeconds: elapsed,
            assertionExpiries: RescoreBackgroundScheduler.assertionExpiries - reScoreExpiriesAtStart,
            backgroundedAtEnd: RescoreBackgroundScheduler.isBackgrounded), nil)
        // #1681: a pass that completes while leaving the mark SET looks identical in a capture to one that
        // cleared it. Rare-event evidence, so always-on: it costs a line only when it actually happens,
        // and it is exactly what is missing when someone reports the app re-scoring on every launch.
        if !settled {
            diagnosticSink?("re-score: debt NOT settled — a newer re-score was recorded while this pass "
                            + "was running, so the mark stays and another pass will run (#1681)", nil)
        }
        // New-data debt does not invalidate the repair writes that just succeeded (#2606).
        // Cancellation and persistence failures still leave the repair flags unset.
        if !Task.isCancelled { onPersisted?() }
    }

    /// UserDefaults key for the #836 idle-tick gate: the complete raw-analysis fingerprint the last completed
    /// `analyzeRecent` scored against. A non-forced tick whose current fingerprint equals this skips the
    /// 21-day rescore; cleared implicitly by any scoring-stream insert (the fingerprint moves), so it self-heals.
    private static let analyzeWatermarkKey = "noop.analyzeWatermark"

    /// CAPTURE-B (#814/#799): build the universal `dayOwner …` self-diagnostic line VERBATIM (the Test
    /// Centre export parser depends on this exact shape). `readId` is the owner this day was read+scored
    /// from; `writeActiveId` is the registry's active id the Collector writes raw under; a DIVERGENCE on a
    /// day with HR rows is the #814 read/write split. `provenance` is `imported:whoop` / `imported:apple`
    /// when an export covers the day, else `measured` when the owner returned HR rows, else `none`. Pure +
    /// nonisolated so it's unit-tested directly and so the format can never silently drift. No PII (the ids
    /// are local "my-whoop" / "whoop-…" / import tokens; LiveState.append also scrubs).
    nonisolated static func dayOwnerLine(day: String, readId: String, writeActiveId: String,
                                         hrRows: Int, importedWhoop: Bool, importedApple: Bool) -> String {
        let provenance: String
        if importedWhoop { provenance = "imported:whoop" }
        else if importedApple { provenance = "imported:apple" }
        else if hrRows > 0 { provenance = "measured" }
        else { provenance = "none" }
        return "dayOwner day=\(day) readId=\(readId) writeActiveId=\(writeActiveId) "
            + "hrRows=\(hrRows) provenance=\(provenance)"
    }

    /// Resolve the SINGLE device that owns `day` (invariant I2), so the day is scored from exactly one
    /// source, never a mix. A locked override wins first; otherwise devices are probed in priority order
    /// (0 = active strap, 1 = other live straps, 2 = imports, 3 = activity files,
    /// 4 = archived devices; lower wins) until one has HR for the day. Returns `fallbackDeviceId`
    /// when the registry has no owner, so the legacy single-source path is preserved.
    ///
    /// Single-device install: the only paired row is the seeded active 'my-whoop' (== `fallbackDeviceId`).
    /// The single-device shortcut returns `fallbackDeviceId` without a presence probe, preserving the
    /// caller's legacy reads. With multiple devices, each probe covers the window the caller reads.
    ///
    /// `nonisolated static` (FIX 1): the body touches NO `@Published`/instance-isolated state , only the
    /// passed-in `store` actor, the nonisolated `registry` struct, the value params, and `fallbackDeviceId`
    /// (the former `self.deviceId`). Making it `nonisolated` lets the off-main scan loop call it WITHOUT
    /// hopping back to the main actor each iteration, which is the whole point of FIX 1. Logic identical.
    nonisolated static func resolveDayOwner(day: String, from: Int, to: Int, store: WhoopStore,
                                            devices: [PairedDevice], activeId: String,
                                            registry: DeviceRegistryStore,
                                            fallbackDeviceId: String) async -> String {
        // A locked override wins outright and skips the presence checks entirely. Timed because it runs on
        // EVERY call, ahead of any presence probe, and the first cut of this instrumentation counted only
        // the probe: that reported the cheap half of owner resolution while a warm pass still had seconds
        // unaccounted for. See `StoreProbeRecorder`.
        let lockedStarted = DispatchTime.now().uptimeNanoseconds
        let lockedOwner = (try? registry.dayOwner(day))?.deviceId
        StoreProbeRecorder.record(.dayOwner, nanos: DispatchTime.now().uptimeNanoseconds &- lockedStarted)
        if let lockedOwner {
            return lockedOwner
        }
        // No registry rows (shouldn't happen , v15 seeds one , but be safe): keep the legacy id.
        guard !devices.isEmpty else { return fallbackDeviceId }

        // #970: the default single-WHOOP install has exactly one device that IS the fallback id, so
        // the owner is a foregone conclusion — the resolver returns that id whether or not it has data in
        // this window (active priority 0 -> its id; or no candidate has data -> nil -> fallbackDeviceId,
        // both == fallbackDeviceId here). Skip the per-day LIMIT-1 HR probe in that case (called once per
        // scanned day, so it saves ~maxDays tiny reads per analyzeRecent). Byte-identical to the loop. The
        // guard is deliberately `== fallbackDeviceId`: a lone IMPORT device whose id differs would NOT be
        // byte-identical (no-data -> fallback, not its own id), so it must still take the probe path.
        if devices.count == 1, devices[0].id == fallbackDeviceId {
            return fallbackDeviceId
        }

        // Probe in PRIORITY ORDER and stop at the first candidate that has data.
        //
        // `DayOwnerResolver.resolve` is `candidates.filter(hasData).min(by: priority)`, so the winner is
        // the lowest-priority-number candidate with data, and every probe after it cannot change the
        // answer. Probing them anyway cost a query per candidate per day: on the 60-day steps window with
        // two straps that is 120 per pass, and the active strap usually answers on the first.
        // `DayOwnerResolverEquivalenceTests` pins this against the resolver itself rather than trusting
        // the reasoning, because the two must not be allowed to drift.
        //
        // The probe is a scalar EXISTS now, not a fetched `LIMIT 1` row: the question is one bit, and it
        // used to be answered by materialising a row and an `HRSample` to test an array for emptiness.
        //
        // #137: an activity-file ride ranks BELOW whole-day imports (priority 3 vs 2), so a full-day
        // WHOOP CSV/cloud import keeps ownership of a day it has HR for; the ride only wins a day that
        // nothing else covers (a strap-less day). Kotlin RegistryDayOwnerSource mirrors this ordering.
        let ranked: [(id: String, priority: Int)] = devices.map { d in
            let isImport = d.sourceKind == .cloudImport || d.sourceKind == .fileImport
            let priority: Int
            if d.id == activeId { priority = 0 }
            else if d.status == .archived { priority = 4 }
            else if d.sourceKind == .activityFile { priority = 3 }
            else if isImport { priority = 2 }
            else { priority = 1 }
            return (d.id, priority)
        }
        // Sorted on (priority, ORIGINAL INDEX), not priority alone. Swift's `sorted` is not a stable sort
        // by contract, so two candidates sharing a priority — which two non-active straps do, both being
        // priority 1 — could come back in either order and the first-with-data probe would then pick
        // either one. Kotlin's `sortedBy` is stable and its resolver's `minByOrNull` takes the first
        // minimum, so leaving this to the sort would let the platforms disagree on a tie. Carrying the
        // index makes the order total and matches Kotlin exactly.
        .enumerated().sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }
        .map(\.element)
        for c in ranked {
            if (try? await store.hasHrInWindow(deviceId: c.id, from: from, to: to)) == true { return c.id }
        }
        return fallbackDeviceId
    }

    /// The strap family that wrote `owner`'s skin-temp rows (#938), so the nightly funnel converts the raw
    /// register on the right scale. The model-label → family mapping (and the `.whoop5` fallback for
    /// unknowns) lives in `DeviceFamily.forRegistryDevice` (#171, #1086).
    nonisolated static func skinTempFamily(forOwner owner: String, devices: [PairedDevice]) -> DeviceFamily {
        let d = devices.first(where: { $0.id == owner })
        // Non-WHOOP owner (nil) shares the non-4.0 temp scale, so coalesce to `.whoop5` — same conversion
        // as before; the brand-aware resolver just no longer mislabels the owner as a WHOOP (#1086).
        return DeviceFamily.forRegistryDevice(model: d?.model, brand: d?.brand) ?? .whoop5
    }

    /// #1467: the skin-temp "worn" gate's timestamp tolerance for `owner` — 0 (exact match) for a WHOOP
    /// strap, whose HR and skin-temp are one co-sampled 1 Hz stream, so this is byte-identical to before
    /// this change for every WHOOP night. An Oura ring streams the two on independent clocks (dense HR,
    /// ~1/min skin-temp), so an exact-second match only ever caught ~40-55% of real worn samples — every
    /// one of 7 straight real nights landed just under `minSkinTempSamples`, ground-truthed against the
    /// Oura app's own reported skin-temp trend (queue 11b, `worklog/BOARD.md`). Same registry lookup
    /// `skinTempFamily` uses; deliberately its own small helper rather than folding into `DeviceFamily`,
    /// which has no Oura case (#1086) and a tolerance-in-seconds isn't a temperature-scale concern.
    nonisolated static func skinTempWornToleranceSec(forOwner owner: String, devices: [PairedDevice]) -> Int {
        devices.first(where: { $0.id == owner })?.brand == "Oura"
            ? AnalyticsEngine.defaultOuraWornToleranceSec : 0
    }

    /// #137: re-score under-sampled manual workouts. A `manual` workout is scored from the live HR
    /// captured during the session; on a 5/MG that stream is sparse, so calories/strain land near zero.
    /// The strap banks its own HR and offloads it on sync , once that denser HR covers the workout's
    /// window, recompute from it. Conservative + idempotent: only `manual` rows that look under-scored
    /// (negligible calories), and only when the recompute is a genuine improvement , so a well-scored
    /// 4.0 workout is never touched and a still-sparse window is a no-op.
    private func rescoreManualWorkouts(store: WhoopStore, profile up: UserProfile,
                                       restingHR: Double? = nil,
                                       // #1545: the recipe THIS PASS scored its days with, threaded in
                                       // rather than re-read. Re-reading would let a toggle flipped
                                       // mid-pass score a manual workout by one recipe and the day it
                                       // sits in by the other — the exact day-vs-bout contradiction the
                                       // threading exists to prevent. Twin of the Kotlin parameter.
                                       effortMethod: StrainScorer.Method = .edwards) async {
        let now = Int(Date().timeIntervalSince1970)
        let since = now - 14 * 86_400
        guard let rows = try? await store.workouts(deviceId: deviceId, from: since, to: now, limit: 200)
        else { return }
        let hrMax = Double(profile.hrMax)
        var updated: [WorkoutRow] = []
        // A manual row is eligible when it looks under-scored (negligible kcal, #137) OR it's missing
        // strain (the merged-workout case, where kcal is the SUM of inputs so it never looks under-scored
        // yet Effort stays blank forever). `improves` then accepts a strain-only gain for the latter.
        for row in rows where row.source == "manual"
            && (ManualWorkoutRescore.looksUnderScored(currentKcal: row.energyKcal) || row.strain == nil) {
            guard let samples = try? await store.hrSamples(deviceId: deviceId, from: row.startTs,
                                                           to: row.endTs, limit: 20_000),
                  let s = ManualWorkoutRescore.scored(windowSamples: samples, profile: up, hrMax: hrMax,
                                                      restingHR: restingHR,
                                                      effortMethod: effortMethod),
                  ManualWorkoutRescore.improves(s, over: row.energyKcal, currentStrain: row.strain,
                                                allowStrainOnlyFill: true)
            else { continue }
            // Never lower a summed kcal: only take the recomputed kcal when it genuinely beats the stored
            // value; a strain-only fill (merged row) keeps the existing summed energyKcal.
            let kcalBeatsStored = (s.kcal ?? 0) > (row.energyKcal ?? 0) + ManualWorkoutRescore.improvementMarginKcal
            let energyKcal = kcalBeatsStored ? s.kcal : row.energyKcal
            updated.append(WorkoutRow(
                startTs: row.startTs, endTs: row.endTs, sport: row.sport, source: row.source,
                durationS: row.durationS, energyKcal: energyKcal, avgHr: s.avgHr, maxHr: s.maxHr,
                strain: s.strain, distanceM: row.distanceM, zonesJSON: row.zonesJSON, notes: row.notes,
                steps: row.steps))
        }
        if !updated.isEmpty { _ = try? await store.upsertWorkouts(updated, deviceId: deviceId) }
    }

    /// Pass 1 has no seeded skin baseline. Attach the deviation before scoring so the score,
    /// explanation, trace and persisted row all consume the same temperature. Internal for regression tests.
    static func recomputeRecoveryDaily(_ daily: DailyMetric, nightlySkinTempC: Double?,
                                       baselines: AnalyticsEngine.ProfileBaselines) -> DailyMetric {
        let skinDev = recomputeSkinTempDev(nightlySkinTempC, baselines.skinTemp)
        let input = daily.with(recovery: daily.recovery, skinTempDevC: skinDev, skinTempC: nightlySkinTempC)
        return input.with(recovery: recomputeRecovery(input, baselines), skinTempDevC: skinDev,
                          skinTempC: nightlySkinTempC)
    }

    /// Resolve conservative legacy snapshots before the computed-window upsert can replace them. The date
    /// loop reuses the scorer's own day/window arithmetic instead of parsing calendar dates, keeping both
    /// DST behaviour and today's shortened forward window identical to the scoring read.
    private static func legacyScoreSnapshots(
        store: WhoopStore, computedId: String, from: String, to: String,
        fresh: [DailyMetric], ownerByDay: [String: String],
        dayWindowsByKey: [String: LocalDayWindow], now: Int,
        strictCanonicalAlias: Bool
    ) async -> [String: LegacyScoreSnapshot] {
        let existing = (try? await store.dailyMetrics(deviceId: computedId, from: from, to: to)) ?? []
        let existingByDay = Dictionary(existing.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        var snapshots: [String: LegacyScoreSnapshot] = [:]
        for day in fresh {
            guard day.avgHrv == nil, let old = existingByDay[day.day], let oldHrv = old.avgHrv,
                  let owner = ownerByDay[day.day], let window = dayWindowsByKey[day.day] else { continue }
            let dayStart = Int(window.start.timeIntervalSince1970)
            let readFrom = dayStart - StreamReadCap.lookbackSeconds
            let readTo = min(Int(window.nextStart.timeIntervalSince1970), now)
            let alias = strictCanonicalAlias && owner == Repository.whoopSource
            guard (try? await store.legacyWhoop5RRWithheld(
                deviceId: owner, from: readFrom, to: readTo,
                unlabelledAliasOfWhoop5: alias)) == true else { continue }
            snapshots[day.day] = LegacyScoreSnapshot(
                avgHrv: oldHrv, recovery: old.recovery,
                respRateBpm: old.respRateBpm, avgSdnn: old.avgSdnn,
                recoverySource: try? await store.scoreInputSource(
                    deviceId: computedId, day: day.day, key: "recovery"))
        }
        return snapshots
    }

    /// Re-score ONLY the recovery composite for a day against a (re-seeded) baseline. Every other field
    /// in `daily` is baseline-independent and already final from pass 1. Returns nil until the HRV
    /// baseline is usable (RecoveryScorer gates on `hrvBaseline.usable`, i.e. ≥ minNightsSeed valid
    /// nights) , so the honest null-until-4-nights cold-start is free. Mirrors AnalyticsEngine's own
    /// recovery call + Android IntelligenceEngine.recomputeRecovery. (#78)
    private static func recomputeRecovery(_ daily: DailyMetric, _ baselines: AnalyticsEngine.ProfileBaselines) -> Double? {
        guard let hrvVal = daily.avgHrv, let rhrVal = daily.restingHr, let hrvBase = baselines.hrv else { return nil }
        // Charge enrichment: feed the Rest COMPOSITE (÷100) as the sleep-quality term instead of raw
        // efficiency, and fold in the night's skin-temp deviation. Both come from the persisted daily
        // fields (the raw streams are gone in pass 2). (Charge/Effort/Rest scoring redesign.)
        let restQuality = AnalyticsEngine.Rest.composite(daily: daily).map { $0 / 100.0 } ?? daily.efficiency
        return RecoveryScorer.recovery(hrv: hrvVal, rhr: Double(rhrVal), resp: daily.respRateBpm,
                                       hrvBaseline: hrvBase, rhrBaseline: baselines.restingHR,
                                       respBaseline: baselines.resp, sleepPerf: restQuality,
                                       skinTempDev: daily.skinTempDevC)
    }

    /// The ordered "what shaped it" Charge driver list for one day (SHARED CONTRACT). Pure: it feeds the
    /// SAME inputs `recomputeRecovery` reads (the SAME `restQuality` derivation) into
    /// `RecoveryScorer.chargeDrivers`, whose per-term deltas come from `RecoveryScorer.recovery` verbatim, so
    /// the rows can never diverge from the Charge number written for the day. Empty when a hard input
    /// (HRV / RHR / HRV-baseline) is missing or the baseline isn't usable yet, mirroring `recomputeRecovery`'s
    /// own early-nil so a cold-start night shows the calibrating state rather than fabricated rows.
    private func recomputeChargeDrivers(_ daily: DailyMetric,
                                        _ baselines: AnalyticsEngine.ProfileBaselines) -> [ChargeDriver] {
        guard let hrvVal = daily.avgHrv, let rhrVal = daily.restingHr, let hrvBase = baselines.hrv else {
            return []
        }
        let restQuality = AnalyticsEngine.Rest.composite(daily: daily).map { $0 / 100.0 } ?? daily.efficiency
        return RecoveryScorer.chargeDrivers(hrv: hrvVal, rhr: Double(rhrVal), resp: daily.respRateBpm,
                                            hrvBaseline: hrvBase, rhrBaseline: baselines.restingHR,
                                            respBaseline: baselines.resp, sleepPerf: restQuality,
                                            skinTempDev: daily.skinTempDevC)
    }

    /// The Charge term-breakdown trace lines for one day (Recovery test mode, Group G). Pure: it feeds the
    /// SAME inputs `recomputeRecovery` does (the SAME `restQuality` derivation) into RecoveryScorer's
    /// side-effect-free `recoveryTrace`, whose returned score IS `RecoveryScorer.recovery` verbatim, so the
    /// trace can never diverge from the Charge number written for the day. Empty when a hard input
    /// (HRV / RHR / HRV-baseline) is missing, mirroring `recomputeRecovery`'s own early-nil. Only CALLED
    /// when `TestCentre.active(.recovery)` is true, so it costs nothing when the mode is off.
    private func recoveryTraceLines(_ daily: DailyMetric, _ baselines: AnalyticsEngine.ProfileBaselines) -> [String] {
        guard let hrvVal = daily.avgHrv, let rhrVal = daily.restingHr, let hrvBase = baselines.hrv else {
            return ["charge day=\(daily.day) nilScore reason=missingInput "
                + "(hrv/rhr/hrvBaseline required)"]
        }
        let restQuality = AnalyticsEngine.Rest.composite(daily: daily).map { $0 / 100.0 } ?? daily.efficiency
        let (_, trace) = RecoveryScorer.recoveryTrace(
            hrv: hrvVal, rhr: Double(rhrVal), resp: daily.respRateBpm,
            hrvBaseline: hrvBase, rhrBaseline: baselines.restingHR,
            respBaseline: baselines.resp, sleepPerf: restQuality,
            skinTempDev: daily.skinTempDevC)
        // Prefix each line with the day key so a multi-night export stays parseable, matching the sleep
        // trace's per-day shape. Strip ONLY the leading "charge " token the trace builder writes (every
        // line starts with it), then re-emit as "charge day=<day> ...".
        return trace.map { line in
            let body = line.hasPrefix("charge ") ? String(line.dropFirst("charge ".count)) : line
            return "charge day=\(daily.day) " + body
        }
    }

    /// One day's watch-derived recovery output, keyed by day.
    struct WatchScoredDay: Equatable {
        let day: String
        let recovery: Double?
        let confidence: ScoreConfidence
    }

    /// Compute Apple-Watch recovery (Charge) for the apple-health days that lack a strap recovery.
    ///
    /// The Apple Watch gives DAILY aggregates (an SDNN HRV reading + a resting HR), not a WHOOP-density raw
    /// stream, so the normal `analyzeRecent` raw-HR path (`hr.count >= 200`) never scores these days and the
    /// import leaves `recovery: nil`. This fills that one gap: for each apple-health day it folds the TRAILING
    /// SDNN + RHR history (every earlier apple-health day's `avgHrv` / `restingHr`) into the cross-lane
    /// `WatchRecovery` engine, which mirrors our Charge recovery shape but reads Apple's daily values. It stays
    /// nil + `.calibrating` until there are enough usable nights of HRV baseline, so we never fabricate a number.
    ///
    /// `strapRecoveryDays` are the days a strap (WHOOP / computed) already scored a recovery , those are SKIPPED
    /// so the strap keeps winning (matching the source precedence; we never overwrite a strap recovery with a
    /// lower-density watch one). Pure (no store) so it's unit-tested directly and is the SAME logic
    /// `analyzeRecent` ships. `appleRows` must be chronological (oldest first).
    nonisolated static func watchRecoveries(appleRows: [DailyMetric],
                                strapRecoveryDays: Set<String> = []) -> [WatchScoredDay] {
        let rows = appleRows.sorted { $0.day < $1.day }
        var out: [WatchScoredDay] = []
        for (i, row) in rows.enumerated() where !strapRecoveryDays.contains(row.day) {
            // Trailing baseline history = every earlier apple-health day with a usable value. Today is the
            // current row; the baseline is built from the days BEFORE it so it can't see its own value.
            let prior = rows[..<i]
            let sdnnHistory = prior.compactMap { $0.avgHrv }
            let rhrHistory = prior.compactMap { $0.restingHr.map(Double.init) }
            let res = WatchRecovery.compute(todaySDNN: row.avgHrv,
                                            todayRHR: row.restingHr,
                                            sdnnHistory: sdnnHistory,
                                            rhrHistory: rhrHistory)
            out.append(WatchScoredDay(day: row.day, recovery: res.recovery, confidence: res.confidence))
        }
        return out
    }

    /// Override a day's detected sleep aggregates with the user's hand-corrected window when one of the
    /// night's blocks was edited. Substitutes each edited block (matched by its stable startTs) for its
    /// detected twin and recomputes totalSleep / efficiency / stage minutes from the reshaped stages, so
    /// the Rest composite and recovery score the corrected sleep , not the auto-detected window. No edit
    /// touching the night → the detected daily is returned unchanged. (#318)
    /// #299: the edited / hand-logged sleep rows that belong to `day` — the ones whose edits may be folded
    /// into THAT day's sleep total. An edit belongs to the day its night ENDS on (`dayString(endTs)`),
    /// matching AnalyticsEngine's end-day session bucket; `endTs` is stable under a bedtime edit (only the
    /// onset moves). Scoping this per day is the fix: the edit set was built window-wide and
    /// `sleepEditedDaily` folds any row that isn't a twin of a day's detected sessions in as a "manual"
    /// block, so one edit / nap leaked its total onto EVERY night. Byte-identical twin of Android
    /// `IntelligenceEngine.editedRowsForDay`.
    static func editedRowsForDay(_ editedRows: [CachedSleepSession], day: String,
                                 tzOffsetSeconds: Int, dayBounds: Range<Int>? = nil) -> [CachedSleepSession] {
        if let dayBounds { return editedRows.filter { dayBounds.contains($0.endTs) } }
        return editedRows.filter { AnalyticsEngine.dayString($0.endTs, offsetSec: tzOffsetSeconds) == day }
    }

    private func sleepEditedDaily(_ daily: DailyMetric, detected: [CachedSleepSession],
                                 editsByStart: [Int: CachedSleepSession],
                                 habitualMidsleepSec: Int?) -> DailyMetric {
        guard !editsByStart.isEmpty else { return daily }
        let detectedTuples = detected.map { (startTs: $0.startTs, stagesJSON: $0.stagesJSON) }
        let editedStages = editsByStart.mapValues { $0.stagesJSON }
        // A hand-logged nap is a userEdited row with NO detected twin , it would never be
        // visited by the substitution pass, so its minutes were dropped from the day's Rest
        // total. Pass those twinless rows through the union channel so they fold in. (#518/#508)
        let detectedStarts = Set(detected.map { $0.startTs })
        let manualTuples = editsByStart
            .filter { !detectedStarts.contains($0.key) }
            .map { (startTs: $0.key, stagesJSON: $0.value.stagesJSON) }
        // #525/#547: supply each block's EFFECTIVE onset (audit finding C / #8) keyed by its stable
        // detected startTs, plus the device tz offset + learned habitual midsleep, so the edited recompute
        // picks the SAME MAIN NIGHT the Sleep tab shows. The onset must be the user-CORRECTED bedtime
        // (`startTsAdjusted ?? startTs`) when a block was edited, NOT the immutable detected start , a
        // bedtime edit crossing the overnight boundary would otherwise let the seam and the Sleep tab pick
        // different blocks. For a detected block the effective onset is its edited twin's effectiveStartTs
        // (an edit moves the onset) when edited, else the detected block's own effectiveStartTs; for a
        // twinless manual block it's that row's effectiveStartTs. Without these the seam falls back to the
        // legacy SUM and an overnight+nap day would re-include the nap in the headline total.
        var onsetByStart: [Int: Int] = [:]
        for d in detected {
            onsetByStart[d.startTs] = editsByStart[d.startTs]?.effectiveStartTs ?? d.effectiveStartTs
        }
        for (start, edit) in editsByStart where !detectedStarts.contains(start) {
            onsetByStart[start] = edit.effectiveStartTs
        }
        guard let r = SleepStageTotals.dailyAggregateHonoringEdits(detected: detectedTuples,
                                                                   edited: editedStages,
                                                                   manual: manualTuples,
                                                                   onsetByStart: onsetByStart,
                                                                   offsetSec: TimeZone.current.secondsFromGMT(),
                                                                   habitualMidsleepSec: habitualMidsleepSec,
                                                                   timeZone: TimeZone.autoupdatingCurrent),
              r.editApplied else { return daily }
        let agg = r.sleep
        return daily.with(totalSleepMin: agg.totalSleepMin, efficiency: agg.efficiency,
                          deepMin: agg.deepMin, remMin: agg.remMin, lightMin: agg.lightMin)
    }

    /// Re-derive the skin-temperature deviation (°C) for a night against the freshly-seeded personal
    /// baseline, mirroring the avgHrv→recovery re-score. Nil when the night had no wear-gated mean or
    /// the skin-temp baseline isn't usable yet (< minNightsSeed) , honest cold-start. Rounded to 2 dp
    /// to match the imported/demo precision. APPROXIMATE.
    private static func recomputeSkinTempDev(_ nightly: Double?, _ base: BaselineState?) -> Double? {
        guard let v = nightly, let b = base, b.usable else { return nil }
        return (Baselines.deviation(v, state: b).delta * 100.0).rounded() / 100.0
    }

    /// The user's habitual midsleep (local time-of-day seconds), or nil under `habitualMinDays` of
    /// history (cold-start). Reads the stored sleep sessions (imported + computed) over the window, makes
    /// one `HistoryBlock` per session , start/end are the EFFECTIVE (edited) bounds so a corrected bedtime
    /// is learned, dayKey is the LOCAL calendar day of the midpoint , and defers to
    /// `SleepStageTotals.habitualMidsleepSec`, which keeps the longest block per day (naps drop out). The
    /// imported + computed sets can overlap; both are unioned and the learner de-dupes per day by length.
    /// (#547) Mirrors the Android `computeHabitualSleep`.
    /// CONSUME (#531 / H8): the prior pass's persisted v18 BAND sleep_state for sessions overlapping
    /// `[from, to]`, expanded to timestamped `(ts, state)` samples on the 30 s epoch grid, for the H7
    /// morning-stillness guard's re-onset confirmation. Reads the computed sessions in the window, then each
    /// one's persisted per-epoch sleep_state (NULL when never banded , first pass / imported night), and maps
    /// epoch `i` to `startTs + i*30`. Empty when nothing is banded yet, so the guard simply falls back to the
    /// HR bar. Honest: only real banded states are surfaced, never a fabricated reading. The grid here mirrors
    /// `SleepStager`'s 30 s epoch grid, so an epoch's timestamp lands inside the candidate run it scores.
    /// `nonisolated static` (FIX 1): touches only the `store` actor + value params, so the off-main scan
    /// loop calls it without hopping back to the main actor each iteration. Logic identical.
    nonisolated static func bandSleepStateSamples(computedId: String, from: Int, to: Int,
                                                  store: WhoopStore) async -> [(ts: Int, state: Int)] {
        let epochS = 30
        // #899: collapse overlapping timebase-shifted duplicates BEFORE consuming band state. A stale
        // re-banked copy of the night would otherwise feed "asleep" epochs at the OLD times into the H7
        // re-onset guard, letting the stale block keep confirming itself. Read-side only (no bank-recency
        // witness here); the store itself is healed post-upsert in analyzeRecent.
        let sessions = SleepSessionDedup.dedupe(
            (try? await store.sleepSessions(deviceId: computedId, from: from, to: to,
                                            limit: 4000)) ?? []).kept
        // One range read of the window's banked band state, keyed by startTs, instead of a single-row SELECT
        // per kept session. We still expand ONLY the kept (deduped) sessions, in order, so the output is
        // identical to the old per-session loop — just without the N round-trips.
        let stateByStart = (try? await store.sessionSleepStates(deviceId: computedId,
                                                                from: from, to: to)) ?? [:]
        var samples: [(ts: Int, state: Int)] = []
        for s in sessions {
            guard let states = stateByStart[s.startTs], !states.isEmpty else { continue }
            for (i, st) in states.enumerated() {
                samples.append((ts: s.startTs + i * epochS, state: st))
            }
        }
        return samples
    }

    /// Habitual midsleep (local seconds) AND the trailing per-night sleep DURATIONS (hours,
    /// chronological) from the stored sessions over the window — the longest block per LOCAL day, so
    /// naps drop out. One read serves both the main-night midsleep learner (#547) and the personal
    /// sleep-need + regularity that thread into `analyzeDay` (Wave 0 · SL1/T1). The midsleep result is
    /// byte-identical to before; the nightly-hours output is the Swift-side extension.
    ///
    /// Only sessions that ended before `finishedBefore` (the pass's local midnight) are learned from. Tonight's
    /// session is re-banked by every sync while it is still growing, and each time it moved the learned
    /// consistency and midsleep, so every pass through a morning found the day-cache signature changed and
    /// re-scored all 21 nights from scratch. On a backgrounded phone that turned a seconds-long pass into
    /// hours (a field log: 8 813 s and 2 345 s, back to back). A night still being slept is not a habit yet;
    /// it joins the history the day after, once, when the window rolls anyway.
    ///
    /// Internal rather than private only so a test can drive the `finishedBefore` cutoff directly.
    static func computeHabitualSleep(
        store: WhoopStore, importedId: String, computedId: String,
        windowStart: Int, windowEnd: Int, finishedBefore: Int, offsetSec: Int,
        timeZone: TimeZone? = nil
    ) async -> (midsleepSec: Int?, nightlyHours: [Double]) {
        let imported = (try? await store.sleepSessions(deviceId: importedId, from: windowStart,
                                                       to: windowEnd, limit: 4000)) ?? []
        let computed = (try? await store.sleepSessions(deviceId: computedId, from: windowStart,
                                                       to: windowEnd, limit: 4000)) ?? []
        // #899: collapse overlapping timebase-shifted duplicates BEFORE the learner sees the history.
        // A stale re-banked copy of a night lands on a DIFFERENT day key, so the per-day longest-block
        // de-dup below never caught it and the learned midsleep drifted toward the stale timing, which
        // then steered the main-night pick (day assignment) to the stale block. The same collapse also
        // covers an imported night and its computed twin (the longest capture wins, exactly what the
        // per-day length rule chose anyway).
        let merged = SleepSessionDedup.dedupe(imported + computed).kept.filter { $0.endTs < finishedBefore }
        // Longest block per LOCAL day (naps drop out), chosen by in-bed SPAN — reused for BOTH the
        // midsleep learner and the per-night durations (Wave 0 · SL1/T1), so the two can never read a
        // different history. For the DURATIONS we keep TST (span × efficiency), NOT the in-bed span:
        // the need/regularity estimate must be in the same asleep-time units as the `tstSeconds` Rest
        // scores against, or need reads systematically high (validated on real data — an in-bed span
        // over-counts ~0.85 h vs TST). Efficiency is 0..1 (post the v26 unit-heal); a rare nil main
        // night falls back to a typical 0.9.
        var longestByDay: [String: (span: Int, tstHours: Double)] = [:]
        let blocks = merged.compactMap { s -> SleepStageTotals.HistoryBlock? in
            let start = s.effectiveStartTs, end = s.endTs
            guard end > start else { return nil }
            let mid = start + (end - start) / 2
            let dayKey = timeZone.map { AnalyticsEngine.dayString(mid, timeZone: $0) }
                ?? AnalyticsEngine.dayString(mid, offsetSec: offsetSec)
            let span = end - start
            if span > (longestByDay[dayKey]?.span ?? 0) {
                let eff = s.efficiency.flatMap { (0.0 < $0 && $0 <= 1.0) ? $0 : nil } ?? 0.9
                longestByDay[dayKey] = (span, Double(span) / 3600.0 * eff)
            }
            return SleepStageTotals.HistoryBlock(start: start, end: end, dayKey: dayKey)
        }
        let midsleep = SleepStageTotals.habitualMidsleepSec(blocks, offsetSec: offsetSec,
                                                            timeZone: timeZone)
        // Chronological (day-key string sort == date order) so a recent-window suffix is well-defined.
        let nightlyHours = longestByDay.keys.sorted().compactMap { longestByDay[$0]?.tstHours }
        return (midsleep, nightlyHours)
    }

    /// Resolve local calendar-day windows newest-first using the zone's actual rules.
    nonisolated static func localDayWindows(now: Int, maxDays: Int, timeZone: TimeZone) -> [LocalDayWindow] {
        guard maxDays > 0 else { return [] }
        let reference = Date(timeIntervalSince1970: TimeInterval(now))
        let resolver = LocalDayWindows(timeZone: timeZone, referenceInstant: reference)
        let newestDate = resolver.localDate(of: reference)
        let oldestFirst = resolver.backwardRun(endingAt: newestDate, count: maxDays)
            .compactMap { resolver.window(of: $0.date) }
        return Array(oldestFirst.reversed())
    }

    /// Floor a unix-seconds timestamp to 00:00:00 of its UTC calendar day. Mirrors the Android
    /// IntelligenceEngine.midnightUtc; the floorMod form is correct for any sign.
    nonisolated static func midnightUtc(_ ts: Int) -> Int { ts - floorMod(ts, 86_400) }

    /// Floor a unix-seconds timestamp to 00:00:00 of its LOCAL calendar day (#277). `offsetSec` is
    /// seconds EAST of UTC. Shift into local time, floor to the local day, shift back:
    /// `ts - floorMod(ts + offsetSec, 86400)`. floorMod keeps the floor correct for negative offsets
    /// and negative timestamps. `offsetSec == 0` reduces exactly to `midnightUtc`. Mirrors the
    /// Android IntelligenceEngine.midnightLocal byte-for-byte.
    nonisolated static func midnightLocal(_ ts: Int, offsetSec: Int) -> Int {
        ts - floorMod(ts + offsetSec, 86_400)
    }

    /// Euclidean modulo (result has the sign of the divisor) , matches Kotlin/Java Math.floorMod, so
    /// the LOCAL-midnight floor is identical across platforms for any sign of ts/offset. Swift's `%`
    /// is a remainder (sign of the dividend), which would mis-floor negative inputs.
    nonisolated private static func floorMod(_ a: Int, _ b: Int) -> Int {
        let r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? r + b : r
    }
}

// `internal`, not `private`: the two `with(...)` rebuilds below are the seams a new DailyMetric column
// is most easily dropped at (they respell every field by name), so StrandTests asserts them directly
// rather than through a copy that could drift. Nothing outside this module can see them either way.
extension DailyMetric {
    /// Rebuild with the exact legacy R-R-derived snapshot while keeping every other freshly-scored cell.
    func with(avgHrv hrv: Double, recovery r: Double?, respRateBpm resp: Double?,
              avgSdnn sdnn: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: efficiency, deepMin: deepMin,
                    remMin: remMin, lightMin: lightMin, disturbances: disturbances, restingHr: restingHr,
                    avgHrv: hrv, recovery: r, strain: strain, exerciseCount: exerciseCount,
                    spo2Pct: spo2Pct, skinTempDevC: skinTempDevC, respRateBpm: resp,
                    steps: steps, activeKcalEst: activeKcalEst,
                    spo2Red: spo2Red, spo2Ir: spo2Ir, avgSdnn: sdnn, skinTempC: skinTempC,
                    sleepHrOnly: sleepHrOnly)
    }

    /// Rebuild the immutable DailyMetric with a substituted recovery + skin-temp deviation
    /// (the struct has no `copy()`). (#78)
    func with(recovery r: Double?, skinTempDevC sd: Double?, skinTempC sa: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: efficiency, deepMin: deepMin,
                    remMin: remMin, lightMin: lightMin, disturbances: disturbances, restingHr: restingHr,
                    avgHrv: avgHrv, recovery: r, strain: strain, exerciseCount: exerciseCount,
                    spo2Pct: spo2Pct, skinTempDevC: sd, respRateBpm: respRateBpm,
                    steps: steps, activeKcalEst: activeKcalEst,
                    spo2Red: spo2Red, spo2Ir: spo2Ir, avgSdnn: avgSdnn, skinTempC: sa,
                    sleepHrOnly: sleepHrOnly)
    }

    /// Rebuild with substituted sleep-derived fields (a user-corrected wake window), leaving every
    /// non-sleep field untouched. Used by `sleepEditedDaily` so Rest/recovery score the edited sleep. (#318)
    func with(totalSleepMin tsm: Double?, efficiency eff: Double?,
              deepMin dm: Double?, remMin rm: Double?, lightMin lm: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: tsm, efficiency: eff, deepMin: dm, remMin: rm, lightMin: lm,
                    disturbances: disturbances, restingHr: restingHr, avgHrv: avgHrv, recovery: recovery,
                    strain: strain, exerciseCount: exerciseCount, spo2Pct: spo2Pct,
                    skinTempDevC: skinTempDevC, respRateBpm: respRateBpm, steps: steps,
                    activeKcalEst: activeKcalEst, spo2Red: spo2Red, spo2Ir: spo2Ir, avgSdnn: avgSdnn,
                    skinTempC: skinTempC, sleepHrOnly: sleepHrOnly)
    }
}
