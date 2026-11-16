import Foundation
import WhoopStore

/// On-device "Readiness" intelligence.
///
/// Synthesizes a handful of established, non-medical sports-science signals from the daily-metrics
/// history into a single readiness read plus the drivers behind it. Everything here is a pure,
/// deterministic function of the rows you pass in — no networking, no strap commands, no state.
///
/// Signals and their references:
/// - **HRV readiness** — z-score of today's HRV against the personal trailing baseline. A drop of
///   roughly half a standard deviation flags autonomic fatigue (Plews et al. 2013; Buchheit 2014).
/// - **Resting-HR drift** — elevated resting HR vs baseline is a classic overtraining / illness
///   signal (Lamberts et al. 2004).
/// - **Respiratory-rate drift** — a rise in sleeping respiratory rate is an early illness signal.
/// - **Training Stress Balance (ACWR)** — acute (7-day) vs chronic (28-day) strain. The 0.8–1.3
///   band is the "sweet spot"; >1.5 is associated with higher injury risk (Gabbett 2016).
/// - **Training monotony** — mean/SD of daily strain over a week; high monotony (low variety) is
///   associated with higher strain and illness (Foster 1998).
/// - **Sleep and recovery context** — duration, duration consistency and NOOP Charge add transparent
///   context, with weights renormalised when an observation is missing.
///
/// Not medical advice. These are approximations from a consumer strap; they describe trends in
/// *your own* data, nothing more.
public enum ReadinessEngine {

    // MARK: Output types

    public enum Level: String, Sendable, Equatable {
        case primed       // signals aligned, load supported
        case balanced     // nothing notable either way
        case strained     // one meaningful signal down / load high
        case rundown      // several recovery signals down
        case insufficient // not enough history yet
    }

    public enum Flag: String, Sendable, Equatable, Hashable {
        case good, neutral, watch, bad
    }

    /// Locale-free numeric evidence. Clients format and localize it at the display boundary.
    public enum Evidence: Sendable, Equatable {
        case metric(value: Double, baseline: Double, unit: String, decimals: Int)
        case value(Double, unit: String, decimals: Int)
        case trainingLoad(acute: Double, chronic: Double)
        case monotony(Double)
    }

    public struct Signal: Sendable, Equatable {
        public let key: String      // "hrv" | "rhr" | "respRate" | "acwr" | "monotony"
        public let label: String    // short human label
        public let evidence: String?
        public let evidenceData: Evidence?
        public let detail: String   // one-line plain-English read
        public let flag: Flag
        public init(key: String, label: String, evidence: String? = nil,
                    evidenceData: Evidence? = nil, detail: String, flag: Flag) {
            self.key = key; self.label = label; self.evidence = evidence
            self.evidenceData = evidenceData; self.detail = detail; self.flag = flag
        }
    }

    public struct Readiness: Sendable, Equatable {
        public let level: Level
        public let headline: String
        public let summary: String
        public let signals: [Signal]
        /// Acute:chronic workload ratio (nil if not enough strain history).
        public let acwr: Double?
        /// Foster training monotony over the last week (nil if not enough strain history).
        public let monotony: Double?
        /// Transparent 0...100 wellness estimate. nil when fewer than two usable inputs exist.
        public let score: Int?
        /// Share of the documented signal weights supported by usable observations, in 0...1.
        public let dataCompleteness: Double
        /// How much history backs this read (HRV/RHR baseline density) — so the card can show
        /// calibrating / building / solid instead of a confident number off a 7-night baseline.
        public let confidence: ScoreConfidence
        public init(level: Level, headline: String, summary: String,
                    signals: [Signal], acwr: Double?, monotony: Double?,
                    score: Int? = nil, dataCompleteness: Double = 0,
                    confidence: ScoreConfidence = .calibrating) {
            self.level = level; self.headline = headline; self.summary = summary
            self.signals = signals; self.acwr = acwr; self.monotony = monotony
            self.score = score; self.dataCompleteness = dataCompleteness
            self.confidence = confidence
        }
    }

    // MARK: Tunables (named so the thresholds are auditable)

    private static let baselineWindow = 30   // days for HRV / RHR / RR baselines
    private static let minBaseline    = 7    // need at least this many baseline nights
    private static let acuteWindow    = 7
    private static let chronicWindow  = 28
    private static let minChronic     = 14   // need at least this much strain history for ACWR

    // MARK: Entry point

    /// Evaluate readiness from daily metrics. `days` may be in any order; the most recent day is
    /// treated as "today" unless `today` (a YYYY-MM-DD string) is given.
    public static func evaluate(days: [DailyMetric], today: String? = nil) -> Readiness {
        // v7.0.2 perf (#707): `evaluate` SORTS the entire daily history and walks trailing windows every
        // call, and it is read from a SwiftUI computed property — so a `body` re-evaluation (the iOS twin of
        // a Compose recompose) re-runs the full-history sort on each ~1 Hz live-HR tick. The Today view also
        // memoizes this at the View layer (its `todayInputKey`); this engine-level cache additionally shields
        // every OTHER caller and the first/uncached read. Key = `today` + a fingerprint over ONLY the row
        // fields the synthesis reads, so a new sync re-keys but a
        // cosmetic reorder does not. Result is a small `Readiness`; no row arrays are retained.
        let key = ReadinessKey(today: today, rows: Self.rowsFingerprint(days))
        return evaluateCache.value(key) { evaluateUncached(days: days, today: today) }
    }

    private struct ReadinessKey: Hashable { let today: String?; let rows: StreamFingerprint }
    private static let evaluateCache = AnalyticsMemoCache<ReadinessKey, Readiness>(capacity: 16)

    /// Fingerprint the readiness-relevant columns of the daily rows without re-sorting or copying them.
    /// Order-independent per-row hash (folded into the checksum), so two identical histories in different
    /// order key the same — `evaluate` sorts internally, so order never changes the result.
    private static func rowsFingerprint(_ days: [DailyMetric]) -> StreamFingerprint {
        var sum: UInt64 = 1469598103934665603
        var minDayHash = 0, maxDayHash = 0
        for (i, d) in days.enumerated() {
            // All folds stay in UInt64 — `Double.bitPattern` is already a UInt64 (its sign bit can exceed
            // Int64.max, so an Int64 round-trip would TRAP), and `Int.bitPattern` reinterprets without loss.
            var h: UInt64 = UInt64(bitPattern: Int64(d.day.hashValue))
            h = (h &* 1099511628211) ^ (d.avgHrv ?? -1).bitPattern
            h = (h &* 1099511628211) ^ (d.restingHr.map { UInt64(bitPattern: Int64($0)) } ?? .max)
            h = (h &* 1099511628211) ^ (d.respRateBpm ?? -1).bitPattern
            h = (h &* 1099511628211) ^ (d.strain ?? -1).bitPattern
            h = (h &* 1099511628211) ^ (d.totalSleepMin ?? -1).bitPattern
            h = (h &* 1099511628211) ^ (d.recovery ?? -1).bitPattern
            sum ^= h                                   // commutative fold → order-independent
            let dh = d.day.hashValue
            if i == 0 { minDayHash = dh; maxDayHash = dh } else { minDayHash = min(minDayHash, dh); maxDayHash = max(maxDayHash, dh) }
        }
        return StreamFingerprint(count: days.count, firstTs: minDayHash, lastTs: maxDayHash, checksum: sum)
    }

    private static func evaluateUncached(days: [DailyMetric], today: String?) -> Readiness {
        // A repeated sync can surface the same logical day more than once to a caller. Pick the more
        // complete row before any baseline/window math so a duplicate cannot count as another night.
        let sorted = deduplicated(days).sorted { $0.day < $1.day }
        // When an explicit `today` is given (the dashboard passes the device's real local day key), use
        // the row for THAT day and nothing else: a stale historical import has no row for today, so the
        // readiness card reads "insufficient" rather than synthesizing off the newest stored — possibly
        // months-old — row (issue #23/#24). With no `today` (live-strap default callers) fall back to the
        // most recent row exactly as before, so nothing wearing the strap nightly changes.
        let latestRow: DailyMetric?
        if let today { latestRow = sorted.first { $0.day == today } } else { latestRow = sorted.last }
        guard let latest = latestRow else {
            return Readiness(level: .insufficient,
                             headline: "Readiness",
                             summary: "Wear the strap for a few nights and your readiness read will appear here.",
                             signals: [], acwr: nil, monotony: nil)
        }
        let history = sorted.filter { $0.day < latest.day }   // everything before today

        var signals: [Signal] = []

        // HRV readiness ------------------------------------------------------
        let hrvSignal = zSignal(
            value: latest.avgHrv.flatMap { (5...300).contains($0) ? $0 : nil },
            baseline: history.suffix(baselineWindow).compactMap { $0.avgHrv }.filter { (5...300).contains($0) },
            key: "hrv", label: "HRV",
            unit: "ms",
            decimals: 0,
            higherIsBetter: true,
            logDomain: true,   // RD1: lnRMSSD — HRV is right-skewed
            cfg: Baselines.readinessHRVLnCfg,   // RD2: ln-space spine, reject off
            goodText: "above your baseline - well recovered",
            neutralText: "in your normal range",
            watchText: "a touch below baseline",
            badText: "suppressed - a sign of autonomic fatigue")
        if let s = hrvSignal { signals.append(s) }

        // Resting-HR drift ---------------------------------------------------
        let rhrSignal = zSignal(
            value: latest.restingHr.map(Double.init).flatMap { (25...220).contains($0) ? $0 : nil },
            baseline: history.suffix(baselineWindow).compactMap { $0.restingHr.map(Double.init) }
                .filter { (25...220).contains($0) },
            key: "rhr", label: "Resting HR",
            unit: "bpm",
            decimals: 0,
            higherIsBetter: false,
            cfg: Baselines.restingHRCfg,   // RD2: raw-bpm spine, reject off
            goodText: "at or below baseline",
            neutralText: "in your normal range",
            watchText: "running a little high",
            badText: "elevated - overtraining or illness can do this")
        if let s = rhrSignal { signals.append(s) }

        // Respiratory-rate drift (illness early signal) ----------------------
        // respRateBpm may be a clean cloud value OR a higher-variance on-device RSA estimate, so gate
        // BOTH the latest value and the baseline mean to the plausible sleeping-RR band (8–25 bpm) and
        // use wider resp-only z thresholds (WATCH 1.5 / BAD 2.0) than HRV/RHR so a single noisy night
        // can't flip RUNDOWN. Mirrors the Kotlin reference (#78) for cross-platform parity.
        if let rr = latest.respRateBpm, SleepStager.respPlausibleRangeBpm.contains(rr) {
            let base = history.suffix(baselineWindow).compactMap { $0.respRateBpm }
                .filter { SleepStager.respPlausibleRangeBpm.contains($0) }
            if base.count >= minBaseline, let m = mean(base),
               SleepStager.respPlausibleRangeBpm.contains(m), let sd = sampleSD(base), sd > 0 {
                let z = (rr - m) / sd
                if z >= 2.0 {
                    signals.append(Signal(key: "respRate", label: "Respiratory rate",
                        evidence: evidence(value: rr, baseline: m, unit: "rpm", decimals: 1),
                        evidenceData: .metric(value: rr, baseline: m, unit: "rpm", decimals: 1),
                        detail: "up vs baseline - sometimes an early sign of getting sick", flag: .bad))
                } else if z >= 1.5 {
                    signals.append(Signal(key: "respRate", label: "Respiratory rate",
                        evidence: evidence(value: rr, baseline: m, unit: "rpm", decimals: 1),
                        evidenceData: .metric(value: rr, baseline: m, unit: "rpm", decimals: 1),
                        detail: "slightly raised vs baseline", flag: .watch))
                } else {
                    signals.append(Signal(key: "respRate", label: "Respiratory rate",
                        evidence: evidence(value: rr, baseline: m, unit: "rpm", decimals: 1),
                        evidenceData: .metric(value: rr, baseline: m, unit: "rpm", decimals: 1),
                        detail: "in your normal range", flag: .neutral))
                }
            }
        }

        // Training Stress Balance (ACWR) + monotony --------------------------
        let strainSeries = sorted.compactMap { $0.strain }.filter { (0...100).contains($0) }
        var acwr: Double? = nil
        var monotony: Double? = nil
        if strainSeries.count >= minChronic {
            let acute = mean(Array(strainSeries.suffix(acuteWindow)))!
            let chronic = mean(Array(strainSeries.suffix(chronicWindow)))!
            if chronic > 0 {
                let ratio = acute / chronic
                acwr = ratio
                signals.append(acwrSignal(ratio, acute: acute, chronic: chronic))
            }
            // Foster monotony over the last week of strain.
            let week = Array(strainSeries.suffix(acuteWindow))
            if week.count >= 4, let sd = sampleSD(week), sd > 0, let m = mean(week) {
                let mono = m / sd
                monotony = mono
                if mono >= 2.0 {
                    signals.append(Signal(key: "monotony", label: "Training variety",
                        evidence: "monotony \(String(format: "%.1f", mono))",
                        evidenceData: .monotony(mono),
                        detail: "low - similar strain every day raises strain/illness risk", flag: .watch))
                }
            }
        }

        // Sleep duration ----------------------------------------------------
        // There is no reliable bedtime timestamp in DailyMetric, so "consistency" here explicitly means
        // night-to-night DURATION consistency. We do not claim schedule consistency from absent data.
        if let sleep = latest.totalSleepMin, (30...960).contains(sleep) {
            let flag: Flag
            let detail: String
            switch sleep {
            case 420...600: flag = .good; detail = "duration supports training today"
            case 360..<420: flag = .neutral; detail = "a little short, but within a usable range"
            case 300..<360: flag = .watch; detail = "short sleep may limit harder training"
            default: flag = .bad; detail = "very short or unusually long sleep lowers confidence"
            }
            signals.append(Signal(key: "sleepDuration", label: "Sleep duration",
                                  evidence: "\(String(format: "%.1f", sleep / 60)) h",
                                  evidenceData: .value(sleep / 60, unit: "h", decimals: 1),
                                  detail: detail, flag: flag))
        }

        let recentSleep = Array((history + [latest]).suffix(7))
            .compactMap { $0.totalSleepMin }.filter { (30...960).contains($0) }
        if recentSleep.count >= 4, let variation = sampleSD(recentSleep) {
            let flag: Flag = variation <= 45 ? .good : (variation <= 90 ? .watch : .bad)
            let detail = variation <= 45 ? "sleep duration has been consistent"
                : (variation <= 90 ? "sleep duration has varied recently" : "sleep duration has varied widely")
            signals.append(Signal(key: "sleepConsistency", label: "Sleep consistency",
                                  evidence: "\(Int(variation.rounded())) min variation",
                                  evidenceData: .value(variation, unit: "min variation", decimals: 0),
                                  detail: detail, flag: flag))
        }

        if let recovery = latest.recovery, (0...100).contains(recovery) {
            let flag: Flag = recovery >= 67 ? .good : (recovery >= 34 ? .neutral : .bad)
            let detail = recovery >= 67 ? "today's Charge supports training"
                : (recovery >= 34 ? "today's Charge is moderate" : "low Charge favours recovery")
            signals.append(Signal(key: "recovery", label: "Recovery",
                                  evidence: "\(Int(recovery.rounded()))%",
                                  evidenceData: .value(recovery, unit: "%", decimals: 0),
                                  detail: detail, flag: flag))
        }

        let (level, headline, summary) = synthesize(signals: signals,
                                                    hasHistory: !history.isEmpty || acwr != nil)
        // RD-confidence: surface how much history backs the read (HRV baseline density, the primary
        // readiness driver). A read off a 7-night baseline must not look as certain as one off the full
        // 30-night window. Insufficient reads carry .calibrating.
        let hrvBaselineNights = history.suffix(baselineWindow).compactMap { $0.avgHrv }
            .filter { (5...300).contains($0) }.count
        let scored = weightedScore(signals)
        let confidence = ScoreConfidence.readiness(hasRead: level != .insufficient,
                                                   baselineNights: hrvBaselineNights,
                                                   fullWindow: baselineWindow)
        return Readiness(level: level, headline: headline, summary: summary,
                         signals: signals, acwr: acwr, monotony: monotony,
                         score: scored.score, dataCompleteness: scored.completeness,
                         confidence: confidence)
    }

    // MARK: Signal builders

    /// Build a z-score signal for a metric where the baseline is the trailing window.
    private static func zSignal(value: Double?, baseline: [Double],
                                key: String, label: String, unit: String, decimals: Int,
                                higherIsBetter: Bool, logDomain: Bool = false,
                                cfg: MetricCfg,
                                goodText: String, neutralText: String,
                                watchText: String, badText: String) -> Signal? {
        guard let v = value, v.isFinite,
              baseline.count >= minBaseline, baseline.allSatisfy(\.isFinite) else { return nil }
        // RD1: right-skewed metrics (HRV/RMSSD) are z-scored in the LOG domain — lnRMSSD is closer to
        // normal, so a symmetric z is statistically valid, whereas a raw-ms z over-weights the long
        // upper tail and misstates tail rarity (Plews/Altini; the app's own HRVReadiness works this
        // way). RHR/resp are ~normal and stay linear. Evidence stays in the metric's own units, but the
        // baseline shown is then the GEOMETRIC mean (exp of the log-mean) — a typical night, not an
        // outlier-inflated arithmetic mean.
        let tv = logDomain ? log(max(v, 1.0)) : v
        let tb = logDomain ? baseline.map { log(max($0, 1.0)) } : baseline
        // RD2: fold the trailing baseline through the shared Winsorized-EWMA spine — recency-weighted,
        // σ-floored (a tight baseline can't saturate the z), and Winsor-clamped so a single freak night
        // is DAMPED not folded raw — instead of a flat mean + sample SD. Hard-outlier REJECTION is off
        // (`rejectHardOutliers: false`): a re-folded trailing window must ADAPT to a recent sustained
        // shift (fitness change / device swap) rather than reject the new normal as a run of outliers —
        // the window-fold vs incremental-fold distinction, validated on real HRV history. `cfg` is in
        // the SAME space as `tb` (ln for HRV, linear for RHR); center + spread come back σ-floored.
        let state = Baselines.foldHistory(tb.map { Optional($0) }, cfg: cfg, rejectHardOutliers: false)
        guard state.usable else { return nil }
        let sigma = max(1.253 * state.spread, 1e-9)   // robust σ from the EWMA-abs-dev spread
        guard sigma > 0 else { return nil }
        let m = state.baseline
        // Orient z so positive always means "better".
        let z = (higherIsBetter ? (tv - m) : (m - tv)) / sigma
        let flag: Flag
        let text: String
        switch z {
        case 0.5...:        flag = .good;    text = goodText
        case -0.5..<0.5:    flag = .neutral; text = neutralText
        case -1.0 ..< -0.5: flag = .watch;   text = watchText
        default:            flag = .bad;     text = badText
        }
        return Signal(key: key, label: label,
                      evidence: evidence(value: v, baseline: logDomain ? exp(m) : m,
                                         unit: unit, decimals: decimals),
                      evidenceData: .metric(value: v, baseline: logDomain ? exp(m) : m,
                                            unit: unit, decimals: decimals),
                      detail: text, flag: flag)
    }

    private static func acwrSignal(_ ratio: Double, acute: Double, chronic: Double) -> Signal {
        let pct = String(format: "%.2f", ratio)
        let evidence = "7d \(String(format: "%.1f", acute)) / 28d \(String(format: "%.1f", chronic))"
        switch ratio {
        case ..<0.8:
            return Signal(key: "acwr", label: "Training load",
                evidence: evidence,
                evidenceData: .trainingLoad(acute: acute, chronic: chronic),
                detail: "ramping down (acute:chronic \(pct)) - room to build", flag: .watch)
        case 0.8..<1.3:
            return Signal(key: "acwr", label: "Training load",
                evidence: evidence,
                evidenceData: .trainingLoad(acute: acute, chronic: chronic),
                detail: "in the sweet spot (acute:chronic \(pct))", flag: .good)
        case 1.3..<1.5:
            return Signal(key: "acwr", label: "Training load",
                evidence: evidence,
                evidenceData: .trainingLoad(acute: acute, chronic: chronic),
                detail: "building fast (acute:chronic \(pct)) - watch fatigue", flag: .watch)
        default:
            return Signal(key: "acwr", label: "Training load",
                evidence: evidence,
                evidenceData: .trainingLoad(acute: acute, chronic: chronic),
                detail: "spiking (acute:chronic \(pct)) - higher injury risk", flag: .bad)
        }
    }

    private static func evidence(value: Double, baseline: Double, unit: String, decimals: Int) -> String {
        "\(format(value, decimals: decimals)) vs \(format(baseline, decimals: decimals)) \(unit)"
    }

    private static func format(_ value: Double, decimals: Int) -> String {
        decimals == 0
            ? String(Int(value.rounded()))
            : String(format: "%.\(decimals)f", value)
    }

    // MARK: Synthesis

    private static func synthesize(signals: [Signal], hasHistory: Bool) -> (Level, String, String) {
        guard hasHistory, !signals.isEmpty else {
            return (.insufficient, "Readiness",
                    "A few more nights of data and your readiness read will sharpen.")
        }
        let bad = signals.filter { $0.flag == .bad }
        let watch = signals.filter { $0.flag == .watch }
        let good = signals.filter { $0.flag == .good }
        let recoveryDown = signals.contains {
            ["hrv", "rhr", "respRate", "sleepDuration", "recovery"].contains($0.key) && $0.flag == .bad
        }
        let loadHigh = signals.contains { $0.key == "acwr" && $0.flag == .bad }

        if bad.count >= 2 || (recoveryDown && loadHigh) {
            return (.rundown, "Run down",
                    "Several signals are down at once. Treat today as recovery - easy movement, real sleep tonight.")
        }
        if recoveryDown || loadHigh || bad.count >= 1 {
            return (.strained, "Strained",
                    "One of your signals is flagging. You can train, but keep it controlled and bank the recovery.")
        }
        if good.count >= 2 && watch.isEmpty {
            return (.primed, "Primed",
                    "Your signals are aligned and your load is supported. A harder session is well backed today.")
        }
        return (.balanced, "Balanced",
                "Nothing's flagging. Train to feel - your body's holding steady.")
    }

    /// Weighted score kept separate from the categorical synthesis so the long-standing Push/Maintain/Rest
    /// behavior remains stable. Missing signals are excluded and the remaining weights are renormalised.
    private static func weightedScore(_ signals: [Signal]) -> (score: Int?, completeness: Double) {
        let weights: [String: Double] = [
            "hrv": 0.20, "rhr": 0.15, "respRate": 0.05,
            "acwr": 0.15, "monotony": 0.05,
            "sleepDuration": 0.15, "sleepConsistency": 0.10, "recovery": 0.15,
        ]
        let values: [Flag: Double] = [.good: 85, .neutral: 65, .watch: 45, .bad: 20]
        var used = Set<String>()
        var weighted = 0.0
        var totalWeight = 0.0
        for signal in signals where used.insert(signal.key).inserted {
            guard let weight = weights[signal.key], let value = values[signal.flag] else { continue }
            weighted += value * weight
            totalWeight += weight
        }
        let completeness = min(1, max(0, totalWeight))
        guard used.count >= 2, totalWeight >= 0.25 else { return (nil, completeness) }
        return (Int(min(100, max(0, weighted / totalWeight)).rounded()), completeness)
    }

    private static func deduplicated(_ days: [DailyMetric]) -> [DailyMetric] {
        var chosen: [String: DailyMetric] = [:]
        for day in days where !day.day.isEmpty {
            guard let existing = chosen[day.day] else { chosen[day.day] = day; continue }
            let candidate = (quality(day), stableKey(day))
            let current = (quality(existing), stableKey(existing))
            if candidate.0 > current.0 || (candidate.0 == current.0 && candidate.1 > current.1) {
                chosen[day.day] = day
            }
        }
        return Array(chosen.values)
    }

    private static func quality(_ day: DailyMetric) -> Int {
        var count = 0
        if let value = day.totalSleepMin, (30...960).contains(value) { count += 1 }
        if let value = day.avgHrv, (5...300).contains(value) { count += 1 }
        if let value = day.recovery, (0...100).contains(value) { count += 1 }
        if let value = day.strain, (0...100).contains(value) { count += 1 }
        if let value = day.respRateBpm, SleepStager.respPlausibleRangeBpm.contains(value) { count += 1 }
        if let value = day.restingHr, (25...220).contains(value) { count += 1 }
        return count
    }

    private static func stableKey(_ day: DailyMetric) -> String {
        [day.totalSleepMin, day.avgHrv, day.recovery, day.strain,
         day.respRateBpm, day.restingHr.map(Double.init)]
            .map { $0.map { String(format: "%020.8f", $0) } ?? "-" }
            .joined(separator: "|")
    }

    // MARK: Stats helpers

    static func mean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    /// Sample standard deviation (n-1). nil for fewer than 2 points.
    static func sampleSD(_ xs: [Double]) -> Double? {
        guard xs.count >= 2, let m = mean(xs) else { return nil }
        let ss = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return (ss / Double(xs.count - 1)).squareRoot()
    }
}
