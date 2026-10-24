Warning: truncated output (original token count: 49871)
Total output lines: 3164

import Foundation
import WhoopProtocol

// SleepStager.swift — sleep/wake detection + APPROXIMATE 4-class staging.
//
// Ported from server/ingest/app/analysis/sleep.py and sleep_features.py.
//
// HONEST HEDGING: these stages are APPROXIMATIONS, not PSG-validated, not medical
// advice. The EEG-free 4-class ceiling is ~65–73% epoch agreement (Walch 2019).
// Light/deep separation is the weakest link — deep-minute estimates are the least
// reliable output.
//
// Pipeline (30 s epochs):
//   Stage 0  gravity-stillness sleep/wake spine → in-bed sessions. Cole–Kripke
//            (te Lindert 30 s) computed as a citable cross-check; HR confirms runs.
//   Stage 1  per-epoch cardiorespiratory features over a rolling 5-min window
//            (mean HR, DoG-HR variability, RMSSD/SDNN from RR, resp rate + RRV).
//   Stage 2  transparent percentile-band classifier → {wake, light, deep, rem}.
//   Stage 3  median smoothing + physiology re-imposition (no early REM, deep in
//            the first third of the night).
//
// NOTE: the Python source computes RMSSD/SDNN/HF/LF/LFHF via neurokit2 per epoch.
// On-device we have no neurokit2/scipy, so frequency-domain features (HF, LF/HF)
// are omitted and the parasympathetic-tone signal is RMSSD only. Respiration rate
// + RRV are derived from the raw 1 Hz resp channel with a simple peak detector
// (the Python source explicitly derives these "robustly ourselves" too, so this
// path is a faithful port rather than an approximation). The classifier seam,
// percentile bands, smoothing, and physiology rules are reproduced exactly.

// MARK: - Public output shapes

/// A contiguous sleep-stage segment. Times are wall-clock unix seconds.
public struct StageSegment: Equatable, Sendable, Codable {
    public var start: Int
    public var end: Int
    public var stage: String  // "wake" | "light" | "deep" | "rem"
    public init(start: Int, end: Int, stage: String) {
        self.start = start; self.end = end; self.stage = stage
    }
}

/// A detected sleep session (in-bed span) with APPROXIMATE staging.
public struct SleepSession: Equatable, Sendable {
    public let start: Int
    public let end: Int
    /// asleep / in-bed in [0, 1] (AASM TST/TIB; asleep = in-bed − wake).
    public let efficiency: Double
    public let stages: [StageSegment]
    /// Lowest 5-min rolling-mean HR during the session (bpm), or nil.
    public let restingHR: Int?
    /// Mean RMSSD over 5-min windows across the session (ms), or nil.
    public let avgHRV: Double?
    /// Staged WITHOUT a motion spine, from heart rate alone (#1801).
    ///
    /// True only for a strap that streams HR but banks no motion, where Stage 0's gravity-stillness
    /// spine has nothing to work with. Such a night is weaker by construction, not by tuning: with
    /// motion gone a quiet evening at rest can sit in the sleep band. It is allowed to describe itself
    /// — duration, stages, Rest — and must NOT reach anything it cannot be unwound from, which is why
    /// `restingHR` and `avgHRV` are left nil on one rather than filtered out downstream.
    ///
    /// Kotlin twin: `DetectedSleep.hrOnly` (the model names diverge, `DetectedSleep`/`SleepSession`).
    public let hrOnly: Bool

    public init(start: Int, end: Int, efficiency: Double, stages: [StageSegment],
                restingHR: Int?, avgHRV: Double?, hrOnly: Bool = false) {
        self.start = start; self.end = end; self.efficiency = efficiency
        self.stages = stages; self.restingHR = restingHR; self.avgHRV = avgHRV
        self.hrOnly = hrOnly
    }
}

public enum SleepStager {

    // MARK: - #1943: RHR bin-gate thresholds (shared by sessionRestingHR and rhrBinGateLogLine)
    // One constant per threshold, read by both the gate and its conformance check, so a drift
    // between the two is structurally impossible rather than merely documented.

    /// Minimum samples in a 5-min bin for it to qualify as a candidate for the night's resting HR.
    /// A one-sample bin at the edge of a wear gap cannot become the floor.
    public static let rhrMinBinSamples: Int = 5
    /// Minimum plausible mean HR (bpm) for a bin to qualify. A dropout-driven sub-physiological
    /// dip cannot become the floor.
    public static let rhrMinPlausibleBpm: Double = 25

    // MARK: - Stage 0 constants (sleep.py)

    /// Per-sample gravity change (g) at/below which a sample is "still".
    public static let gravityStillThresholdG: Double = 0.01
    /// Rolling stillness window (minutes).
    public static let stillWindowMin: Int = 15
    /// Fraction of still samples to call the window-center "sleep".
    public static let stillFraction: Double = 0.70
    /// Data gap (minutes) that always breaks a run.
    public static let maxGapMin: Int = 20
    /// Runs shorter than this (minutes) are absorbed into neighbours.
    public static let mergeMin: Int = 15
    /// A sleep run must exceed this (minutes) to count as a session.
    public static let minSleepMin: Int = 60
    /// Assumed sample interval (seconds) when not inferable.
    public static let defaultIntervalS: Double = 60.0

    // MARK: - Daytime false-sleep guard (#90)

    // A long, still, sedentary daytime stretch (reading, a desk, a sofa) is gravity-
    // indistinguishable from a real nap, so the gravity spine alone misclassifies it as
    // sleep. The fix is NOT to drop daytime sleep — real naps are legitimate sessions —
    // but to hold a window whose CENTER falls in the local daytime band to a stricter bar:
    // it must be long enough to be a real nap AND show a genuine cardiac dip (a sedentary
    // stretch keeps a near-baseline HR). Overnight windows are UNCHANGED.

    /// Local hour (inclusive) at which the stricter daytime bar begins.
    public static let daytimeBandStartHour: Int = 11
    /// Local hour (exclusive) at which the stricter daytime bar ends. A window whose center
    /// is in [start, end) local hours is "daytime"; everything else is "overnight".
    public static let daytimeBandEndHour: Int = 20
    /// A still sleep run that resumes within this gap of an overnight sleep chain is the
    /// night's TAIL — a late wake past the daytime-band start, or a brief morning stir then
    /// back to sleep — not an isolated daytime nap, so it skips the daytime guard. Without
    /// this, a real sleep that ran past ~11:00 local had its tail rejected as a "nap" and the
    /// displayed wake time was truncated to late morning (late sleepers / shift workers).
    // Reimplemented from @vulnix0x4's PR #353.
    public static let nightContinuationGapMin: Int = 90
    /// A daytime window must run at least this long (minutes) to count — short still
    /// daytime stretches are the dominant false-positive and are rejected outright.
    public static let daytimeMinSleepMin: Int = 90
    /// A daytime window's resting HR (lowest 5-min rolling mean) must be at or below
    /// baseline × this to confirm a real cardiac dip. Stricter than the overnight 1.05:
    /// a true nap dips BELOW the waking-day median, sedentary stillness does not.
    public static let daytimeRestingHRMult: Double = 0.95

    // MARK: - H4 physiological in-bed span cap (#547 / #531 / #509 / tail)

    /// Maximum plausible in-bed span (seconds) for a SINGLE assembled main-sleep run. No real single night
    /// runs longer than this: a 12 h+ "sleep" is a bad-clock artefact (a stale/duplicated timestamp range,
    /// or a strap that banked one frozen still stretch under a wrong clock) reading as one enormous still
    /// block — which then reports a 12 h sleep and poisons Rest / the debt ledger / the headline. 16 h is
    /// well above any genuine night (incl. recovery/illness sleeps and late weekend lie-ins) yet below the
    /// clock-artefact range. A run whose span exceeds this is DROPPED (not silently truncated to 16 h, which
    /// would fabricate a wake time): an over-long block is not trustworthy enough to assert a span for at
    /// all. (#547 / #531 / #509 tail)
    public static let maxMainSleepSpanS: Int = 16 * 60 * 60

    // MARK: - H7 morning-stillness nap suppression (#531)

    // After a real overnight wake the wrist is often still (sitting with coffee, back in bed scrolling, a
    // sofa) for a stretch that the gravity spine reads as a fresh "nap" — #531's 9 am phantom nap right after
    // the night ended. It is NOT a night-tail continuation (that is handled by `nightContinuationGapMin` and
    // exempted), and it can clear the ordinary daytime guard (it is long + the post-wake HR is still low), so
    // it slipped through. H7 holds a daytime block that BEGINS within `morningStillnessWindowMin` of the
    // just-detected overnight wake to a STRONGER bar than an ordinary daytime nap: it must show a genuine
    // SUSTAINED re-onset — a real second sleep dips clearly below the day median, not merely near it.

    /// A daytime block whose onset falls within this many minutes AFTER an overnight chain's wake is treated
    /// as suspected morning residual stillness and held to the stronger re-onset bar below. ~3 h covers the
    /// post-wake window where residual stillness masquerades as a nap; a genuine afternoon nap (hours later)
    /// is past it and faces only the ordinary daytime guard. (#531)
    public static let morningStillnessWindowMin: Int = 180

    /// The stronger resting-HR bar (× day baseline) a suspected-morning-stillness block must clear to be kept
    /// as a real re-onset. Stricter than the ordinary daytime `daytimeRestingHRMult` (0.95): residual waking
    /// stillness keeps a near-waking HR, so only a block that dips clearly (a true second sleep) survives.
    public static let morningReonsetRestingHRMult: Double = 0.90

    /// The persisted v18 BAND sleep_state value that means "asleep" (Interpreter's `(sb>>4)&3`: 0 wake /
    /// 1 still / 2 asleep / 3 up). The strap's OWN scored band state — an independent anchor we CONSUME to
    /// confirm a borderline morning re-onset (H7) without re-deriving anything. (#531 / H8 consume)
    public static let bandStateAsleep: Int = 2

    /// Fraction of a suspected-morning-stillness block's epochs whose persisted band sleep_state must read
    /// "asleep" (`bandStateAsleep`) for the strap's OWN signal to CONFIRM a genuine re-onset and KEEP the
    /// block even when its HR dip is borderline. A real second sleep the strap itself scored asleep is a
    /// strong, honest anchor; a residual-stillness false nap reads "still"/"up", not "asleep". ≥0.6 keeps
    /// this conservative. (H8 consume)
    public static let morningReonsetBandAsleepFrac: Double = 0.6
    /// Seconds in a calendar day (for local-hour-of-day arithmetic).
    static let secondsPerDay: Int = 86_400
    /// Floor on the rolling-window size in samples.
    public static let minWindowSamples: Int = 3
    /// A run is HR-confirmed only if mean HR ≤ baseline × this.
    public static let hrSleepBaselineMult: Double = 1.05
    /// Skip HR refinement (trust gravity) when fewer than this many HR samples.
    public static let hrRefineMinSamples: Int = 30
    /// Consecutive sleep epochs required to declare onset.
    public static let onsetPersistEpochs: Int = 3

    // MARK: - Off-wrist backstop (#500)

    // A wrist-OFF stretch reads as perfectly still gravity with no contrary motion, so the
    // gravity spine classifies it as sleep — and because the off-wrist epochs carry zero/missing
    // HR the daytime guard treats them as "missing data" and lets them through (a daytime desk-off
    // strap logged a phantom sleep). The backstop measures OFF-WRIST COVERAGE: while the strap is
    // worn it emits ~1 Hz HR, so a long CONTIGUOUS gap in the HR samples spanning part of a candidate
    // sleep run is a strong off-wrist proxy that works even when explicit WRIST_OFF events are absent;
    // explicit WRIST_OFF→WRIST_ON intervals (when the store surfaces them) sharpen it. A run is dropped
    // only when that coverage reaches maxOffWristSleepFraction of its duration (the FRACTIONAL rule from
    // j0b-dev's #504), so a real night that over-extends into a SHORT off-wrist tail survives. This is
    // independent of the daytime band — off-wrist time is off-wrist day or night, and a night-tail
    // continuation does NOT exempt it.
    /// A contiguous HR-sample gap of at least this many minutes contributes to a candidate run's
    /// off-wrist coverage. Sized at maxGapMin so a real worn night (dense ~1 Hz HR, or PPG-derived HR
    /// on a 5/MG) contributes ~no gap, but a wrist-off stretch (HR flatlines to no samples) contributes
    /// its whole span. The edges of the run count too: a run that begins/ends far from its nearest HR
    /// sample is partially uncovered.
    public static let offWristHRGapMin: Int = 20

    /// FRACTIONAL off-wrist rejection (#500), design credited to j0b-dev's #504 analysis. A candidate
    /// sleep run is dropped ONLY when its off-wrist coverage — the UNION of its long HR-gap spans and
    /// any WRIST_OFF→WRIST_ON intervals overlapping it — is at least this fraction of its duration. The
    /// earlier guard dropped the WHOLE run on ANY contiguous HR gap or ANY single WRIST_OFF blip, which
    /// nuked a real night that over-extended into a SHORT off-wrist morning tail (strap removed shortly
    /// after waking) or that contained one stray WRIST_OFF event. 0.5 keeps such a night (<50% off-wrist)
    /// while still dropping an all-day desk strap (≈100% gap) or a session genuinely spent off-wrist.
    public static let maxOffWristSleepFraction: Double = 0.5

    /// Minimum average HR-stream density for the off-wrist HR-gap proxy to be trusted (#507). The proxy
    /// reads a >`offWristHRGapMin`-minute hole in HR as "off the wrist" — valid only when HR is otherwise
    /// dense (live 5/MG, or a worn night with continuous HR), so a real gap is anomalous. A WHOOP 4.0's
    /// SYNCED night is reconstructed mostly from MOTION with sparse, derived HR, whose natural gaps would
    /// otherwise read as off-wrist and wrongly DROP a real night. So if the HR stream averages fewer than
    /// one sample per this many seconds, we don't assert off-wrist from gaps at all (WRIST_OFF events
    /// still apply). Self-consistent: a night sparse enough to be >50% gap-covered is, by definition,
    /// below this density, so it is spared. Measured over the whole stream, so an off-wrist HOLE inside an
    /// otherwise dense, worn day (#500) is still caught.
    static let hrDenseSpacingS: Int = 600   // one HR sample per 10 minutes, averaged over the stream

    // MARK: - Sparse-gravity robustness (#308)

    // On an un-unlocked WHOOP 5.0 the strap backfills mostly v18/v26 records where gravity is
    // sparse/clumped (~25% coverage), so the gravity-only Stage-0 spine fragments the night at
    // every >maxGapMin gravity gap and detectSleep drops every <minSleepMin fragment — collapsing
    // a ~6 h night to ~1 h. The fix derives the in-bed spine from a sustained low-HR stretch and
    // uses gravity stillness only to REFINE it, but is GATED ENTIRELY behind a "gravity is sparse"
    // condition so dense WHOOP-4.0 nights stay BYTE-IDENTICAL (a 4.0 regression is unacceptable).

    /// Gravity is "sparse" when its timespan covers less than this fraction of the HR-sample
    /// timespan. A dense 4.0 night has gravity spanning the whole HR window (≈1.0) and never
    /// trips this; a 5.0 backfill clumps gravity into a fraction of the night.
    public static let sparseGravitySpanFrac: Double = 0.5
    /// When sparse, HR drives the in-bed spine: an HR sample is "sleep-band" when its bpm ≤
    /// baseline × this. Reuses the overnight HR-confirmation multiplier so the band is the same
    /// one detectSleep already trusts to confirm a run.
    public static let hrSleepBandMult: Double = hrSleepBaselineMult
    /// When sparse, two adjacent sleep runs separated ONLY by a gravity gap up to this many
    /// minutes are merged if the intervening HR stays in the sleep band — so a real night is not
    /// shredded into sub-minSleepMin fragments by gravity dropouts. Sized at the daytime-nap
    /// floor (a real continuous night never has a true >90 min wake bridge mid-sleep).
    public static let sparseBridgeGapMin: Int = 90

    /// A single intervening ACTIVE run up to this long may be absorbed when bridging two sleep runs
    /// (#1657).
    ///
    /// This started as `maxGapMin` (20), on the reasoning that the file already had a threshold for
    /// "a discontinuity this long is decisive". An end-to-end test through `detectSleep` showed that was
    /// too tight to reach the case the issue is about: a FIFTEEN-minute interruption produced a
    /// TWENTY-ONE-minute active run, because `classifyStill` smears the still/moving boundary by roughly
    /// its rolling window and `buildRuns` closes runs at sample edges. The detected run is systematically
    /// longer than the interruption it represents, so a bound set from the interruption's true length
    /// rejects it.
    ///
    /// 30 is a judgement, and stated as one rather than dressed up as derived: a realistic trip out of
    /// bed of up to about a quarter of an hour, plus the ~6 minutes of smear that measurement showed,
    /// with a little headroom. It is deliberately well under `minSleepMin` — an interruption long enough
    /// to be a session in its own right is a genuine awakening and should split the night.
    ///
    /// The bound is the cheap half of the guard. The real one is the HR band across the whole span: a
    /// wearer who is actually up keeps HR elevated for the duration and fails it, while a brief stir does
    /// not. `mergeMin` (15) already absorbs shorter active runs upstream in `mergePeriods`.
    public static let sparseBridgeActiveMaxMin: Int = 30

    /// The same bound when HR across the whole span stays in the sleep band.
    ///
    /// `sparseBridgeActiveMaxMin`'s own doc calls the minute bound "the cheap half of the guard" and the
    /// HR band "the real one" — but the check order meant the cheap half vetoed first, so the real one
    /// never got to speak for a run over 30 minutes. A 42-minute active run with sleep-band HR was
    /// rejected identically to one with a wearer plainly up and about.
    ///
    /// That is the wrong way round on a strap whose "active" verdict comes from MOTION, which is the
    /// sparse and unreliable signal on the hardware this fires for (field log 260901-1022: 20,647 gravity
    /// samples across a 54-hour window, against 109,868 HR). HR is the better witness there, and it is
    /// already computed. 60 rather than something larger because it is `minSleepMin`: an interruption
    /// long enough to be a session in its own right is a genuine awakening whatever HR says.
    ///
    /// Applied as a MAXIMUM against `sparseBridgeActiveMaxMin`, never a replacement, so the in-band path
    /// can only ever be more permissive — an out-of-band span keeps the 30-minute bound exactly.
    public static let sparseBridgeActiveMaxInBandMin: Int = 60

    // MARK: - Stage 1–3 constants (sleep_features.py)

    public static let epochS: Double = 30.0
    public static let featureWindowS: Double = 5 * 60.0
    public static let ckCountDivisor: Double = 100.0
    public static let ckCountClip: Double = 300.0
    public static let moveDeltaThresholdG: Double = 0.01
    public static let hrDogSigma1S: Double = 120.0
    public static let hrDogSigma2S: Double = 600.0

    public static let stageHRLowPct: Double = 25.0
    public static let stageHRHighPct: Double = 70.0
    public static let stageHRVHighPct: Double = 70.0
    public static let stageHRVarHighPct: Double = 65.0
    public static let stageRRVHighPct: Double = 65.0
    public static let stageRRVLowPct: Double = 50.0
    public static let stageWakeMoveFrac: Double = 0.15
    public static let stageStillMoveFrac: Double = 0.10

    /// Fraction of sleep-period epochs that must carry a MISSING per-epoch RMSSD (sparse R-R) for the
    /// session's cardiac signal to count as PPG-DERIVED / sparse-cardiac. On a WHOOP 5/MG the PPG-derived
    /// HR feeds a noisier per-epoch HR-variance, which inflates `hrVar` on otherwise still, low-HR sleep
    /// epochs and was tripping the Stage-2 WAKE rule (which keys on the `hrvarHigh` percentile) — so a
    /// whole night over-reported WAKE. We already trust `!rmssd.isFinite` as a PPG/sparse tell for the
    /// pro-deep RMSSD handling (#127/#129); at this share across the night it also down-weights the
    /// HR-variance half of the WAKE rule. ~50% keeps a real worn 4.0 night (dense R-R) on the strict
    /// path and only relaxes nights whose cardiac signal is genuinely sparse/derived. (#705)
    public static let cardiacSparseEpochFrac: Double = 0.5

    public static let smoothEpochs: Int = 5
    public static let noREMAfterOnsetMin: Double = 15.0
    public static let deepFirstFraction: Double = 1.0 / 3.0

    /// Fragment-merge threshold (#274). A staged run shorter than this is "noise": the
    /// WHOOP 5/MG banks sparse motion, so the stager emits lots of sub-minute stage flecks
    /// and the hypnogram reads choppier than WHOOP's. mergeFragments (a DISPLAY/scoring
    /// smoothing applied AFTER staging, never to the underlying detection) absorbs runs
    /// below this into their neighbours. 3 min is conservative — long enough to clear the
    /// fleck noise, short enough to leave a genuine stage transition (a real deep or REM
    /// block runs many minutes) untouched.
    public static let fragmentMergeMin: Double = 3.0
    /// fragmentMergeMin expressed in 30 s epochs (6). A run with < this many epochs merges.
    public static let fragmentMergeEpochs: Int = Int((fragmentMergeMin * 60.0 / epochS).rounded())

    /// te Lindert 30 s Cole–Kripke weights [A₋₄..A₊₂]. SI = 0.001·Σ wᵢ·Aᵢ; sleep iff SI<1.
    public static let ckWeights: [Double] = [106.0, 54.0, 58.0, 76.0, 230.0, 74.0, 67.0]
    public static let ckScale: Double = 0.001
    public static let ckBack: Int = 4
    public static let ckFwd: Int = 2

    // MARK: - Gravity deltas

    /// Per-record movement proxy = L2 magnitude of the gravity change vs the
    /// previous record. First record → 0. (No dropout sentinel needed: GravitySample
    /// always carries finite x/y/z.)
    static func gravityDeltas(_ grav: [GravitySample]) -> [Double] {
        var deltas: [Double] = []
        deltas.reserveCapacity(grav.count)
        var prev: GravitySample? = nil
        for (i, r) in grav.enumerated() {
            if i == 0 {
                deltas.append(0.0)
            } else if let p = prev {
                let dx = p.x - r.x, dy = p.y - r.y, dz = p.z - r.z
                deltas.append((dx * dx + dy * dy + dz * dz).squareRoot())
            } else {
                deltas.append(0.0)
            }
            prev = r
        }
        return deltas
    }

    /// Median spacing between consecutive timestamps, restricted to (0, 300 s).
    static func medianIntervalS(_ times: [Int]) -> Double {
        guard times.count >= 2 else { return defaultIntervalS }
        var gaps: [Double] = []
        for i in 0..<(times.count - 1) {
            let g = Double(times[i + 1] - times[i])
            if g > 0 && g < 300 { gaps.append(g) }
        }
        guard !gaps.isEmpty else { return defaultIntervalS }
        gaps.sort()
        return max(gaps[gaps.count / 2], 1.0)
    }

    static func windowSize(_ times: [Int]) -> Int {
        let interval = medianIntervalS(times)
        return max(minWindowSamples, Int(Double(stillWindowMin * 60) / interval))
    }

    // MARK: - Sparse-gravity gate (#308)

    /// Largest spacing between consecutive timestamps (seconds), NO upper cap; 0 for <2 samples.
    /// Used to detect clumped/sparse gravity where the dropouts themselves are the signal: a few
    /// long dropouts in otherwise-dense (clumped) motion keep the MEDIAN gap small but still break
    /// runs, so the largest gap — not the median — is the right signal (#28).
    static func largestGapS(_ times: [Int]) -> Double {
        guard times.count >= 2 else { return 0 }
        var mx = 0.0
        for i in 0..<(times.count - 1) {
            let g = Double(times[i + 1] - times[i])
            if g > mx { mx = g }
        }
        return mx
    }

    /// True when gravity is too sparse for the gravity-only spine to be trusted across gaps:
    /// the gravity timespan covers < sparseGravitySpanFrac of the HR-sample timespan, OR the
    /// LARGEST gravity inter-sample gap exceeds maxGapMin. The largest-gap test (not just the
    /// median) catches CLUMPED motion — dense bursts split by a few long dropouts, the typical
    /// WHOOP 4.0 backfill (#28) — whose median gap stays small yet which still hides run-breaking
    /// gaps. Requires a real HR span to compare against — with no/degenerate HR the dense path is
    /// kept (false), so a 4.0 with absent HR is never reclassified as sparse.
    static func isGravitySparse(_ grav: [GravitySample], hr: [HRSample]) -> Bool {
        if grav.count < 2 || hr.count < 2 { return false }
        let hrSpan = Double(hr[hr.count - 1].ts - hr[0].ts)
        if hrSpan <= 0 { return false }
        let gravSpan = Double(grav[grav.count - 1].ts - grav[0].ts)
        if gravSpan < sparseGravitySpanFrac * hrSpan { return true }
        // #28: clumped 4.0 motion keeps a SMALL median gap yet still contains >maxGapMin dropouts
        // the gravity-only spine shreds the night on. The largest gap catches what a median would
        // miss (largest ≥ median, so this subsumes the old median check). Flagging sparse only
        // ENABLES buildRuns' HR-vouched bridge — a real wake (HR above the sleep band) still breaks.
        return largestGapS(grav.map { $0.ts }) > Double(maxGapMin * 60)
    }

    /// True when HR stays in the sleep band (≤ baseline × hrSleepBandMult) across (a, b], used to
    /// decide whether a pure gravity gap is a real wake or just a dropout. With no baseline or no
    /// HR in the interval, the answer is false (cannot vouch for the gap → treat as a real break).
    static func hrSleepBandAcross(_ a: Int, _ b: Int, hr: [HRSample], baseline: Double?) -> Bool {
        guard let baseline = baseline else { return false }
        let seg = hr.filter { $0.ts > a && $0.ts <= b }
        if seg.isEmpty { return false }
        // MEDIAN, not mean (#1657). `confirmSleepWithHR` below already documents why the mean is the
        // wrong statistic here — "a real sleep night carries brief arousal / wake HR spikes (observed to
        // ~190 bpm)" that drag it above the band — and uses the median for exactly that reason. This gate
        // answers the same question over a SHORTER window, where a single spike dominates the mean even
        // harder: a two-minute stir inside a fifteen-minute interval can put the mean out of band while
        // the wearer was asleep for thirteen of those minutes. The median rejects a SUSTAINED elevation
        // just as firmly, which is the discrimination this gate exists to make.
        let medianHR = HRVAnalyzer.median(seg.map { Double($0.bpm) })
        return medianHR <= baseline * hrSleepBandMult
    }

    /// Per-record sleep flags from a rolling fraction of "still" samples.
    static func classifyStill(_ grav: [GravitySample], _ deltas: [Double]) -> [Bool] {
        let n = grav.count
        if n < 2 { return [Bool](repeating: false, count: n) }
        let half = windowSize(grav.map { $0.ts }) / 2
        // stillPrefix[i] = # still samples among deltas[0..<i]: O(1) window counts → an O(n) scan, not
        // O(n×window). The old nested loop burned minutes of CPU per analysis tick (and on Android, on
        // the main thread, froze the app into ANRs after a few nights of 1 Hz history). Identical output.
        var stillPrefix = [Int](repeating: 0, count: n + 1)
        for i in 0..<n {
            stillPrefix[i + 1] = stillPrefix[i] + (deltas[i] < gravityStillThresholdG ? 1 : 0)
        }
        var flags: [Bool] = []
        flags.reserveCapacity(n)
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n, i + half + 1)
            let stillCount = stillPrefix[hi] - stillPrefix[lo]
            flags.append(Double(stillCount) / Double(hi - lo) >= stillFraction)
        }
        return flags
    }

    struct Period { var stage: String; var start: Int; var end: Int }

    /// Collapse per-record flags into contiguous runs, breaking on class change
    /// or a gap > maxGapMin minutes.
    ///
    /// When `sparse` (gravity is too clumped to bridge gaps — #308), a PURE gravity data-gap
    /// (no contrary motion) does NOT close a SLEEP run while HR stays in the sleep band across
    /// the gap: the strap simply banked no motion there, not a wake. A class change always still
    /// closes the run, and the dense path (`sparse == false`) is byte-identical to the original.
    static func buildRuns(_ grav: [GravitySample], _ flags: [Bool],
                          sparse: Bool = false, hr: [HRSample] = [], baseline: Double? = nil) -> [Period] {
        let n = grav.count
        if n == 0 { return [] }
        let times = grav.map { $0.ts }
        let maxGapS = maxGapMin * 60
        var periods: [Period] = []
        var runStart = 0
        for i in 1...n {
            let atEnd = (i == n)
            let close: Bool
            if atEnd {
                close = true
            } else {
                let classChanged = flags[i] != flags[runStart]
                var gapExceeded = (times[i] - times[i - 1]) > maxGapS
                // Sparse override: a pure gravity gap (no class change) does not break a sleep
                // run when HR stays in the sleep band across it — the gap is a dropout, not a wake.
                if sparse && gapExceeded && !classChanged && flags[runStart]
                    && hrSleepBandAcross(times[i - 1], times[i], hr: hr, baseline: baseline) {
                    gapExceeded = false
                }
                close = classChanged || gapExceeded
            }
            if close {
                periods.append(Period(stage: flags[runStart] ? "sleep" : "active",
                                      start: times[runStart], end: times[i - 1]))
                runStart = i
            }
        }
        return periods
    }

    /// Percentile of the window's bpm that anchors the HR-only sleep band.
    ///
    /// NOT `hrBaseline`. That is the window MEDIAN, and it is the right anchor where it is used — as a
    /// CONFIRMATION gate on a run gravity stillness already found, where being permissive is deliberate.
    /// As a PRIMARY threshold it is disqualified by arithmetic rather than by tuning: a median splits the
    /// samples in half by definition, so a band of `median * 1.05` admits strictly more than half of any
    /// window whatever the data. Measured on a realistic 24 h (16 h awake 74-96, 8 h night 59-70) it
    /// called 14.4 hours sleep against a truth of 8.
    ///
    /// A tenth percentile sits in the night's trough instead, which is what a sleep band should be
    /// anchored to, and cannot admit half the window however the day is shaped.
    public static let hrOnlyAnchorPercentile: Double = 0.10

    /// Multiplier above `hrOnlyAnchorPercentile` that still counts as asleep.
    ///
    /// Numerically equal to `hrSleepBandMult` today, and deliberately a SEPARATE constant: that one is a
    /// confirmation gate's tolerance and this one is a detector's, and a future change to either has no
    /// business silently moving the other.
    ///
    /// Chosen conservatively from a sweep over anchor x multiplier against windows with known truth,
    /// because the two failure directions are not symmetric. Over-detection puts a wrong Rest number on
    /// screen; under-detection leaves "No data", which is the state this feature is trying to improve on
    /// and therefore a safe place to fail. p10 x 1.05 measured 8.1 h against a truth of 8 on a
    /// field-shaped 24 h window, and under-reads a long multi-night window rather than over-reading it
    /// (8.7 h of 16 h across two nights in 54 h) — pinned in `SleepStagerHrOnlyAnchorTests`.
    public static let hrOnlyBandMult: Double = 1.05

    /// The `hrOnlyAnchorPercentile` of `hr` by bpm, or nil when empty. Nearest-rank (no interpolation), so
    /// the value is always one the wearer actually recorded and the two platforms cannot disagree on a
    /// rounding rule.
    static func hrOnlyBaseline(_ hr: [HRSample]) -> Double? {
        hrPercentile(hr, hrOnlyAnchorPercentile)
    }

    /// The `p` percentile of `hr` by bpm, nearest-rank. Shared with `hrOnlyBaseline` so the spread the
    /// trace reports is measured by the SAME rule as the anchor it is meant to be judged against.
    static func hrPercentile(_ hr: [HRSample], _ p: Double) -> Double? {
        percentileOfSorted(hr.map { Double($0.bpm) }.sorted(), p)
    }

    /// The `p` percentile of an ALREADY-SORTED bpm list, nearest-rank. Split out because the caller
    /// needs three percentiles from the same window, and the obvious spelling sorts once per
    /// percentile — ~160k samples sorted three times per scored day across a 21-day rescore.
    static func percentileOfSorted(_ sorted: [Double], _ p: Double) -> Double? {
        if sorted.isEmpty { return nil }
        let idx = min(max(Int(Double(sorted.count - 1) * p), 0), sorted.count - 1)
        return sorted[idx]
    }

    /// How many distinct `hrOnlyEpochS` buckets `sortedByTs` spans.
    ///
    /// A single pass rather than a Set, because `hrS` is already sorted by timestamp so the bucket key
    /// is non-decreasing. The obvious spelling (`Set(hrS.map { … })`) builds a full intermediate array
    /// AND a set over every sample to end up with a few thousand distinct keys — per scored day, across
    /// the 21-day rescore. A diagnostic must not cost what it is measuring.
    static func distinctEpochs(_ sortedByTs: [HRSample]) -> Int {
        var count = 0
        var last = Int.min
        for s in sortedByTs {
            let key = s.ts / hrOnlyEpochS
            if key != last { count += 1; last = key }
        }
        return count
    }

    /// Epoch for the HR-only spine, in seconds.
    public static let hrOnlyEpochS: Int = 60

    /// Sleep/active runs built from HEART RATE ALONE, for a strap that streams HR but banks no motion.
    ///
    /// Stage 0 is normally a gravity-stillness spine (Cole-Kripke) that HR only CONFIRMS, via
    /// `hrSleepBandAcross` and `confirmSleepWithHR`. A WHOOP 5/MG that cannot bond never banks motion at
    /// all — `SET_CLOCK` rides a handshake it never completes — so `grav` is empty, there is no spine, and
    /// no quantity of HR can stage the night (#1801). This builds the spine from the one signal such a
    /// strap does provide.
    ///
    /// Deliberately the SAME rule the confirm path already trusts: per-epoch MEDIAN bpm against
    /// `baseline * hrSleepBandMult`, median for the reason `hrSleepBandAcross` spells out. The run
    /// construction follows `buildRuns` — close on a class change or a gap over `maxGapMin` — so the two
    /// spines segment alike once flags exist, and only the flag SOURCE differs.
    ///
    /// With ONE branch deliberately absent, and it is not an oversight. `buildRuns` can forgive a gap when
    /// `hrSleepBandAcross` vouches that HR stayed in band across it, which rescues a night whose GRAVITY
    /// dropped out. Here the gap IS in the heart rate, so there is nothing left to vouch with and no
    /// analogue to port. A long HR dropout therefore breaks an HR-only run where it would not break a
    /// motion-backed one, and a night fragmented that way is dropped by the caller's minimum-duration
    /// gate rather than bridged.
    ///
    /// WEAKER THAN THE MOTION SPINE, by construction rather than by tuning. The file already notes that a
    /// long still daytime stretch is gravity-indistinguishable from a nap and that HR is what saves it;
    /// with motion gone the inverse is exposed, and a quiet evening at rest can sit in the sleep band. A
    /// caller must treat these runs as lower-confidence than a motion-backed night and must not let one
    /// reach a baseline it cannot be unwound from.
    ///
    /// Bucket order does not depend on sort stability: samples are grouped by epoch and reduced with a
    /// median, so their order within an epoch cannot change the result.
    static func hrOnlySleepRuns(_ hr: [HRSample], baseline: Double?,
                                epochS: Int = hrOnlyEpochS,
                                maxGapMinutes: Int = maxGapMin) -> [Period] {
        guard let baseline = baseline, baseline > 0 else { return [] }
        if hr.isEmpty || epochS <= 0 { return [] }
        var byEpoch: [Int: [Double]] = [:]
        var lastTs: [Int: Int] = [:]
        for s in hr {
            let k = s.ts / epochS
            byEpoch[k, default: []].append(Double(s.bpm))
            lastTs[k] = max(lastTs[k] ?? Int.min, s.ts)
        }
        let keys = byEpoch.keys.sorted()
        // Two axes, deliberately. A gap and a run's START use the epoch's own start, so a gap is measured
        // between epochs rather than between whichever samples sat at their edges. A run's END is the last
        // SAMPLE observed in its final epoch, which is what `buildRuns` means by `end` — reading the epoch
        // start there would report every run one whole epoch shorter than the data it covers, and that
        // understatement would then be weighed against the caller's minimum-duration gate.
        let times = keys.map { $0 * epochS }
        let ends = keys.map { lastTs[$0]! }
        let flags = keys.map { HRVAnalyzer.median(byEpoch[$0]!) <= baseline * hrOnlyBandMult }
        let maxGapS = maxGapMinutes * 60
        var periods: [Period] = []
        var runStart = 0
        for i in 1...keys.count {
            let atEnd = (i == keys.count)
            let close: Bool
            if atEnd {
                close = true
            } else {
                close = flags[i] != flags[runStart] || (times[i] - times[i - 1]) > maxGapS
            }
            if close {
                periods.append(Period(stage: flags[runStart] ? "sleep" : "active",
                                      start: times[runStart], end: ends[i - 1]))
                runStart = i
            }
        }
        return periods
    }

    /// Whole sleep SESSIONS from heart rate alone, for a strap that banks no motion (#1801).
    ///
    /// `hrOnlySleepRuns` supplies the spine this normally gets from gravity stillness; `SleepStagerV2`
    /// then stages each surviving run from HR and R-R with an EMPTY gravity array. That is not a
    /// degenerate call: V2's epoch features read HR and R-R directly and only its motion-quiescence terms
    /// go quiet, so it returns a real hypnogram rather than one flat stage. A stageless session would be
    /// dropped by `sleepSessionFromProvided` anyway, so a night that fails to stage is correctly omitted
    /// here rather than passed on hollow.
    ///
    /// The anchor is `hrOnlyBaseline` — the `hrOnlyAnchorPercentile` of the window — and NOT the
    /// `hrBaseline` median the motion path derives. Reusing that median looked like parity and was a bug:
    /// as a confirmation gate on an already-detected run it is deliberately permissive, but as a primary
    /// threshold it admits over half of any window by definition. See `hrOnlyAnchorPercentile`.
    ///
    /// `restingHR` and `avgHRV` are MEASURED here and reported (#1884). They were withheld under #1801,
    /// which treated them as inferred; they are not. Only the session BOUNDS are inferred from heart rate
    /// — that is what `hrOnly` marks — while each RMSSD is computed over its own 5-minute window, so fuzzy
    /// bounds change WHICH windows are included, not whether any one of them is valid. Withholding them
    /// discarded a measured 22-25 ms and left Charge with no input at all, which is a worse error than a
    /// slightly fuzzy one.
    ///
    /// The flag travels on instead, so a consumer that wants to weigh an HR-only night down still can.
    /// `public` because the app target calls it: `Strand/Data/IntelligenceEngine.swift` is the day scan,
    /// and it lives outside this package. The spine and the anchor below it stay `internal` — the tests
    /// reach them with `@testable`, and nothing outside should be building its own spine.
    public static func hrOnlySessions(day: String, hr: [HRSample], rr: [RRInterval], resp: [RespSample],
                                      minMinutes: Int = minSleepMin,
                                      traceSink: ((String) -> Void)? = nil) -> [SleepSession] {
        let hrS = hr.sorted { $0.ts < $1.ts }
        // ONE sort of the bpm axis, reused for the anchor and for the spread the trace reports.
        let sortedBpm = hrS.map { Double($0.bpm) }.sorted()
        guard let baseline = percentileOfSorted(sortedBpm, hrOnlyAnchorPercentile) else {
            traceSink?(GateTrace.hrOnlyLine(day: day, anchorBpm: nil, bandBpm: nil, hrP50: nil, hrP90: nil,
                                            epochs: 0, runs: 0,
                                            mergedRuns: 0, sleepRuns: 0, longestSleepMin: 0,
                                            staged: 0, kept: 0, minSleepMin: minMinutes))
            return []
        }
        let rrS = rr.sorted { $0.ts < $1.ts }
        var out: [SleepSession] = []
        // mergePeriods for the same reason the motion path calls it: a run boundary is a threshold
        // crossing, and a sleeping heart rate oscillates across the band all night. Without this the
        // spine returns the night's minutes correctly but shredded into sub-mergeMin fragments, every one
        // of which then fails the minimum-duration gate below — 8 h of detected sleep yielding zero
        // sessions. Absorbing the short runs first is what turns a spine into a night.
        let rawRuns = hrOnlySleepRuns(hrS, baseline: baseline)
        let merged = mergePeriods(rawRuns)
        var staged = 0
        var longestSleepS = 0
        for p in merged {
            if p.stage != "sleep" { continue }
            longestSleepS = max(longestSleepS, p.end - p.start)
            if (p.end - p.start) < minMinutes * 60 { continue }
            let stages = SleepStagerV2.stageSession(start: p.start, end: p.end, grav: [],
                                                    hr: hrS, rr: rrS, resp: resp)
            staged += 1
            if stages.isEmpty { continue }
            // #1884: MEASURED, not nilled. The bounds here are inferred from heart rate, which is why
            // `hrOnly` marks the session — but each RMSSD is computed over its own 5-minute window tagged
            // by the stage at its centre, so fuzzy bounds change WHICH windows are included, not whether
            // any one of them is valid. A field log showed this path computing a stable 22-25ms deepOnly
            // and discarding it, leaving Charge unscoreable. `hrOnly` still travels with the session, so
            // it is a quality marker now rather than a delete. Kotlin twin: `SleepStager.hrOnlySessions`.
            out.append(SleepSession(start: p.start, end: p.end,
                                    efficiency: efficiency(start: p.start, end: p.end, stages: stages),
                                    stages: stages,
                                    restingHR: sessionRestingHR(start: p.start, end: p.end, hr: hrS),
                                    avgHRV: sessionAvgHRV(start: p.start, end: p.end, rr: rrS),
                                    hrOnly: true))
        }
        traceSink?(GateTrace.hrOnlyLine(
            day: day,
            anchorBpm: baseline,
            bandBpm: baseline * hrOnlyBandMult,
            // The wearer's own spread. An anchor alone cannot be judged: p10 of 60 means one thing when
            // the median is 63 and quite another when it is 74, and only the second leaves a night the
            // band can separate.
            hrP50: percentileOfSorted(sortedBpm, 0.50),
            hrP90: percentileOfSorted(sortedBpm, 0.90),
            // The real epoch count, not the sample count: the spine buckets by `hrOnlyEpochS` before it
            // decides anything, so this is the axis every other number here is measured on.
            epochs: distinctEpochs(hrS),
            runs: rawRuns.count,
            mergedRuns: merged.count,
            sleepRuns: merged.filter { $0.stage == "sleep" }.count,
            longestSleepMin: longestSleepS / 60,
            staged: staged,
            kept: out.count,
            minSleepMin: minMinutes))
        return out
    }

    /// Absorb runs shorter than mergeMin minutes into their neighbours.
    static func mergePeriods(_ periods: [Period], mergeMinutes: Int = mergeMin) -> [Period] {
        if periods.isEmpty { return [] }
        var pending = periods
        let thresholdS = mergeMinutes * 60
        var merged: [Period] = []
        var i = 0
        while i < pending.count {
            let current = pending[i]
            let tooShort = (current.end - current.start) < thresholdS
            if !tooShort { merged.append(current); i += 1; continue }

            let hasPrev = i > 0 && !merged.isEmpty
            let hasNext = i + 1 < pending.count
            let bridgesSame = hasPrev && hasNext && pending[i - 1].stage == pending[i + 1].stage

            if bridgesSame {
                let prev = merged.removeLast()
                merged.append(Period(stage: prev.stage, start: prev.start, end: pending[i + 1].end))
                i += 2
            } else if hasNext {
                pending[i + 1] = Period(stage: pending[i + 1].stage,
                                        start: current.start, end: pending[i + 1].end)
                i += 1
            } else if hasPrev {
                let prev = merged.removeLast()
                merged.append(Period(stage: prev.stage, start: prev.start, end: current.end))
                i += 1
            } else {
                i += 1
            }
        }
        return merged
    }

    /// Why `bridgeSparseSleep` did or did not merge one adjacent pair of runs (#737).
    ///
    /// The existing trace reports only `runsBefore`/`runsAfter`, so a bridge that changed NOTHING gives
    /// no reason — and there are three very different causes (gap over the tolerance, HR outside the
    /// sleep band, or the pair simply not being two adjacent sleep runs). A reporter's night showed
    /// `runsBefore=13 runsAfter=13` with 8 runs then discarded by `minSleepMin`, and the log could not
    /// say which cause applied, so no fix could be chosen responsibly. This names it per pair.
    struct SparseBridgeAttempt: Equatable, Sendable {
        /// Gap between the two runs, in whole minutes (negative when they overlap).
        let gapMin: Int
        /// Minutes of intervening ACTIVE run, or 0 when the pair was only separated by a gap (#1657).
        let activeMin: Int
        /// The bound this pair was actually judged against — 30, or 60 when HR stayed in the sleep band.
        let activeCapMin: Int
        /// Whether the intervening HR stayed in the sleep band (the bridge's second condition).
        let hrInSleepBand: Bool
        /// Whether this pair was merged.
        let bridged: Bool
        /// Stable token for the log: bridged / gapTooLong / hrOutOfBand / overlap / activeTooLong.
        let reason: String
    }

    /// True when this night's sleep runs will ALL be dropped by `minSleepMin` yet add up to a plausible
    /// night. Pure, so the rule can be tested without building gravity.
    ///
    /// The predicate is deliberately "today's answer is zero". Every run being under the floor means the
    /// survival pass keeps none of them, so a bridge enabled on this basis can only turn nothing into
    /// something; if any single run already clears the floor this is false, the sparse rule decides as
    /// before, and a night that currently scores cannot change.
    ///
    /// Two runs at minimum, because one fragment is not a fragmented night. The SUM must clear the floor
    /// so a handful of brief stirs does not become a night. Neither condition weakens what the bridge
    /// itself checks. Kotlin twin: `isFragmentedToNothing`.
    static func isFragmentedToNothing(_ sleepRunSpansS: [Int], minSleepS: Int) -> Bool {
        sleepRunSpansS.count >= 2
            && !sleepRunSpansS.contains { $0 >= minSleepS }
            && sleepRunSpansS.reduce(0, +) >= minSleepS
    }

    /// Per-pair explanation of `bridgeSparseSleep`, mirroring its rule EXACTLY (same adjacency walk,
    /// same `gap >= 0 && gap <= sparseBridgeGapMin*60`, same HR-band check) so the reasons describe what
    /// actually happened rather than an approximation. Only pairs the bridge itself CONSIDERS (two
    /// adjacent sleep runs) produce an attempt; a pair separated by an active run is never considered,
    /// which is itself the answer when no attempts are reported. Pure — no I/O, no side effects.
    /// The bridge, plus what it considered. See `bridgeSparseSleep` for the merge rule.
    ///
    /// #1657: an intervening ACTIVE run no longer blocks the merge permanently. The original loop could
    /// only join runs already adjacent in its own output, so any active run between two sleep runs was
    /// appended first and made the next pair unreachable — and a field trace found the bridge merging
    /// NOTHING on 14 of 14 sparse nights for exactly that reason. Since a bathroom trip is definitionally
    /// an active run, the rescue built for fragmentation was unavailable in the case that needs it most.
    ///
    /// A single active run up to `sparseBridgeActiveMaxMin` is now absorbed, with the whole span still
    /// subject to `sparseBridgeGapMin` and to the HR band. Two or more consecutive active runs are not:
    /// that is a night with real structure in it, not one interruption.
    ///
    /// This USED to be a shadow copy of the loop kept only for tracing, which had to be edited in step
    /// with the real one — a trace that quietly disagrees with the behaviour it describes is worse than
    /// no trace. Merge and trace are one pass now. Kotlin twin: `bridgeSparseSleepTraced`.
    static func bridgeSparseSleepTraced(_ periods: [Period], sparse: Bool, hr: [HRSample],
                                        baseline: Double?) -> ([Period], [SparseBridgeAttempt]) {
        if !sparse || periods.isEmpty { return (periods, []) }
        let bridgeGapS = sparseBridgeGapMin * 60
        let activeMaxS = sparseBridgeActiveMaxMin * 60
        let activeMaxInBandS = sparseBridgeActiveMaxInBandMin * 60
        var out: [Period] = []
        var attempts: [SparseBridgeAttempt] = []

        /// Judge one candidate pair, record it, and merge when it passes.
        ///
        /// The order of the checks fixes which reason a failing pair reports, and it is deliberate:
        /// overlap and gap are properties of the pair, activeTooLong is a property of what sits between
        /// them, and hrOutOfBand is last because it is the only one that needed the HR series to decide.
        /// `activeMaxInBandS` is a PARAMETER rather than a capture, mirroring the Kotlin default of 0.
        /// Captured, case 1 (adjacent sleep runs, no intervening active run) would report activeCapMin=60
        /// on Apple and 0 on Android for the identical decision — same behaviour, divergent trace, which
        /// is exactly the byte-for-byte comparison these lines exist to allow.
        func consider(_ left: Period, _ right: Period, activeS: Int,
                      dropTrailing: Bool, activeMaxS: Int, activeMaxInBandS: Int = 0) -> Bool {
            let gap = right.start - left.end
            let inBand = hrSleepBandAcross(left.end, right.start, hr: hr, baseline: baseline)
            // The HR band is the real guard, so let it widen the minute bound rather than be vetoed by
            // it. max, not a swap: in-band can only ever be MORE permissive, and case 1 (activeMaxS = 0,
            // no intervening run) is untouched because activeS is 0 there too.
            let activeCapS = inBand ? max(activeMaxS, activeMaxInBandS) : activeMaxS
            let reason: String
            if gap < 0 { reason = "overlap" }
            else if gap > bridgeGapS { reason = "gapTooLong" }
            else if activeS > activeCapS { reason = "activeTooLong" }
            else if !inBand { reason = "hrOutOfBand" }
            else { reason = "bridged" }
            let bridged = reason == "bridged"
            attempts.append(SparseBridgeAttempt(gapMin: gap / 60, activeMin: activeS / 60,
                                                activeCapMin: activeCapS / 60,
                                                hrInSleepBand: inBand, bridged: bridged, reason: reason))
            guard bridged else { return false }
            if dropTrailing { out.removeLast() }
            out[out.count - 1] = Period(stage: "sleep", start: left.start, end: right.end)
            return true
        }

        for p in periods {
            if p.stage == "sleep" {
                // Case 1: the previous run is sleep — the original adjacent-pair merge.
                if let last = out.last, last.stage == "sleep" {
                    if consider(last, p, activeS: 0, dropTrailing: false, activeMaxS: 0) { continue }
                }
                // Case 2: exactly one active run sits between two sleep runs. Absorbed when short
                // enough, which is the #1657 case the original loop could never reach.
                if out.count >= 2, let last = out.last, last.stage == "active",
                   out[out.count - 2].stage == "sleep" {
                    let prev = out[out.count - 2]
                    if consider(prev, p, activeS: last.end - last.start,
                                dropTrailing: true, activeMaxS: activeMaxS,
                                activeMaxInBandS: activeMaxInBandS) { continue }
                }
            }
            out.append(p)
        }
        return (out, attempts)
    }

    /// Sparse-gravity bridge (#308): merge two SLEEP runs when the intervening HR stays in the sleep
    /// band — so a real night fragmented by gravity dropouts is re-stitched into one continuous in-bed
    /// span BEFORE the minSleepMin gate drops the pieces. A no-op when `sparse == false`, so the dense
    /// 4.0 path is unchanged.
    ///
    /// What sits between the two runs may be a bare gap (up to `sparseBridgeGapMin`) or ONE active run
    /// (additionally up to `sparseBridgeActiveMaxMin`). Over-threshold gaps, longer active runs and two
    /// consecutive active runs are all left untouched.
    ///
    /// The previous wording here — "Active runs … are left untouched; the span between two bridged sleep
    /// runs (an "active"/gap run, if present) is absorbed" — read as though an intervening active run was
    /// already handled. It was not: only a bare gap was, and that sentence is a large part of why #1657
    /// went unnoticed. Kept in the history rather than quietly deleted, because the next person to widen
    /// this function will read this comment first.
    static func bridgeSparseSleep(_ periods: [Period], sparse: Bool,
                                  hr: [HRSample], baseline: Double?) -> [Period] {
        bridgeSparseSleepTraced(periods, sparse: sparse, hr: hr, baseline: baseline).0
    }

    // MARK: - HR refinement

    static func rowsBetween<T>(_ rows: [T], start: Int, end: Int, ts: (T) -> Int) -> [T] {
        rows.filter { ts($0) >= start && ts($0) <= end }
    }

    /// Day HR baseline = median bpm over all HR samples; nil if none.
    static func hrBaseline(_ hr: [HRSample]) -> Double? {
        let vals = hr.map { Double($0.bpm) }
        guard !vals.isEmpty else { return nil }
        return HRVAnalyzer.median(vals)
    }

    /// HR-confirmation with MOTION CORROBORATION (motion-corroborated wake). A run is confirmed as sleep when
    /// its MEDIAN HR sits within the sleep band relative to `baseline`. The band is normally `hrSleepBaselineMult`
    /// (×1.05); on a run that is DEEPLY MOTION-QUIESCENT (`runIsDeeplyQuiescent` — the wrist barely moved and its
    /// posture did not change across the whole span) the band widens to `quiescentHRSleepMult`, because a raised
    /// but FLAT overnight HR with a motionless wrist is a supplement / fever / hot-room / alcohol artefact, not
    /// wakefulness — elevated-HR-alone must not reject a still run. The wider band STILL keeps a floor: a
    /// genuinely awake, high-HR run (median above `quiescentHRSleepMult × baseline`) is rejected even when still,
    /// so all-night in-bed wakefulness is not scored asleep. `sleepHRBaseline` (directive b) overrides `baseline`
    /// with the wearer's personalised overnight band (`adaptiveOvernightHRBaseline`) when the caller supplies
    /// one, so a supplement / fitness era self-calibrates instead of drifting against a fixed day-median.
    /// `grav` defaults to empty (motion unprovable → strict band, byte-identical to the pre-corroboration gate);
    /// the detection call site passes the night's gravity. Mirrors Kotlin `confirmSleepWithHR`.
    static func confirmSleepWithHR(_ p: Period, hr: [HRSample], baseline: Double?,
                                   grav: [GravitySample] = [], sleepHRBaseline: Double? = nil) -> Bool {
        let effBaseline = sleepHRBaseline ?? baseline
        guard let effBaseline = effBaseline else { return true }
        let seg = rowsBetween(hr, start: p.start, end: p.end) { $0.ts }
        if seg.count < hrRefineMinSamples { return true }
        // Confirm on the run's MEDIAN, not its mean. A real sleep night carries brief arousal / wake HR
        // spikes (observed to ~190 bpm) that pull the MEAN above baseline × mult and reject the run — and for
        // a typical single main-sleep run per night that means zero sessions ("no sleep recorded") — while
        // the spike-robust median stays at the true sleep level. Baseline is itself a median, so both sides
        // use the same robust statistic; a genuinely elevated (awake) run still has a high median and fails.
        // Median ≤ mean for the right-skewed HR of a real night, so this only ever RELAXES the gate — every
        // run the mean already accepted still passes, and runs the mean wrongly dropped are recovered.
        let medHR = HRVAnalyzer.median(seg.map { Double($0.bpm) })
        let mult = runIsDeeplyQuiescent(p, grav: grav) ? quiescentHRSleepMult : hrSleepBaselineMult
        return medHR <= effBaseline * mult
    }

    // MARK: - Motion-corroborated wake (elevated-but-flat-HR nights)

    // Both stagers call "wake" primarily off HR / HR-variability, and the HR-led session confirmation
    // (`confirmSleepWithHR`) rejects a still run whose median HR sits above the sleep band. On a night with
    // pharmacologically- or metabolically-elevated resting HR that keeps HR up WITHOUT the wearer getting up
    // (a supplement protocol, a fever, a hot room, alcohol), that HR-led logic misreads hot-but-motionless
    // sleep as wake. The corroboration rule is: elevated-HR ALONE is insufficient — a run/epoch at the night's
    // quiescent MOTION floor with UNCHANGED posture cannot be called wake on cardiac evidence alone. The
    // per-epoch half lives in the stagers …19871 tokens truncated…tly as it does across a
        // dropout. That is the intent - both genuinely splice the tachogram, which is the same reason
        // #204/#195 made RMSSD skip differences across a removed beat - but it does mean a night with
        // heavy ectopic rejection now loses windows it used to keep.
        var beatTimes = [Double](repeating: 0, count: filtered.count)
        var spliceAtS: [Double] = []
        var acc = 0.0
        for i in filtered.indices {
            if i > 0 {
                let wallStepS = Double(inBedRows[i].ts - inBedRows[i - 1].ts)
                if wallStepS - filtered[i] / 1000.0 > rsaGapToleranceS { spliceAtS.append(acc) }
            }
            acc += filtered[i] / 1000.0
            beatTimes[i] = acc
        }
        let totalSpanS = beatTimes[beatTimes.count - 1]
        if totalSpanS < rsaWindowS / 2.0 { return nan }  // < ~2.5 min of beats

        // 3. Resample onto a uniform grid by linear interpolation.
        let dt = 1.0 / rsaResampleHz
        let nGrid = Int(totalSpanS / dt) + 1
        if nGrid < 8 { return nan }
        var grid = [Double](repeating: 0, count: nGrid)
        var seg = 0
        for g in 0..<nGrid {
            let t = Double(g) * dt
            // advance segment so beatTimes[seg] <= t <= beatTimes[seg+1]
            while seg < beatTimes.count - 2 && beatTimes[seg + 1] < t { seg += 1 }
            let t0 = beatTimes[seg]
            let t1 = beatTimes[seg + 1]
            let v0 = filtered[seg]
            let v1 = filtered[seg + 1]
            grid[g] = t1 <= t0 ? v0 : v0 + min(max((t - t0) / (t1 - t0), 0), 1) * (v1 - v0)
        }

        // 4. Detrend: subtract a centered moving mean (removes slow LF/baseline drift).
        let halfW = max(1, Int((rsaDetrendWindowS * rsaResampleHz / 2.0).rounded()))
        var detrended = [Double](repeating: 0, count: nGrid)
        for i in 0..<nGrid {
            let lo = max(0, i - halfW)
            let hi = min(nGrid - 1, i + halfW)
            var sum = 0.0
            for j in lo...hi { sum += grid[j] }
            detrended[i] = grid[i] - sum / Double(hi - lo + 1)
        }
        if standardDeviation(detrended) <= 1e-9 { return nan }  // flat → no RSA

        // 5. Per ~5-min window peak-pick → 60/median(breath interval); median across.
        let spliceGrid = spliceAtS.map { Int($0 / dt) }
        let minDistSamples = max(2, Int((rsaMinPeakDistanceS * rsaResampleHz).rounded()))
        let windowSamples = max(minDistSamples * 3, Int((rsaWindowS * rsaResampleHz).rounded()))
        var perWindowRates: [Double] = []
        var w = 0
        while w < nGrid {
            let wEnd = min(nGrid, w + windowSamples)
            // #977: a window straddling a splice is measuring a discontinuity, not a breath. Dropping it
            // costs one window; keeping it puts a fabricated interval into the median. All windows spliced
            // leaves perWindowRates empty and the function returns NaN, which is the honest answer.
            let spliced = spliceGrid.contains { $0 >= w && $0 < wEnd }
            if !spliced && wEnd - w >= minDistSamples * 3 {
                let winSeg = Array(detrended[w..<wEnd])
                // findPeaks with height = 0.0 selects the positive RSA peaks (one per
                // breath) on the zero-mean detrended tachogram.
                let peaks = findPeaks(winSeg, distance: minDistSamples, height: 0.0)
                if peaks.count >= 3 {
                    var intervals: [Double] = []
                    for i in 1..<peaks.count {
                        let ivS = Double(peaks[i] - peaks[i - 1]) * dt
                        if ivS >= rsaMinBreathIntervalS && ivS <= rsaMaxBreathIntervalS {
                            intervals.append(ivS)
                        }
                    }
                    if intervals.count >= 2 {
                        let med = HRVAnalyzer.median(intervals)
                        if med > 0.0 { perWindowRates.append(60.0 / med) }
                    }
                }
            }
            w += windowSamples
        }
        if perWindowRates.isEmpty { return nan }
        // Reject estimates outside the canonical consumer band (NaN = "no usable estimate") so the
        // persisted value never silently disagrees with the illness/readiness plausibility gate.
        let median = HRVAnalyzer.median(perWindowRates)
        return respPlausibleRangeBpm.contains(median) ? median : nan
    }

    // MARK: - Per-epoch features

    struct EpochFeatures {
        let index: Int
        let midTs: Double
        let count: Double      // rescaled Cole–Kripke activity count
        let moveFrac: Double
        let ckSleep: Bool
        let hr: Double         // mean HR over the feature window
        let hrVar: Double      // Walch DoG-HR windowed std
        let rmssd: Double      // ms
        let sdnn: Double       // ms
        let respRate: Double   // breaths/min
        let rrv: Double        // respiratory-rate variability (s)
        let clock: Double      // normalized time since onset, 0..1
    }

    static func extractFeatures(grid: EpochGrid, ckFlags: [Bool], dogHR: [Double],
                                onsetIdx: Int, finalWakeIdx: Int) -> [EpochFeatures] {
        let n = grid.nEpochs
        let rescaled = rescaleCounts(grid.counts)
        let halfW = Int((featureWindowS / epochS / 2).rounded())
        let span = Double(max(1, finalWakeIdx - onsetIdx))

        var feats: [EpochFeatures] = []
        feats.reserveCapacity(n)
        for i in 0..<n {
            let lo = max(0, i - halfW)
            let hi = min(n, i + halfW + 1)

            let winHR = (lo..<hi).map { grid.hr[$0] }.filter { !$0.isNaN }
            let hrMean = winHR.isEmpty ? Double.nan : winHR.reduce(0, +) / Double(winHR.count)

            let winDog = (lo..<hi).map { dogHR.isEmpty ? 0.0 : dogHR[$0] }
            let hrVar = winDog.count >= 2 ? standardDeviation(winDog) : Double.nan

            // RMSSD/SDNN over the pooled RR window (range-filtered, like the
            // Python per-epoch hrv_from_rr which uses RAW range-filtered RR).
            var winRR: [Double] = []
            for j in lo..<hi { winRR.append(contentsOf: grid.rr[j]) }
            let filteredRR = HRVAnalyzer.rangeFilter(winRR)
            let rmssd = filteredRR.count >= 5 ? (HRVAnalyzer.rmssdRaw(filteredRR) ?? Double.nan) : Double.nan
            let sdnn = filteredRR.count >= 5 ? (HRVAnalyzer.sdnnRaw(filteredRR) ?? Double.nan) : Double.nan

            var winResp: [Double] = []
            for j in lo..<hi { winResp.append(contentsOf: grid.resp[j]) }
            let (respRate, rrv) = respRateAndRRV(winResp)

            let clock = min(1.0, max(0.0, Double(i - onsetIdx) / span))

            feats.append(EpochFeatures(
                index: i, midTs: grid.epochMid(i), count: rescaled[i],
                moveFrac: grid.moveFrac[i],
                ckSleep: i < ckFlags.count ? ckFlags[i] : true,
                hr: hrMean, hrVar: hrVar, rmssd: rmssd, sdnn: sdnn,
                respRate: respRate, rrv: rrv, clock: clock))
        }
        return feats
    }

    // MARK: - Percentile helper

    /// numpy-style linear-interpolated percentile over finite values; nil if none.
    static func percentile(_ values: [Double], _ pct: Double) -> Double? {
        let vals = values.filter { $0.isFinite }.sorted()
        if vals.isEmpty { return nil }
        return StrainScorer.percentile(vals, pct)
    }

    // MARK: - Classifier seam (Stage 2)

    static func classifyEpochs(_ features: [EpochFeatures]) -> [String] {
        let n = features.count
        if n == 0 { return [] }

        // Session-relative reference distributions over SLEEP-PERIOD epochs.
        let sleepFeats = features.contains { $0.ckSleep } ? features.filter { $0.ckSleep } : features
        let hrLo = percentile(sleepFeats.map { $0.hr }, stageHRLowPct)
        let hrHi = percentile(sleepFeats.map { $0.hr }, stageHRHighPct)
        let rmssdHi = percentile(sleepFeats.map { $0.rmssd }, stageHRVHighPct)
        let hrvarHi = percentile(sleepFeats.map { $0.hrVar }, stageHRVarHighPct)
        let rrvHi = percentile(sleepFeats.map { $0.rrv }, stageRRVHighPct)
        let rrvLo = percentile(sleepFeats.map { $0.rrv }, stageRRVLowPct)
        let cardiacSparse = isCardiacSparse(sleepFeats)

        return features.map {
            classifyOne($0, hrLo: hrLo, hrHi: hrHi, rmssdHi: rmssdHi,
                        hrvarHi: hrvarHi, rrvHi: rrvHi, rrvLo: rrvLo,
                        cardiacSparse: cardiacSparse)
        }
    }

    /// Session-level PPG-derived / sparse-cardiac tell: most sleep-period epochs carry NO finite
    /// per-epoch RMSSD (sparse R-R). On those nights the HR is PPG-derived and its windowed variance
    /// (`hrVar`) is noisier, so the percentile `hrvarHigh` bar fires on genuinely still, low-HR sleep —
    /// which the WAKE rule must NOT treat as cardiac activation. Same `!rmssd.isFinite` signal already
    /// trusted for the pro-deep RMSSD handling (#127/#129), aggregated across the night. (#705)
    static func isCardiacSparse(_ sleepFeats: [EpochFeatures]) -> Bool {
        if sleepFeats.isEmpty { return false }
        let sparse = sleepFeats.reduce(0) { $0 + (($1.rmssd.isFinite) ? 0 : 1) }
        return Double(sparse) >= cardiacSparseEpochFrac * Double(sleepFeats.count)
    }

    /// What this epoch's respiration says about depth — FIVE states, because "we did not measure it" is
    /// not an observation and must not be spendable as one.
    ///
    /// This used to be two booleans over a NaN RRV, and the `regular` one read
    /// `(!f.rrv.isFinite) || (f.rrv <= rrvLo)`: a MISSING respiration reading was converted into a
    /// positive assertion that breathing was regular, which is pro-deep. On a WHOOP 5/MG that is not an
    /// edge case, it is the only code path — the v18 layout emits no `resp_rate_raw` at all (pinned by
    /// `Whoop5HistoricalTests`), so `respSample` has zero rows, every epoch's RRV is NaN, and the
    /// fabricated "regular" fires on 100% of epochs. Where a night with real respiration data has ~50% of
    /// its epochs clear the `regular` bar (it is the MEDIAN — `stageRRVLowPct` = 50), a 5/MG night has
    /// 100% clear it, on no measurement whatsoever.
    ///
    /// The five cases are the exact CROSS-PRODUCT of the two predicates this replaced, so the mapping is
    /// total and no case is decided by which bar `of` happens to test first:
    ///
    /// | pre-fix `rrvIrregular` | pre-fix `rrvRegular` | case |
    /// |---|---|---|
    /// | false | true (via `!isFinite`) | `unmeasured` |
    /// | false | true (via the low bar) | `regular` |
    /// | true | false | `irregular` |
    /// | false | false | `measuredMidBand` |
    /// | true | true | `barsDegenerate` |
    ///
    /// `unmeasured` and `measuredMidBand` are deliberately DISTINCT. Both fail the regular and irregular
    /// bars, but they mean opposite things — one is "no reading", the other is a real reading that simply
    /// sits between the bars — and the classifier already treats them differently (the REM fallback fires
    /// only on a missing reading). Collapsing them would silently change the hypnogram.
    enum RespEvidence {
        /// A finite RRV at or below the session's low bar — breathing measured as regular.
        case regular
        /// A finite RRV at or above the session's high bar — breathing measured as irregular.
        case irregular
        /// A finite RRV between the bars: measured, but neither notably regular nor notably irregular.
        case measuredMidBand
        /// No usable RRV for this epoch. Either the strap has no respiration channel at all (every 5/MG),
        /// or this epoch's window had too few / too flat samples to derive one (`respRateAndRRV` returns
        /// NaN below 8 samples, on a flat signal, under 3 peaks, or under 2 in-band breath intervals).
        case unmeasured
        /// A finite RRV that clears BOTH bars at once — at or above the high bar AND at or below the low
        /// bar. The session's two percentile bars have collapsed onto this reading, so it satisfies each
        /// of them and the pair carries no information at this value.
        ///
        /// Reachable, not hypothetical, and for a structural reason: RRV is the population std of breath
        /// intervals measured in WHOLE SECONDS (`respRateAndRRV`, `dtS` = 1), so it is quantised onto a
        /// small discrete lattice and exact ties between epochs are ordinary. `percentile` interpolates
        /// between order statistics, so p50 and p65 coincide whenever the tie run spans them — and when
        /// only ONE sleep epoch has a finite RRV (the rest NaN, which that same function returns freely on
        /// short, flat or low-peak windows) `percentile` returns that single value for both, so the epoch
        /// that SET the bars necessarily sits on both of them.
        ///
        /// Kept as its own case because a four-state enum cannot represent it: both pre-fix booleans were
        /// true here, so whichever bar the factory tested first would silently decide the label. Behaviour
        /// is pinned to the pre-fix outcome — waived for depth (`rrvRegular` was true, see
        /// `contradictsDepth`) and clearing the REM irregular bar (`rrvIrregular` was true, see
        /// `meetsIrregularBar`) — which keeps this change a representation fix.
        ///
        /// That pre-fix outcome resolves to DEEP only because the deep rule is written before the REM rule
        /// in `classifyOne`; statement order is not a reason, and re-deciding it is a live question. It is
        /// deliberately NOT re-decided here: doing so is a scoring change on the degenerate-distribution
        /// nights, and this repo has no staged nights of that shape to validate it against (CLAUDE.md,
        /// "validate against the artifact, not one match"). The point of naming the case is that the
        /// decision is now a one-line edit in `contradictsDepth` / `meetsIrregularBar` with a test that
        /// fails loudly, instead of an invisible consequence of statement order.
        case barsDegenerate

        /// Total mapping of the two pre-fix predicates. Written as an exhaustive switch on the pair
        /// rather than an ordered `if` chain, because an ordered chain is exactly how the `barsDegenerate`
        /// case used to be decided by accident.
        static func of(_ rrv: Double, lowBar: Double?, highBar: Double?) -> RespEvidence {
            guard rrv.isFinite else { return .unmeasured }
            let atOrAboveHigh = highBar.map { rrv >= $0 } ?? false
            let atOrBelowLow = lowBar.map { rrv <= $0 } ?? false
            switch (atOrAboveHigh, atOrBelowLow) {
            case (true, true): return .barsDegenerate
            case (true, false): return .irregular
            case (false, true): return .regular
            case (false, false): return .measuredMidBand
            }
        }

        /// Whether respiration CONTRADICTS depth. The deep rule reads this rather than a "regular" flag,
        /// because `unmeasured` is not evidence of regular breathing — it is the absence of evidence, and
        /// the rule it feeds is "respiration must not rule depth out".
        ///
        /// `unmeasured` is WAIVED here, not because missing respiration is reassuring, but because
        /// blocking on it would decode 0 m of deep on every 5/MG night — the exact regression #127/#129
        /// fixed for the parallel missing-RMSSD case, whose rule statement already carries the same
        /// qualifier ("with high parasympathetic tone WHEN MEASURABLE"). This makes the respiration
        /// waiver explicit and equally qualified instead of leaving it implied by a NaN short-circuit.
        ///
        /// `barsDegenerate` is waived too, matching the pre-fix `rrvRegular`; see its doc for why that is
        /// preserved rather than re-decided.
        ///
        /// KNOWN LIMITATION, deliberately not changed here: on a 5/MG BOTH waivers can fire at once
        /// (sparse R-R leaves RMSSD NaN too), and the deep rule then reduces to stillness + a low HR with
        /// no physiological corroboration at all. That is a real weakness, but it is bounded — `hrLow` is
        /// a PERCENTILE bar (`stageHRLowPct` = 25), so at most ~25% of sleep epochs can clear it however
        /// the respiration term resolves. Narrowing the waiver (e.g. to epoch-level gaps within a night
        /// that HAS a respiration channel, versus a device with no channel at all) is a scoring change
        /// that needs validation data this repo does not have — see the "validate against the artifact,
        /// not one match" rule in CLAUDE.md. `SleepStagerRespEvidenceTests` pins the current behaviour and
        /// quantifies the bias so that decision can be made on numbers.
        var contradictsDepth: Bool {
            switch self {
            case .regular, .unmeasured, .barsDegenerate: return false
            case .irregular, .measuredMidBand: return true
            }
        }

        /// Whether this epoch clears the session's IRREGULAR bar — the pre-fix `rrvIrregular` predicate,
        /// which the main REM rule reads. `barsDegenerate` clears it (it IS at or above the high bar) even
        /// though `contradictsDepth` also waives it; that pair of answers is precisely the pre-fix state
        /// where both booleans were true, and it is preserved deliberately.
        var meetsIrregularBar: Bool {
            switch self {
            case .irregular, .barsDegenerate: return true
            case .regular, .measuredMidBand, .unmeasured: return false
            }
        }
    }

    static func classifyOne(_ f: EpochFeatures, hrLo: Double?, hrHi: Double?,
                            rmssdHi: Double?, hrvarHi: Double?, rrvHi: Double?, rrvLo: Double?,
                            cardiacSparse: Bool = false) -> String {
        let hasHR = f.hr.isFinite
        let hrLow = hasHR && hrLo != nil && f.hr <= hrLo!
        let hrHigh = hasHR && hrHi != nil && f.hr >= hrHi!

        // NOTE: HF omitted (no neurokit2). Parasympathetic tone = RMSSD only. A MISSING per-epoch
        // RMSSD (sparse R-R, common on BLE-offloaded nights and especially 5/MG) is treated as
        // pro-deep rather than deep-blocking — mirroring how a missing respiration value is handled
        // below — so those nights stop decoding 0 m of deep sleep despite a real depth signature
        // (still + low HR + regular breathing). An epoch WITH a finite RMSSD must still clear the
        // high-tone bar. (#127, #129)
        let parasympOK = (!f.rmssd.isFinite) || (rmssdHi != nil && f.rmssd >= rmssdHi!)

        let hrvarHigh = f.hrVar.isFinite && hrvarHi != nil && f.hrVar >= hrvarHi!
        let cardiacActivated = hrHigh || hrvarHigh

        // WAKE-specific cardiac vetting. On a PPG-derived / sparse-cardiac night the per-epoch HR-variance
        // is noisy, so `hrvarHigh` fires on still, low-HR sleep and used to flip those epochs to WAKE. When
        // the session is sparse we DOWN-WEIGHT hrVar for the wake promotion and require a real elevated HR
        // (`hrHigh`) — the down-weighting mirrors how sparse R-R is trusted for the pro-deep RMSSD handling.
        // Dense 4.0 nights keep the full `hrHigh || hrvarHigh` signal, so their behaviour is unchanged. (#705)
        let cardiacActivatedForWake = cardiacSparse ? hrHigh : cardiacActivated

        let resp = RespEvidence.of(f.rrv, lowBar: rrvLo, highBar: rrvHi)

        let still = f.moveFrac <= stageStillMoveFrac
        let moving = f.moveFrac >= stageWakeMoveFrac

        // WAKE: sustained motion + activated cardiac (or no HR to vet motion). On a sparse/PPG night the
        // cardiac half is vetted by HR only (see `cardiacActivatedForWake`), so noisy hrVar no longer
        // over-promotes still sleep to wake. (#705)
        if moving && (cardiacActivatedForWake || !hasHR) { return "wake" }
        // DEEP: still + low HR + respiration that does not RULE OUT depth, with high parasympathetic tone
        // when measurable. `contradictsDepth` is where an unmeasured respiration is waived — see its doc
        // for why the waiver stays and what it costs.
        if still && parasympOK && hrLow && !resp.contradictsDepth { return "deep" }
        // REM: still body + activated cardiac + respiration clearing the irregular bar.
        if still && cardiacActivated && resp.meetsIrregularBar { return "rem" }
        // REM fallback when respiration was never MEASURED (not merely mid-band): require BOTH cardiac
        // signals. A mid-band reading is real evidence and does not earn the fallback.
        if still && hrHigh && hrvarHigh && resp == .unmeasured { return "rem" }
        return "light"
    }

    // MARK: - Post-processing (Stage 3)

    static func smoothLabels(_ labels: [String], window: Int = smoothEpochs) -> [String] {
        let n = labels.count
        if n == 0 || window <= 1 { return labels }
        var w = window
        if w % 2 == 0 { w += 1 }
        let half = w / 2
        var out: [String] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let lo = max(0, i - half)
            let hi = min(n, i + half + 1)
            var counts: [String: Int] = [:]
            var order: [String] = []
            for s in labels[lo..<hi] {
                if counts[s] == nil { order.append(s) }
                counts[s, default: 0] += 1
            }
            guard let best = counts.values.max() else { out.append(labels[i]); continue }
            let winners = order.filter { counts[$0] == best }  // insertion order preserved
            out.append(winners.contains(labels[i]) ? labels[i] : winners[0])
        }
        return out
    }

    static func reimposePhysiology(_ labels: [String], features: [EpochFeatures],
                                   onsetIdx: Int, finalWakeIdx: Int) -> [String] {
        var out = labels
        let noREMEpochs = Int((noREMAfterOnsetMin * 60.0 / epochS).rounded())
        // "Deep is front-loaded" re-imposes scattered late "deep" back to light — BUT only when there's
        // deep in the first third to anchor that prior. If the whole detected deep block lands later
        // (individual variation, or HR/HRV-only staging without respiration placing the deepest, lowest-HR
        // window later), zeroing it out gives a wrong "0 m deep"; keeping the best estimate is better. (#127)
        let hasEarlyDeep = zip(labels, features).contains { $0.0 == "deep" && $0.1.clock <= deepFirstFraction }
        for (i, f) in features.enumerated() {
            if i < onsetIdx || i > finalWakeIdx { continue }
            if out[i] == "rem" && (i - onsetIdx) < noREMEpochs { out[i] = "light" }
            if out[i] == "deep" && f.clock > deepFirstFraction && hasEarlyDeep { out[i] = "light" }
        }
        return out
    }

    // MARK: - REM-funnel diagnostic (#688)

    // 0% REM over a whole night is physiologically implausible (healthy adults cycle ~20–25% REM),
    // so a 0%-REM hypnogram — common on WHOOP 4.0 nights staged WITHOUT a respiration channel —
    // points at the STAGER, not the sleeper. The REM path in `classifyOne` is gated by three
    // predicates (still body + activated cardiac + irregular respiration), with a no-resp fallback
    // (still + high HR + high HR-variability), and any surviving early-REM is then stripped by the
    // no-REM-after-onset re-imposition. This pure, READ-ONLY diagnostic re-runs that exact funnel and
    // counts where REM was lost — WITHOUT changing a single label or score — so a 0%-REM night can be
    // triaged (e.g. "respiration unavailable AND HR-variability never cleared its high bar → no epoch
    // could be REM" vs "REM was detected but all of it fell inside the 15-min onset guard"). It is a
    // triage surface, logged by the caller, never a scoring change.

    /// Why REM funneled toward zero for one staged session window. Counts are over the SLEEP-PERIOD
    /// epochs (onset…finalWake) the classifier actually ranges; pure + deterministic; shares the exact
    /// classifier seam with `stageSession`, so it explains the SAME hypnogram the app shows. (#688)
    public struct REMFunnelDiagnostic: Equatable, Sendable {
        /// Sleep-period epochs considered (onset…finalWake inclusive).
        public let sleepEpochs: Int
        /// Epochs the classifier labelled "rem" BEFORE smoothing / re-imposition.
        public let remAtClassify: Int
        /// "rem" epochs surviving the no-REM-after-onset re-imposition (the final hypnogram's REM).
        public let remAfterReimpose: Int
        /// Classified-REM epochs stripped specifically by the 15-min onset guard.
        public let remStrippedByOnsetGuard: Int
        /// Whether ANY epoch carried a finite respiration-variability feature (the resp channel was
        /// usable). False ⇒ the whole night ran the no-resp REM fallback — the dominant 4.0 cause.
        public let respChannelPresent: Bool
        /// Among sleep-period epochs, how many were blocked from REM by each gate (a per-epoch reason,
        /// counted at the FIRST gate that rejected it, in classifier precedence). These sum with
        /// `remAtClassify` (and any wake/deep wins) to the sleep-epoch total.
        public let blockedNotStill: Int          // body not still enough (moveFrac above the still bar)
        public let blockedNoCardiacActivation: Int  // neither HR-high nor HR-variability-high
        public let blockedRespRegular: Int       // resp present but NOT irregular (regular breathing)
        public let blockedNoRespFallbackBar: Int // resp absent and the stricter no-resp REM bar unmet
        /// Won a non-REM stage outright (wake/deep/light) before any REM gate — not a REM rejection.
        public let wonOtherStage: Int

        public init(sleepEpochs: Int, remAtClassify: Int, remAfterReimpose: Int,
                    remStrippedByOnsetGuard: Int, respChannelPresent: Bool,
                    blockedNotStill: Int, blockedNoCardiacActivation: Int,
                    blockedRespRegular: Int, blockedNoRespFallbackBar: Int, wonOtherStage: Int) {
            self.sleepEpochs = sleepEpochs; self.remAtClassify = remAtClassify
            self.remAfterReimpose = remAfterReimpose; self.remStrippedByOnsetGuard = remStrippedByOnsetGuard
            self.respChannelPresent = respChannelPresent
            self.blockedNotStill = blockedNotStill
            self.blockedNoCardiacActivation = blockedNoCardiacActivation
            self.blockedRespRegular = blockedRespRegular
            self.blockedNoRespFallbackBar = blockedNoRespFallbackBar
            self.wonOtherStage = wonOtherStage
        }

        /// True when the final hypnogram carries no REM at all — the case this diagnostic exists to
        /// triage. (`remAfterReimpose == 0`.)
        public var isZeroREM: Bool { remAfterReimpose == 0 }

        /// One human-readable line for the caller to LOG. No I/O here — the engine stays pure.
        public var summary: String {
            "REM-funnel: \(sleepEpochs) sleep-epochs, classify=\(remAtClassify) rem, "
            + "final=\(remAfterReimpose) rem (onset-guard stripped \(remStrippedByOnsetGuard)); "
            + "resp=\(respChannelPresent ? "present" : "ABSENT"); "
            + "blocked[notStill=\(blockedNotStill), noCardiac=\(blockedNoCardiacActivation), "
            + "respRegular=\(blockedRespRegular), noRespBar=\(blockedNoRespFallbackBar)], "
            + "otherStage=\(wonOtherStage)"
        }
    }

    /// Per-epoch reason REM was rejected, evaluated in classifier precedence order. `remEligible`
    /// means the epoch WOULD be labelled REM. Internal — drives `remFunnelDiagnostic`.
    enum REMRejectReason { case remEligible, wonOtherStage, notStill, noCardiacActivation, respRegular, noRespFallbackBar }

    /// Classify a single epoch's REM-eligibility AND, when not eligible, the FIRST reason it failed —
    /// using the exact predicates and precedence of `classifyOne` so the diagnostic can never diverge
    /// from the real classifier. Read-only. (#688)
    static func remRejectReason(_ f: EpochFeatures, hrLo: Double?, hrHi: Double?,
                                rmssdHi: Double?, hrvarHi: Double?, rrvHi: Double?, rrvLo: Double?,
                                cardiacSparse: Bool = false) -> REMRejectReason {
        // Mirror classifyOne's derived predicates exactly.
        let hasHR = f.hr.isFinite
        let hrLow = hasHR && hrLo != nil && f.hr <= hrLo!
        let hrHigh = hasHR && hrHi != nil && f.hr >= hrHi!
        let parasympOK = (!f.rmssd.isFinite) || (rmssdHi != nil && f.rmssd >= rmssdHi!)
        let hrvarHigh = f.hrVar.isFinite && hrvarHi != nil && f.hrVar >= hrvarHi!
        let cardiacActivated = hrHigh || hrvarHigh
        let cardiacActivatedForWake = cardiacSparse ? hrHigh : cardiacActivated
        // Same respiration evidence the classifier uses, from the same factory — so the diagnostic cannot
        // drift from the rule it explains (these predicates were duplicated by hand).
        let resp = RespEvidence.of(f.rrv, lowBar: rrvLo, highBar: rrvHi)
        let still = f.moveFrac <= stageStillMoveFrac
        let moving = f.moveFrac >= stageWakeMoveFrac

        // classifyOne precedence: WAKE, then DEEP, then REM (then REM fallback), else LIGHT.
        // An epoch that wins WAKE or DEEP was never a REM candidate.
        if moving && (cardiacActivatedForWake || !hasHR) { return .wonOtherStage }     // → wake
        if still && parasympOK && hrLow && !resp.contradictsDepth { return .wonOtherStage } // → deep
        // From here the epoch did NOT win wake/deep; it is either REM or falls through to LIGHT.
        if still && cardiacActivated && resp.meetsIrregularBar { return .remEligible }
        if still && hrHigh && hrvarHigh && resp == .unmeasured { return .remEligible }
        // Not REM → attribute to the FIRST unmet REM precondition (in REM-rule order).
        if !still { return .notStill }
        if !cardiacActivated { return .noCardiacActivation }
        if resp != .unmeasured { return .respRegular }   // resp measured but not irregular
        return .noRespFallbackBar                          // resp never measured and the no-resp bar unmet
    }

    /// Read-only REM-funnel triage for ONE in-bed window [start, end] (#688). Re-runs THIS type's
    /// Stage-0→3 seam (epoch grid → Cole–Kripke → features → classify → smooth → re-impose), but
    /// instead of emitting a hypnogram it COUNTS where REM was lost. Changes NOTHING: no label, no
    /// score, no session. Returns nil only when the window has too little gravity to grid (mirroring
    /// `stageSession`'s degenerate fallback, which carries no REM to explain). The caller logs
    /// `.summary`; tests assert the counts. Pure + deterministic. (#688)
    ///
    /// WHICH HYPNOGRAM THIS EXPLAINS. V1's, always — this function is `SleepStager`'s own seam. It used
    /// to say it explained "the SAME hypnogram" as the screen, and that has been false since V2 became
    /// the default: the shipped hypnogram is staged by `SleepStagerV2` whenever
    /// `experimentalSleepV2Enabled` says so, which is by default. On a 5/MG the two can be far apart,
    /// because V1's primary REM gate needs the raw respiratory channel the hardware never emits while V2
    /// recovers respiration regularity from R-R: one field pair reported ~46 min REM here against hours
    /// on the screen for the same night (#2365). The caller's line names both stagers for that reason
    /// (#2366); do not restore the claim that they are one.
    public static func remFunnelDiagnostic(start: Int, end: Int, grav: [GravitySample],
                                           hr: [HRSample], rr: [RRInterval],
                                           resp: [RespSample]) -> REMFunnelDiagnostic? {
        let gSeg = rowsBetween(grav, start: start, end: end) { $0.ts }
        if gSeg.count < 2 { return nil }
        let gDeltas = gravityDeltas(gSeg)
        let gTimes = gSeg.map { $0.ts }
        let hrSeg = rowsBetween(hr, start: start, end: end) { $0.ts }
        let rrSeg = rowsBetween(rr, start: start, end: end) { $0.ts }
        let respSeg = rowsBetween(resp, start: start, end: end) { $0.ts }

        let grid = buildEpochGrid(start: Double(start), end: Double(end),
                                  gravTimes: gTimes, gravDeltas: gDeltas,
                                  hr: hrSeg, rr: rrSeg, resp: respSeg)
        if grid.nEpochs == 0 { return nil }

        let rescaled = rescaleCounts(grid.counts)
        let ckFlags = coleKripke(rescaled)
        let (onsetIdx, finalWakeIdx) = onsetAndFinalWake(ckFlags)
        let dogHR = dogHRVariability(grid.hr)
        let feats = extractFeatures(grid: grid, ckFlags: ckFlags, dogHR: dogHR,
                                    onsetIdx: onsetIdx, finalWakeIdx: finalWakeIdx)

        // The SAME session-relative reference percentiles classifyEpochs derives.
        let sleepFeats = feats.contains { $0.ckSleep } ? feats.filter { $0.ckSleep } : feats
        let hrLo = percentile(sleepFeats.map { $0.hr }, stageHRLowPct)
        let hrHi = percentile(sleepFeats.map { $0.hr }, stageHRHighPct)
        let rmssdHi = percentile(sleepFeats.map { $0.rmssd }, stageHRVHighPct)
        let hrvarHi = percentile(sleepFeats.map { $0.hrVar }, stageHRVarHighPct)
        let rrvHi = percentile(sleepFeats.map { $0.rrv }, stageRRVHighPct)
        let rrvLo = percentile(sleepFeats.map { $0.rrv }, stageRRVLowPct)
        let cardiacSparse = isCardiacSparse(sleepFeats)

        // Classify + post-process exactly as stageSession does, so we explain the SAME hypnogram.
        let labels = classifyEpochs(feats)
        let smoothed = smoothLabels(labels)
        let reimposed = reimposePhysiology(smoothed, features: feats,
                                           onsetIdx: onsetIdx, finalWakeIdx: finalWakeIdx)

        let noREMEpochs = Int((noREMAfterOnsetMin * 60.0 / epochS).rounded())
        var sleepEpochs = 0, remAtClassify = 0, remAfterReimpose = 0, remStrippedByOnsetGuard = 0
        var blockedNotStill = 0, blockedNoCardiacActivation = 0, blockedRespRegular = 0
        var blockedNoRespFallbackBar = 0, wonOtherStage = 0
        var respChannelPresent = false

        for i in onsetIdx...max(onsetIdx, finalWakeIdx) where i < feats.count {
            let f = feats[i]
            sleepEpochs += 1
            if f.rrv.isFinite { respChannelPresent = true }
            // Per-epoch REM reason at the raw classifier seam (pre-smoothing) — the funnel's mouth.
            switch remRejectReason(f, hrLo: hrLo, hrHi: hrHi, rmssdHi: rmssdHi,
                                   hrvarHi: hrvarHi, rrvHi: rrvHi, rrvLo: rrvLo,
                                   cardiacSparse: cardiacSparse) {
            case .remEligible:           remAtClassify += 1
            case .wonOtherStage:         wonOtherStage += 1
            case .notStill:              blockedNotStill += 1
            case .noCardiacActivation:   blockedNoCardiacActivation += 1
            case .respRegular:           blockedRespRegular += 1
            case .noRespFallbackBar:     blockedNoRespFallbackBar += 1
            }
            // Final-hypnogram REM (post smooth + re-impose) and the onset-guard strip.
            if reimposed[i] == "rem" { remAfterReimpose += 1 }
            // The re-imposition strips a SMOOTHED "rem" epoch inside the onset guard → light; count
            // the strip off the smoothed labels reimpose actually sees (exact, not the raw seam).
            if smoothed[i] == "rem" && (i - onsetIdx) < noREMEpochs { remStrippedByOnsetGuard += 1 }
        }

        return REMFunnelDiagnostic(
            sleepEpochs: sleepEpochs, remAtClassify: remAtClassify, remAfterReimpose: remAfterReimpose,
            remStrippedByOnsetGuard: remStrippedByOnsetGuard, respChannelPresent: respChannelPresent,
            blockedNotStill: blockedNotStill, blockedNoCardiacActivation: blockedNoCardiacActivation,
            blockedRespRegular: blockedRespRegular, blockedNoRespFallbackBar: blockedNoRespFallbackBar,
            wonOtherStage: wonOtherStage)
    }

    /// Sleep-depth rank, lighter → deeper: wake 0, light 1, rem 2, deep 3. Used by
    /// mergeFragments to bias an ambiguous merge toward the LIGHTER stage so smoothing
    /// can never inflate deep/REM. Unknown labels rank lightest (0) — they never win deep.
    static func stageDepthRank(_ stage: String) -> Int {
        switch stage {
        case "light": return 1
        case "rem":   return 2
        case "deep":  return 3
        default:      return 0  // "wake" and any unexpected label
        }
    }

    /// Display/scoring smoothing of the staged label sequence (#274). Absorbs sub-threshold
    /// "noise" runs WITHOUT erasing real transitions — applied AFTER staging, it never
    /// touches the underlying per-epoch detection.
    ///
    /// Per run shorter than fragmentMergeEpochs:
    ///   • bridged by two SAME-stage neighbours → absorbed into them (the fleck was a blip
    ///     inside one continuous stage);
    ///   • between DIFFERENT stages → relabelled to the dominant (longer) neighbour. On a tie
    ///     — or when the longer neighbour is the deeper one and the shorter is lighter and of
    ///     comparable length — it biases toward the LIGHTER neighbour so a stray fleck can
    ///     never inflate deep/REM (the least-reliable, most-overcountable classes).
    ///
    /// Single left-to-right pass over runs, mirroring mergePeriods' control flow so the
    /// Swift and Kotlin ports stay byte-identical. A run already ≥ threshold is a real
    /// transition and is always preserved.
    static func mergeFragments(_ labels: [String], thresholdEpochs: Int = fragmentMergeEpochs) -> [String] {
        let n = labels.count
        if n == 0 || thresholdEpochs <= 1 { return labels }

        // Collapse the per-epoch labels into contiguous runs of (stage, length).
        var runs: [(stage: String, len: Int)] = []
        for s in labels {
            if let last = runs.last, last.stage == s { runs[runs.count - 1].len += 1 }
            else { runs.append((stage: s, len: 1)) }
        }
        if runs.count < 2 { return labels }

        var merged: [(stage: String, len: Int)] = []
        var i = 0
        while i < runs.count {
            let current = runs[i]
            if current.len >= thresholdEpochs { merged.append(current); i += 1; continue }

            let hasPrev = !merged.isEmpty
            let hasNext = i + 1 < runs.count

            if hasPrev && hasNext && merged[merged.count - 1].stage == runs[i + 1].stage {
                // Same-stage bridge: absorb the fleck and the next run into the previous one.
                merged[merged.count - 1].len += current.len + runs[i + 1].len
                i += 2
            } else if hasPrev && hasNext {
                // Between two DIFFERENT stages: relabel to the dominant neighbour, biasing
                // toward the lighter stage when the two neighbours are tied in length.
                let prev = merged[merged.count - 1]
                let next = runs[i + 1]
                let winner: String
                if prev.len > next.len { winner = prev.stage }
                else if next.len > prev.len { winner = next.stage }
                else {
                    // Tie → lighter (smaller depth rank) wins; never inflate deep/REM.
                    winner = stageDepthRank(prev.stage) <= stageDepthRank(next.stage) ? prev.stage : next.stage
                }
                // Fold the fleck into whichever neighbour it became; the OTHER neighbour
                // stays its own run (handled on the next iterations).
                if winner == prev.stage {
                    merged[merged.count - 1].len += current.len
                    i += 1
                } else {
                    // Becomes part of the NEXT run: extend next, drop current.
                    runs[i + 1] = (stage: next.stage, len: next.len + current.len)
                    i += 1
                }
            } else if hasNext {
                // No previous run (leading fleck): fold forward into the next run.
                runs[i + 1] = (stage: runs[i + 1].stage, len: runs[i + 1].len + current.len)
                i += 1
            } else if hasPrev {
                // No next run (trailing fleck): fold back into the previous run.
                merged[merged.count - 1].len += current.len
                i += 1
            } else {
                // Single sub-threshold run with no neighbours — nothing to merge into.
                merged.append(current)
                i += 1
            }
        }

        // Re-expand the runs back into a per-epoch label sequence of the same length.
        var out: [String] = []
        out.reserveCapacity(n)
        for r in merged { out.append(contentsOf: repeatElement(r.stage, count: r.len)) }
        return out
    }

    // MARK: - Per-session HR / HRV

    /// Lowest 5-min rolling-mean HR during the session (bpm), or nil.
    ///
    /// The window is CLOSED at both ends, so the binning is too: bins are `[t, t + windowS)` except
    /// the final one, which is `[t, end]`. Half-open bins alone would admit a sample sitting exactly
    /// on an aligned `end` through the prefilter and then place it in no bin — counted as data,
    /// silently ignored. A zero-length window (`start == end`) is that single closed bin.
    /// #1943: a conformance check that reports when the artefact gate `sessionRestingHR` applies
    /// actually MOVED the floor. The shipped floor IS the gated floor, so comparing the gated floor
    /// against it is silent by construction. Instead, this reports the UNGATED floor (the old rule:
    /// min over every non-empty bin) against the shipped one, so the line fires when the gate
    /// excluded the bin that would otherwise have won — which is exactly the frequency and magnitude
    /// the measure-only diagnostic was meant to learn, and would never have reported otherwise.
    ///
    /// `sessionRestingHR` gates bins on `rhrMinBinSamples` and `rhrMinPlausibleBpm` before letting them
    /// win the floor, falling back to the lowest of all bin means when no bin qualifies. This helper
    /// reproduces the same partition and the same gate, and ALSO computes the ungated floor (min over
    /// every non-empty bin, the pre-#1943 rule) so the two can be compared.
    ///
    /// Bins are built exactly as `sessionRestingHR` builds them, closed final bin included, or the line
    /// would describe a different partition than the one it is judging.
    ///
    /// Returns nil unless the gate actually MOVED the floor (ungated != shipped), so the log carries
    /// only the nights the gate did something. If it turns out to fire on one night in fifty, that is
    /// worth knowing; if it fires nightly, that is worth knowing sooner.
    ///
    /// The counts still ride along when the line does fire, since they are the context for the change.
    /// Same posture as the over-count-only R-R dump. Counts and bpm only, no timestamps. Pure. Twin of
    /// Kotlin `rhrBinGateLogLine`.
    public static func rhrBinGateLogLine(day: String, sessions: [(Int, Int)], hr: [HRSample],
                                         shippedFloor: Int, minBinSamples: Int = rhrMinBinSamples,
                                         minPlausibleBpm: Double = rhrMinPlausibleBpm) -> String? {
        let windowS = 5 * 60
        var bins = 0, thin = 0, implausible = 0, ungatedN = 0
        var ungated: Double?
        var gated: Double?
        for (start, end) in sessions {
            let seg = hr.filter { $0.ts >= start && $0.ts <= end }
            if seg.isEmpty { continue }
            var t = start
            repeat {
                let isFinal = t + windowS >= end
                let win = seg.filter { $0.ts >= t && (isFinal || $0.ts < t + windowS) }
                if !win.isEmpty {
                    bins += 1
                    let mean = Double(win.reduce(0) { $0 + $1.bpm }) / Double(win.count)
                    if win.count < minBinSamples { thin += 1 }
                    if mean < minPlausibleBpm { implausible += 1 }
                    if ungated == nil || mean < ungated! { ungated = mean; ungatedN = win.count }
                    if win.count >= minBinSamples, mean >= minPlausibleBpm,
                       gated == nil || mean < gated! { gated = mean }
                }
                t += windowS
            } while t < end
        }
        if bins == 0 { return nil }
        let ungatedFloor = ungated.map { Int($0.rounded()) }
        // The gate moved the floor when the ungated floor differs from the shipped one. The shipped
        // floor IS the gated floor, so this fires when the gate excluded the bin that would have won
        // under the old rule — which is the frequency and magnitude we want to learn.
        let moved = ungatedFloor != nil && ungatedFloor != shippedFloor
        if !moved { return nil }
        let gatedFloor = gated.map { Int($0.rounded()) }
        return "rhr bins day=\(day) bins=\(bins) thin=\(thin) implausible=\(implausible) "
            + "winnerN=\(ungatedN) ungated=\(ungatedFloor.map(String.init) ?? "nil") "
            + "gated=\(gatedFloor.map(String.init) ?? "nil") shipped=\(shippedFloor) gateMoved=\(moved)"
    }

    static func sessionRestingHR(start: Int, end: Int, hr: [HRSample]) -> Int? {
        let seg = hr.filter { $0.ts >= start && $0.ts <= end }
        guard !seg.isEmpty else { return nil }
        let windowS = 5 * 60
        // #1943: a bin qualifies to WIN the floor only when it is well-populated (≥ rhrMinBinSamples)
        // and its mean is physiologically plausible (≥ rhrMinPlausibleBpm). A one-sample bin at the
        // edge of a wear gap, or a dropout-driven sub-physiological dip, cannot become the night's
        // resting HR — that number is displayed, stored on the daily row, and fed to the baseline
        // later nights are scored against. If no bin qualifies, fall back to the lowest of ALL bin
        // means (ungated), then the all-sample mean — preserving the never-null-on-data behaviour.
        var gatedMeans: [Double] = []
        var allMeans: [Double] = []
        var t = start
        repeat {
            // The last bin (its half-open end reaches or passes `end`) closes on `end` instead,
            // catching an endpoint sample the prefilter already admitted. `seg` holds nothing past
            // `end`, so "everything from t onwards" IS [t, end]. `repeat` runs once for a
            // zero-length window, where that single closed bin is the whole window.
            let isFinal = t + windowS >= end
            let win = seg.filter { $0.ts >= t && (isFinal || $0.ts < t + windowS) }
            if !win.isEmpty {
                let mean = Double(win.reduce(0) { $0 + $1.bpm }) / Double(win.count)
                allMeans.append(mean)
                if win.count >= rhrMinBinSamples && mean >= rhrMinPlausibleBpm { gatedMeans.append(mean) }
            }
            t += windowS
        } while t < end
        if let m = gatedMeans.min() { return Int(m.rounded()) }
        if let m = allMeans.min() { return Int(m.rounded()) }
        let all = Double(seg.reduce(0) { $0 + $1.bpm }) / Double(seg.count)
        return Int(all.rounded())
    }

    /// One 5-min HRV window: its start ts, the sleep stage at its center, the clean-beat count, and the
    /// window RMSSD (nil when <2 clean beats). Drives both `sessionAvgHRV` and the HRV test-mode trace. (#141)
    public struct HrvWindow: Sendable {
        public let startTs: Int
        public let stage: String
        public let cleanBeats: Int
        public let rmssd: Double?
    }

    /// Mean RMSSD over 5-min tumbling windows across the session (ms), or nil.
    /// A window counts only with `HRVAnalyzer.minBeats` clean intervals (see `sessionHrvWindows`).
    static func sessionAvgHRV(start: Int, end: Int, rr: [RRInterval]) -> Double? {
        let vals = sessionHrvWindows(start: start, end: end, rr: rr, stages: []).compactMap { $0.rmssd }
        if vals.isEmpty { return nil }
        // #1118: refuse the night outright when its own R-R banks more beat-time than the wall clock it
        // spans. Gated HERE rather than at the caller because this is where RMSSD BECOMES the day's HRV:
        // one seam covers the daily row, the sleep-session cache, the Health card and the baseline that
        // later nights are scored against, so none of them can end up disagreeing about whether the night
        // was trustworthy. See `HRVAnalyzer.successiveDiffIsTrustworthy` for why an over-count corrupts a
        // successive-difference statistic and why a blank is the right answer.
        //
        // Classified over the SAME beats the value was built from, windowed [start, end] exactly as
        // `sessionHrvWindows` does, so the verdict cannot describe a different set of beats than the number
        // it is gating.
        guard !sessionHrvOverCounted(start: start, end: end, rr: rr) else { return nil }
        return vals.reduce(0, +) / Double(vals.count)
    }

    /// Whether the #1118 coverage gate refuses a session's HRV: its own R-R, windowed [start, end] exactly
    /// as `sessionAvgHRV` windows it, banks more beat-time than the wall clock allows. Pure. The ONE
    /// definition of "refused": `sessionAvgHRV` gates on it, and `AnalyticsEngine` asks it whether a main
    /// night's missing HRV was refused rather than never measured, so the two cannot disagree about which
    /// nights were refused. Byte-parity twin of Kotlin `SleepStager.sessionHrvOverCounted`.
    static func sessionHrvOverCounted(start: Int, end: Int, rr: [RRInterval]) -> Bool {
        let seg = rr.filter { $0.ts >= start && $0.ts <= end }
        let segTs = seg.map { $0.ts }
        let segMs = seg.map { Double($0.rrMs) }
        let coverage = HRVAnalyzer.rrCoverage(tsSec: segTs, rrMs: segMs)
        // `collapsed` is deliberately the SAME figure as `coverage`, which pins every over-count here to
        // crossSecondOverCount. That is not a claim about which kind it is. The collapsed figure exists only
        // to choose BETWEEN the two over-count verdicts, and this gate refuses both, so the real one would
        // change no outcome — while costing a full sort of the night's ~50-70k beats, since
        // `collapsedCoverage` opens with a sort. This runs per session, per day, across ~21 days of every
        // analyzeRecent, every 15 minutes; #1510 cut this exact path from six sorts a night to two, and
        // buying a distinction the caller discards would hand that back. `rrCoverage` is a single O(n)
        // pass. If a future gate ever needs the two over-count cases apart, compute it then.
        let verdict = HRVAnalyzer.classifyCoverage(coverage: coverage, collapsed: coverage)
        return !HRVAnalyzer.successiveDiffIsTrustworthy(verdict)
    }

    /// Per-5-min-window RMSSD across a session, each window tagged with the sleep stage at its CENTER
    /// (from `stages`) — the SINGLE source `sessionAvgHRV` averages, and the HRV nightly trace reads.
    /// Passing `[]` for `stages` tags every window "?" (the plain-average path needs no stages). (#141)
    ///
    /// Windows follow the same closed-window rule as `sessionRestingHR`: `[t, t + windowS)` except
    /// the final one, which is `[t, end]`, so a beat sitting exactly on an aligned `end` lands in a
    /// window instead of being admitted by the prefilter and then dropped. Window stage tagging and
    /// `startTs` are unchanged — the final window keeps its half-open center `t + windowS / 2`.
    static func sessionHrvWindows(start: Int, end: Int, rr: [RRInterval], stages: [StageSegment]) -> [HrvWindow] {
        // CONTRACT: `rr` MUST already be ts-sorted (RMSSD is built from SUCCESSIVE differences, so a bucket
        // has to be chronological). The value path passes the loop's pre-sorted `rrS`; the trace caller sorts
        // its own copy. Not sorted here on purpose — re-sorting the value path could reorder same-second RR
        // under Swift's unstable sort and shift the shipped avgHrv. Same contract the original sessionAvgHRV had.
        let seg = rr.filter { $0.ts >= start && $0.ts <= end }
        guard !seg.isEmpty else { return [] }
        let windowS = 5 * 60
        var out: [HrvWindow] = []
        var t = start
        // One advancing index instead of re-filtering `seg` per window. The CONTRACT above already
        // guarantees ts-sorted input, so each window's beats are a CONTIGUOUS run and the scan can carry on
        // from where the previous window ended. The rescan it replaces was O(windows x beats): an
        // eight-hour night is about 96 windows, a real night banks tens of thousands of R-R, and
        // `AnalyticsEngine` reaches this five times per sleep session per day while `analyzeRecent` covers
        // three weeks. Output is unchanged, which is not an assertion: an oracle ran both bucketings over
        // 480 nights covering dense, sparse, duplicate-timestamp, tail-loaded, boundary and empty input and
        // found them identical.
        var i = seg.startIndex
        repeat {
            // Final window closes on `end` — same closed-window rule as sessionRestingHR, so an
            // endpoint beat counts instead of vanishing after admission. `repeat` runs once for a
            // zero-length window, where that single closed window is the whole session.
            let isFinal = t + windowS >= end
            // Defensive on the first window only: `seg` starts at or after `start`, so nothing is skipped
            // in practice, and a later window always resumes exactly where the previous one stopped.
            while i < seg.endIndex && seg[i].ts < t { i += 1 }
            var j = i
            if isFinal {
                // The final window takes every remaining beat, matching the old `isFinal` short-circuit,
                // which dropped the upper bound entirely and relied on `seg` already ending at `end`.
                j = seg.endIndex
            } else {
                let upper = t + windowS
                while j < seg.endIndex && seg[j].ts < upper { j += 1 }
            }
            let bucket = seg[i..<j].map { Double($0.rrMs) }
            if !isFinal { i = j }
            // Full clean (range + Malik ectopic rejection), not just range — matches the
            // analyze() pipeline. The 0x2A37 RR on a WHOOP 5/MG is PPG-derived and noisier
            // than a 4.0's; rMSSD is built from SUCCESSIVE differences, so an un-rejected
            // jitter spike inflates the session HRV. Ectopic rejection drops those (#262/#235).
            // #204/#195: gap-aware — a successive difference straddling a dropped beat is skipped so a
            // removed out-of-range/ectopic beat can't splice its neighbours into a spurious delta.
            let cleaned = HRVAnalyzer.cleanRRGapAware(bucket)
            // The same `minBeats` floor the spot reading and the SDNN index apply. The night is a plain mean
            // over windows, so without it a window left with a handful of clean beats (a dropout, a
            // movement-shredded stretch, a short final window) weighed as much as a full five minutes.
            let rmssd: Double? = (cleaned.nn.count >= HRVAnalyzer.minBeats)
                ? HRVAnalyzer.rmssdGapAware(cleaned.nn, cleaned.contiguous) : nil
            let center = t + windowS / 2
            let stage = stages.first { center >= $0.start && center < $0.end }?.stage ?? "?"
            out.append(HrvWindow(startTs: t, stage: stage, cleanBeats: cleaned.nn.count, rmssd: rmssd))
            t += windowS
        } while t < end
        return out
    }

    /// The LAST contiguous run of deep-stage windows in `windows` — the WHOOP-style "last slow-wave-sleep"
    /// comparator for the HRV nightly trace. Empty when no deep window is present. (#141)
    static func lastDeepRun(_ windows: [HrvWindow]) -> [HrvWindow] {
        var lastRun: [HrvWindow] = []
        var cur: [HrvWindow] = []
        for w in windows {
            if w.stage == "deep" { cur.append(w) } else if !cur.isEmpty { lastRun = cur; cur.removeAll() }
        }
        if !cur.isEmpty { lastRun = cur }
        return lastRun
    }

    // MARK: - AASM hypnogram metrics

    /// AASM-style metrics from a session's stage segments.
    public struct HypnogramMetrics: Equatable, Sendable {
        public let tibS: Double
        public let tstS: Double
        public let sptS: Double
        public let solS: Double
        public let remLatencyS: Double  // NaN if no REM
        public let wasoS: Double
        public let efficiency: Double
        public let disturbances: Int
        public let deepMin: Double
        public let remMin: Double
        public let lightMin: Double
        public let deepPct: Double
        public let remPct: Double
        public let lightPct: Double
    }

    public static func hypnogramMetrics(_ session: SleepSession) -> HypnogramMetrics {
        let segs = session.stages.sorted { $0.start < $1.start }
        let tib = max(0.0, Double(session.end - session.start))

        func dur(_ s: StageSegment) -> Double { Double(s.end - s.start) }
        let sleepSegs = segs.filter { $0.stage == "light" || $0.stage == "deep" || $0.stage == "rem" }
        let tst = sleepSegs.reduce(0.0) { $0 + dur($1) }
        let deepS = segs.filter { $0.stage == "deep" }.reduce(0.0) { $0 + dur($1) }
        let remS = segs.filter { $0.stage == "rem" }.reduce(0.0) { $0 + dur($1) }
        let lightS = segs.filter { $0.stage == "light" }.reduce(0.0) { $0 + dur($1) }

        let onset: Double, sptEnd: Double, sol: Double
        if let first = sleepSegs.first, let last = sleepSegs.last {
            onset = Double(first.start)
            sptEnd = Double(last.end)
            sol = max(0.0, onset - Double(session.start))
        } else {
            onset = Double(session.end)
            sptEnd = Double(session.end)
            sol = tib
        }

        let remSegs = segs.filter { $0.stage == "rem" }
        let remLatency = remSegs.first.map { Double($0.start) - onset } ?? Double.nan

        var waso = 0.0
        var disturbances = 0
        for s in segs where SleepStageVocabulary.isWake(s.stage) {
            let w0 = max(Double(s.start), onset)
            let w1 = min(Double(s.end), sptEnd)
            if w1 > w0 { waso += (w1 - w0); disturbances += 1 }
        }

        let se = tib > 0 ? tst / tib : 0.0
        func pct(_ x: Double) -> Double { tst > 0 ? x / tst * 100.0 : 0.0 }

        return HypnogramMetrics(
            tibS: tib, tstS: tst, sptS: max(0.0, sptEnd - onset), solS: sol,
            remLatencyS: remLatency, wasoS: waso, efficiency: min(1.0, se),
            disturbances: disturbances, deepMin: deepS / 60.0, remMin: remS / 60.0,
            lightMin: lightS / 60.0, deepPct: pct(deepS), remPct: pct(remS), lightPct: pct(lightS))
    }

    // MARK: - Small stats helpers

    /// Population standard deviation (numpy default, ddof=0).
    static func standardDeviation(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        var ss = 0.0
        for v in values { let d = v - mean; ss += d * d }
        return (ss / Double(values.count)).squareRoot()
    }
}
