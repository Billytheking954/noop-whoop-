package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.RrInterval
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/*
 * DaytimeStress.kt — an intraday (hour-by-hour) read of the SAME autonomic stress proxy
 * the daily Stress monitor shows, computed from the day's banked HR + R-R.
 *
 * Faithful Kotlin port of StrandAnalytics/DaytimeStress.swift (verified on macOS).
 *
 * The daily Stress score (StressScreen / StressView) maps "resting HR up + HRV down vs a
 * personal baseline" onto a 0–3 logistic. This helper applies that SAME math at the
 * per-hour grain so the Stress screen can show *when* in the day stress ran high — not a
 * new score. For each waking hour it computes:
 *
 *   • mean HR over the hour                    (HR up   = stress, like daily RHR)
 *   • RMSSD over the hour's clean R-R          (HRV down = stress, like daily avgHRV)
 *
 * and z-scores each against the strictly prior portion of the day's quiet reference,
 * then squashes the z-sum onto 0–3 with the identical logistic
 *   stress = 3 / (1 + e^(−raw)). 0 calm · 1.5 baseline · 3 high — same bands as the daily
 * score. During cross-day-baseline warm-up, only completed earlier hours can seed a point.
 *
 * "Sustained high stress" is an honest, conservative flag: the most recent
 * [sustainedHours] covered hours must ALL sit in the HIGH band (≥ [highBandFloor]). It
 * drives a passive in-app suggestion to run a Breathe session — never a notification.
 *
 * APPROXIMATE and non-clinical: an hour with inadequate temporal coverage or too few clean
 * beats is reported with a null level and never invented.
 */
object DaytimeStress {

    // MARK: - Tunables

    /** Bucket width for the timeline, in seconds (one hour). */
    const val bucketSeconds: Long = 3_600L
    /** Day-relative cold start is ready after one completed, quality-accepted waking bucket. */
    const val minimumCausalReferenceHours: Int = 1
    const val scoringAlgorithmVersion: String = "daytime-stress-v2"
    const val causalBaselineVersion: String = "strict-prior-hour-calm-prefix-v1"
    const val personalBaselineVersion: String = "daytime-winsorized-ewma-v1"
    /**
     * How far the DISPLAY timeline slides its window between points.
     *
     * The scored unit stays a full [bucketSeconds] hour. This only decides how often that hour is
     * re-read, so a half-step gives two points an hour, each still an hour of data, rather than
     * half-hours of thinner data. Shrinking [bucketSeconds] itself would have been a scoring change
     * wearing a display change's clothes: the calm reference is a quartile ACROSS buckets, the
     * post-exercise shadow looks back exactly one bucket, and [sustainedHours] counts them.
     *
     * Half rather than a quarter because adjacent points then share half their samples instead of
     * three quarters. The curve is smoother either way, and a denser line invites the reader to see
     * detail it cannot resolve: a 30-minute spike still moves an hour's worth of weight, just sooner.
     * Half is the least overlap that still doubles the resolution, and it keeps every on-the-hour
     * point exactly where the hourly pass put it.
     */
    const val timelineStepSeconds: Long = 1_800L
    /** Band floor for "high" on the shared 0–3 scale (matches StressBand.High). */
    const val highBandFloor: Double = 2.0
    /** Consecutive most-recent covered hours that must all be HIGH to flag sustained stress. */
    const val sustainedHours: Int = 3
    /** First/last local hour-of-day treated as "waking" for the timeline (06:00–22:00). */
    const val wakingStartHour: Int = 6
    const val wakingEndHour: Int = 22

    // MARK: - Motion gate
    //
    // Cardiac signals alone cannot separate psychological stress from EXERTION: a brisk walk and a
    // tense meeting both raise HR and suppress HRV. Without a motion channel an ambulatory hour is
    // scored as "stress". When the caller supplies the day's gravity (wrist accelerometer), an hour
    // that was substantially ambulatory is MASKED (null level, [HourPoint.maskedForActivity] true)
    // rather than scored, and it is excluded from the calm reference and the coverage totals. No
    // gravity → no masking → byte-identical prior behaviour, so the gate only applies when motion is
    // actually observable.

    /**
     * An hour whose gravity-derived activity is ambulatory for at least this fraction of its records
     * is EXERTION, not stress — masked, not scored. "Ambulatory" = a per-record activity intensity
     * above [WorkoutDetector.motionThreshold] (0.20 L2-g, the codebase's calibrated walk floor: desk
     * ≈ 0.05–0.10 g, walking ≈ 0.2–0.4 g). 0.30 means "at least 30 % of the hour was walking or
     * moving"; below it, a stray reach or one trip to the kitchen does not mask a desk hour. An
     * hourly grain is coarse — this is the gate that later allows finer epochs, at which point the
     * fraction can tighten. Range (0, 1].
     */
    const val activityMaskFraction: Double = 0.30

    /**
     * Post-exercise shadow: HR stays elevated for a while AFTER exertion ends, so the single hour
     * that immediately FOLLOWS a directly-ambulatory hour is ALSO masked WHILE its mean HR is still
     * above the calm reference by this margin (bpm). A following hour whose HR has already returned
     * to the calm reference is scored normally, so the shadow self-limits to genuine cardiac
     * recovery. Deliberately ONE hour deep (keyed on the directly-active hour, not chained through
     * prior shadows) so a genuinely tense afternoon that happens to follow a workout is not masked
     * away. Range >= 0.
     */
    const val postActivityShadowBpm: Double = 8.0

    /**
     * VALIDATED (26-day Oura-reference correlation, HR-only): a personal daytime-HR elevation
     * of ~15 bpm over a POOLED/ROLLING baseline — the 10th-percentile daytime HR pooled across
     * days, ~65 bpm in the reference set — is where elevated HR starts reading as
     * Oura-comparable "high" stress (r≈0.6 against Oura's own stress signal). A PER-DAY
     * (day-relative) baseline scored WORSE in the same comparison (r 0.43–0.53): an all-day
     * elevated day pulls its own floor up and masks the stress, which is exactly why
     * [ScoringMode.BaselineRelative] leans on [Baselines]' cross-day rolling EWMA instead of a
     * day-local reference. TUNING SEAM: this is HR-only; HR+HRV (WHOOP-era, RMSSD included) is
     * expected to beat this r≈0.6 ceiling — re-validate this margin once that comparison exists.
     * See [marginToSigma] for how it's translated onto the shared 0–3 squash curve.
     */
    const val baselineRelativeHighMarginBPM: Double = 15.0

    /**
     * Gate for whether the personal daytime-RMSSD baseline feeds the live 0–3 score. `false`:
     * [ScoringMode.BaselineRelative] scores HR-only, exactly the channel the r≈0.6 margin above was
     * validated on. The RMSSD half of the pipeline — [DaytimeBaselines.dayDaytimeAggregate],
     * [DaytimeBaselines.foldDaytimeBaselines], the `daytime_rmssd` config, and [rawScore]'s HRV
     * term — is built and unit-tested, but stays OUT of the live score until it has its OWN
     * Oura-reference validation pass.
     *
     * WHY OFF (validated against real WHOOP data, 2026-07): daytime RMSSD off the wrist is
     * artifact-dominated — hourly values swing ~40→430 ms as posture / motion / talking break the
     * R-R stream, an order of magnitude noisier than the overnight recumbent HRV the nightly
     * baselines use. [rawScore] sums the HRV z EQUAL-WEIGHT with the HR z, so an artifact hour can
     * swing the combined score by ±3 (the full band) on noise alone. Enabling it before it is shown
     * to IMPROVE the correlation risks pushing the combined score BELOW the HR-only r≈0.6 ceiling —
     * the exact regression [baselineRelativeHighMarginBPM]'s comment warns against. Flip to `true`
     * only once daytime HR+RMSSD is validated to beat HR-only on an Oura-style stress reference.
     */
    const val daytimeRMSSDScoringEnabled: Boolean = false

    // MARK: - Scoring mode

    /**
     * WHERE each hour's "calm" reference point + spread come from. Every other step —
     * bucketing, the waking-hour filter, the squash curve, sustained-high, high-stress-minutes
     * — is identical between modes; only the reference differs.
     *
     * Relationship to the rest of the Stress screen: the DAILY 0–3 score already compares last
     * night's NIGHTLY resting-HR/HRV to a plain trailing 30-day mean/SD (a once-a-day number
     * from SLEEP vitals). The Advanced HRV card ([StressIndex], [HrvFreqDomain]) is a today-only
     * descriptive lens with no baseline at all. [BaselineRelative] is neither: it's an HOURLY
     * breakdown of TODAY from DAYTIME/waking-hours HR+RMSSD against a PERSONAL cross-day rolling
     * baseline. Daytime HR runs warmer than nocturnal resting HR (posture, thermic effect), so it
     * needs its OWN baseline (`daytime_hr`/`daytime_rmssd`) rather than reusing the nightly
     * `resting_hr`/`hrv` configs — reusing the nightly ones would systematically over-read stress.
     * The three surfaces are complementary lenses on the same underlying autonomic signal, not
     * competing implementations of one baseline.
     */
    sealed interface ScoringMode {
        /**
         * Cold-start fallback. Each hour is z-scored against the calm reference built from
         * strictly earlier accepted waking hours; the first accepted hour is withheld.
         */
        object DayRelative : ScoringMode

        /**
         * Oura-style — each hour is z-scored against the PERSONAL rolling baseline for daytime
         * HR (and, when available, daytime RMSSD): the SAME Winsorized-EWMA machinery
         * ([Baselines.update] / [Baselines.foldHistory]) that backs the nightly HRV / resting-HR
         * baselines elsewhere, using [Baselines.daytimeHRCfg] / [Baselines.daytimeRMSSDCfg].
         *
         * The HR reference point is [hr]'s baseline, but the HIGH-band threshold does NOT scale
         * with this person's own day-to-day spread — see [baselineRelativeHighMarginBPM]: the
         * validated model is a roughly FIXED bpm margin over the personal floor, not a
         * variability-scaled one.
         *
         * [rmssd] is null when no personal RMSSD baseline exists yet — e.g. an imported, Oura-era
         * day with no R-R stream. The stressor then honestly falls back to HR-only scoring for the
         * whole read and flags [Result.hrOnlyFallback]; this mirrors the per-hour graceful-null
         * already in [rawScore], just at the whole-baseline grain. The RMSSD term (when present)
         * DOES still scale by [rmssd]'s spread via [Baselines.sigma] — only the HR term has a
         * validated fixed-margin figure so far.
         */
        data class BaselineRelative(val hr: BaselineState, val rmssd: BaselineState?) : ScoringMode
    }

    // MARK: - Output

    /**
     * One hour of the daytime timeline. [level] is the shared 0–3 stress proxy, or null when
     * the hour had too little signal to score honestly.
     */
    data class HourPoint(
        /** Hour-of-day on the LOCAL clock (0–23), the bucket this point covers. */
        val hour: Int,
        /** Unix seconds at the start of the bucket (wall-clock). */
        val startTs: Long,
        /** Shared 0–3 stress proxy for the hour, or null when no data. */
        val level: Double?,
        /** Mean HR over the hour (bpm), or null. */
        val meanHr: Double?,
        /** RMSSD over the hour's clean R-R (ms), or null (too few clean beats). */
        val rmssd: Double?,
        /**
         * True when this hour was left unscored because it was AMBULATORY (exertion), not because it
         * lacked HR — so a null [level] here means "masked as activity", not "no data". Lets the UI
         * separate "you were moving" from "no reading" and keeps active hours out of the calm
         * reference and the coverage totals. See the motion-gate constants above.
         */
        val maskedForActivity: Boolean = false,
        /** Structured, versioned HR quality evidence for this exact half-open bucket. */
        val quality: StressQualityDecision? = null,
    ) {
        /** True when the hour was scored (had enough HR to place on the curve). */
        val hasData: Boolean get() = level != null
    }

    /** The full daytime read: the hourly timeline plus the sustained-high summary. */
    data class Result(
        /** Waking-hour timeline, earliest → latest. Hours with no signal carry level == null. */
        val hours: List<HourPoint>,
        /** True when the most recent [sustainedHours] SCORED hours all sit in the HIGH band. */
        val sustainedHigh: Boolean,
        /** Count of trailing high hours backing [sustainedHigh] (0 when not sustained). */
        val sustainedRun: Int,
        /** Mean stress across the SCORED hours, or null when none were scorable. */
        val dayMean: Double?,
        /** Peak scored hour (highest level), or null. */
        val peak: HourPoint?,
        /**
         * Count of waking hours left unscored because they were AMBULATORY (the motion gate fired),
         * i.e. `hours.count { it.maskedForActivity }`. Lets a caller report honest coverage
         * ("N hours excluded — you were moving") instead of a silently short timeline. 0 when no
         * gravity was supplied or nothing was masked; 0 for [EMPTY].
         */
        val activityMaskedHours: Int = 0,
        /**
         * ADDITIVE — total minutes across SCORED waking hours at/above [highBandFloor], the
         * Oura-comparable "time in high stress" figure. Each scored hour is one [bucketSeconds]
         * bucket, so this is `(# high-band scored hours) * bucketSeconds / 60`. Compare against
         * Oura's `stress_high_s / 60` — NOOP's timeline is hourly-grain vs Oura's ~5-minute grain,
         * so treat this as a coarse approximation, not a precise match. 0 for [EMPTY] and for any
         * day with no scored hours.
         */
        val highStressMinutes: Int = 0,
        /**
         * ADDITIVE — true when [ScoringMode.BaselineRelative] mode was requested but had no
         * personal RMSSD baseline to score against (e.g. an imported Oura-era day with no R-R
         * history), so the whole read honestly fell back to HR-only scoring. Always false in
         * [ScoringMode.DayRelative] mode (there, a missing RMSSD is already handled per-hour by
         * [rawScore], not flagged day-wide) and false for [EMPTY].
         */
        val hrOnlyFallback: Boolean = false,
        /**
         * DISPLAY-ONLY sliding read of the same day: [hours] plus a point every
         * [timelineStepSeconds], each still scored over a full [bucketSeconds] window against the
         * SAME reference [hours] used. Defaults to [hours] so a caller that never asked for it, and
         * every existing test, sees exactly what it saw before.
         *
         * Deliberately NOT the input to anything that counts hours. [sustainedHigh],
         * [highStressMinutes], [dayMean] and [peak] all stay on the non-overlapping [hours], because
         * overlapping windows would count the same minute more than once.
         */
        val timeline: List<HourPoint> = hours,
        /** Replay receipt: algorithm/baseline identities and causal cutoff used for this result. */
        val algorithmVersion: String = scoringAlgorithmVersion,
        val baselineVersion: String = causalBaselineVersion,
        val asOfTimestamp: Long? = null,
    ) {
        /** The scored hours only (level non-null), in time order. */
        val scored: List<HourPoint> get() = hours.filter { it.level != null }

        companion object {
            /** Empty read — used when the day had no usable intraday HR at all. */
            val EMPTY = Result(emptyList(), sustainedHigh = false, sustainedRun = 0,
                dayMean = null, peak = null, activityMaskedHours = 0,
                highStressMinutes = 0, hrOnlyFallback = false)
        }
    }

    // MARK: - Shared stress math (identical formula to the daily StressModel)

    internal fun mean(xs: List<Double>): Double? =
        if (xs.isEmpty()) null else xs.sum() / xs.size

    /** Population standard deviation; 0 when there's no spread. (Matches StressMath.std.) */
    private fun std(xs: List<Double>, m: Double?): Double {
        if (m == null || xs.size <= 1) return 0.0
        val v = xs.sumOf { (it - m) * (it - m) } / xs.size
        return sqrt(v)
    }

    /**
     * Combined autonomic z-score. HR-up and HRV-down both push it positive — the SAME
     * directionality as the daily score (RHR up = stress, HRV down = stress).
     */
    private fun rawScore(
        hr: Double?, meanHr: Double?, sdHr: Double,
        rmssd: Double?, meanRmssd: Double?, sdRmssd: Double,
    ): Double {
        var sum = 0.0
        if (hr != null && meanHr != null && sdHr > 0.0001) {
            sum += (hr - meanHr) / sdHr            // HR up = stress
        }
        if (rmssd != null && meanRmssd != null && sdRmssd > 0.0001) {
            sum += (meanRmssd - rmssd) / sdRmssd   // HRV (RMSSD) down = stress
        }
        return sum
    }

    /**
     * Logistic squash of the raw z-sum onto 0–3 (baseline 0 → 1.5). Identical to
     * StressMath.squash, so an hourly point shares the daily score's scale and bands.
     */
    internal fun squash(raw: Double): Double =
        (3.0 / (1.0 + exp(-raw))).coerceIn(0.0, 3.0)

    /**
     * Solve for the z-score spread `sd` such that a raw elevation of exactly [marginBPM] (or any
     * unit — this is unit-agnostic) squashes to exactly [band] on the shared 0–3 curve:
     * `band = 3 / (1 + e^(−marginBPM/sd))`. Used to translate [baselineRelativeHighMarginBPM]'s
     * validated bpm figure into the `sd` the shared [squash] curve expects, so "baseline + margin"
     * lands exactly on [band] by construction rather than by a second, separate threshold check.
     * Defensive fallback (never divides by zero/negative-log) if [band] is ever configured at or
     * outside the curve's open range (0, 3).
     */
    internal fun marginToSigma(marginBPM: Double, band: Double): Double {
        val ratio = 3.0 / band - 1.0
        if (ratio <= 0.0 || marginBPM <= 0.0) return max(marginBPM, 1e-9)
        return marginBPM / (-ln(ratio))
    }

    // MARK: - Public API

    /**
     * Build the daytime stress timeline from a day's banked HR + R-R.
     *
     * @param hr the day's HR samples (any order; bucketed by ts here).
     * @param rr the day's R-R intervals.
     * @param gravity the day's gravity samples (wrist accelerometer), for the motion gate. Defaults
     *   empty: with no gravity NOTHING is masked and the read is byte-identical to before. When
     *   present, ambulatory hours are masked out of the score (see the motion-gate constants).
     * @param tzOffsetSeconds seconds east of UTC, for placing each bucket on the LOCAL clock
     *   (so "waking hours" and the hour labels are local). Defaults to UTC.
     * @param mode causal [ScoringMode.DayRelative] (default) or
     *   [ScoringMode.BaselineRelative] (Oura-style, vs a personal rolling baseline). ADDITIVE and
     *   opt-in: existing callers that don't pass `mode` keep the exact prior behaviour.
     *
     * Returns [Result.EMPTY] when there isn't a single hour with enough HR to score.
     */
    fun analyze(
        hr: List<HrSample>,
        rr: List<RrInterval>,
        gravity: List<GravitySample> = emptyList(),
        tzOffsetSeconds: Long = 0L,
        mode: ScoringMode = ScoringMode.DayRelative,
        /**
         * Also compute [Result.timeline], the sliding read is OPT-IN because half the callers do not want it.

     The Stress screen reads `hours` and draws its own interactive timeline; making it pay for a
     second pass of bucketing and one RMSSD per extra window, on the screen that already does three
     200 000-row reads, would be cost for nothing. The widget and the Today card ask for it.
         */
        includeTimeline: Boolean = false,
        asOfTimestamp: Long? = null,
    ): Result {
        val normalizedHr = hr.map { sample ->
            StressSignalSample(
                timestamp = sample.ts, value = sample.bpm.toDouble(),
                source = "repository-normalized", provenance = "com.noop.data.HrSample",
                quality = if (sample.bpm in 30..220) StressSignalSample.Quality.VALID
                    else StressSignalSample.Quality.REJECTED,
            )
        }
        return analyzeCanonical(normalizedHr, rr, gravity, tzOffsetSeconds, mode,
            includeTimeline, asOfTimestamp)
    }

    private fun analyzeUncached(
        normalizedHr: List<StressSignalSample>,
        rr: List<RrInterval>,
        gravity: List<GravitySample>,
        tzOffsetSeconds: Long,
        mode: ScoringMode,
        includeTimeline: Boolean,
        asOfTimestamp: Long,
    ): Result {
        if (normalizedHr.isEmpty()) return Result.EMPTY
        val effectiveAsOf = asOfTimestamp

        // 1) Bucket HR + R-R into LOCAL hour-of-day buckets, keyed by the bucket start
        //    (floored to the hour on the local clock).
        fun hrBuckets(phase: Long): HashMap<Long, MutableList<StressSignalSample>> {
            val m = HashMap<Long, MutableList<StressSignalSample>>()
            for (s in normalizedHr) {
                m.getOrPut(bucketOf(s.timestamp + tzOffsetSeconds, phase)) { ArrayList() }.add(s)
            }
            return m
        }
        fun rrBuckets(phase: Long): HashMap<Long, MutableList<Double>> {
            val m = HashMap<Long, MutableList<Double>>()
            for (s in rr) m.getOrPut(bucketOf(s.ts + tzOffsetSeconds, phase)) { ArrayList() }
                .add(s.rrMs.toDouble())
            return m
        }
        val hrByBucket = hrBuckets(0L)
        val rrByBucket = rrBuckets(0L)

        // 2) Per-hour mean HR + RMSSD. HR is accepted only when the versioned temporal decision clears
        //    represented-duration coverage and longest-gap limits; sample count is diagnostic only.
        data class HourAgg(
            val bucket: Long,
            val meanHr: Double?,
            val rmssd: Double?,
            val quality: StressQualityDecision,
            val activeContext: Boolean,
        )
        fun aggregate(
            hrGrid: Map<Long, MutableList<StressSignalSample>>,
            rrGrid: Map<Long, MutableList<Double>>,
        ): List<HourAgg> {
            val ordered = hrGrid.keys.sorted()
            val out = ArrayList<HourAgg>(ordered.size)
            for (b in ordered) {
                val hrs = hrGrid[b] ?: emptyList()
                val wallStart = b - tzOffsetSeconds
                val wallEnd = minOf(safeAdd(wallStart, bucketSeconds), effectiveAsOf)
                val quality = StressTemporalQuality.evaluate(
                    hrs, wallStart, wallEnd, true,
                )
                val mHr = if (quality.accepted) StressTemporalQuality.canonicalMean(
                    hrs, wallStart, wallEnd,
                ) else null
                val rrRes = HrvAnalyzer.analyzeRaw(rrGrid[b] ?: emptyList())
                out.add(HourAgg(b, mHr, rrRes.rmssd, quality,
                    hrs.any { it.activityContext == StressSignalSample.ActivityContext.ACTIVE }))
            }
            return out
        }
        val aggs = aggregate(hrByBucket, rrByBucket)

        // 2b) Motion gate: bucket the day's gravity-derived activity by the SAME local hour and mark
        //     each hour AMBULATORY when at least [activityMaskFraction] of its records clear the
        //     calibrated walk floor ([WorkoutDetector.motionThreshold]) — reusing the exact activity
        //     series SedentaryDetector / WorkoutDetector already trust. Empty gravity → no active
        //     buckets → nothing masked below (byte-identical to the pre-motion behaviour).
        // Derived ONCE and re-bucketed per grid. `activitySeries` walks the whole day's gravity, so
        // recomputing it for the second grid would have doubled the most expensive part of the motion
        // gate to answer the same question about the same samples.
        val activity = if (gravity.isEmpty()) emptyList() else WorkoutDetector.activitySeries(gravity)
        fun activeFractions(phase: Long): HashMap<Long, Double> {
            val out = HashMap<Long, Double>()
            if (activity.isEmpty()) return out
            val activeCounts = HashMap<Long, Int>()
            val totalCounts = HashMap<Long, Int>()
            for (p in activity) {
                val bucket = bucketOf(p.ts + tzOffsetSeconds, phase)
                totalCounts[bucket] = (totalCounts[bucket] ?: 0) + 1
                if (p.intensity > WorkoutDetector.motionThreshold) {
                    activeCounts[bucket] = (activeCounts[bucket] ?: 0) + 1
                }
            }
            for ((b, total) in totalCounts) {
                if (total > 0) out[b] = (activeCounts[b] ?: 0).toDouble() / total
            }
            return out
        }
        val activeFracByBucket = activeFractions(0L)
        // 3) External reference state. Day-relative references are built per point from a causal
        //    prefix inside scoreGrid, never from later buckets.
        val refHr: Double?
        val sdHr: Double
        val refRmssd: Double?
        val sdRmssd: Double
        val hrOnlyFallback: Boolean
        val baselineVersion: String
        when (mode) {
            is ScoringMode.DayRelative -> {
                refHr = null
                refRmssd = null
                sdHr = 0.0
                sdRmssd = 0.0
                hrOnlyFallback = false
                baselineVersion = causalBaselineVersion
            }
            is ScoringMode.BaselineRelative -> {
                // The PERSONAL cross-day baseline, folded by the caller from past daytime
                // aggregates via Baselines.update/foldHistory (see the ScoringMode doc).
                // Ambulatory hours are still masked out of the SCORE in step 4 (the motion gate),
                // but the reference itself is external, so it needs no ambulatory exclusion here.
                refHr = mode.hr.baseline
                // VALIDATED tuning, not Baselines.sigma(mode.hr): the correlation study behind
                // baselineRelativeHighMarginBPM found a roughly FIXED bpm margin over the personal
                // floor — not one scaled by this person's own day-to-day spread — best matched
                // Oura's stress signal. marginToSigma solves for the sd that makes exactly
                // refHr + baselineRelativeHighMarginBPM land on highBandFloor on the shared squash
                // curve, so the validated margin IS the "high" cutoff by construction.
                sdHr = marginToSigma(baselineRelativeHighMarginBPM, highBandFloor)
                val rmssdBaseline = mode.rmssd
                if (rmssdBaseline != null) {
                    refRmssd = rmssdBaseline.baseline
                    // No independently validated RMSSD margin yet (see the constant's doc) — this
                    // term still scales by the person's own spread via the shared σ conversion.
                    sdRmssd = Baselines.sigma(rmssdBaseline)
                    hrOnlyFallback = false
                } else {
                    // No personal RMSSD baseline exists (e.g. an Oura-era day with no R-R history to
                    // fold one from). rawScore already treats a null meanRmssd as "skip this term",
                    // so passing null here gracefully degrades to HR-only scoring — flagged honestly
                    // in the output rather than silently.
                    refRmssd = null
                    sdRmssd = 0.0
                    hrOnlyFallback = true
                }
                baselineVersion = personalBaselineVersion
            }
        }

        // 4) Score each waking-hour bucket on the shared 0–3 curve.
        //
        // Written against a supplied bucket grid so the SAME expression scores the on-the-hour pass
        // and the half-step display pass. One copy, so the two can never drift into scoring the same
        // hour differently — which is the whole reason the sliding read reuses the references
        // computed above rather than deriving its own.
        fun scoreGrid(gridAggs: List<HourAgg>, activeFrac: Map<Long, Double>): List<HourPoint> {
            val contextByBucket = gridAggs.associate { it.bucket to it.activeContext }
            fun ambulatory(bucket: Long): Boolean =
                contextByBucket[bucket] == true ||
                    (activeFrac[bucket] ?: 0.0) >= activityMaskFraction
            val out = ArrayList<HourPoint>(gridAggs.size)
            for (a in gridAggs) {
                if (!isWakingHour(a.bucket)) continue
                val pointRefHr: Double?
                val pointSdHr: Double
                val pointRefRmssd: Double?
                val pointSdRmssd: Double
                when (mode) {
                    is ScoringMode.DayRelative -> {
                        val prefix = gridAggs.filter {
                            it.bucket < a.bucket && isWakingHour(it.bucket) && !ambulatory(it.bucket)
                        }
                        val hrMeans = prefix.mapNotNull { it.meanHr }
                        val rmssdVals = prefix.mapNotNull { it.rmssd }
                        pointRefHr = calmReference(hrMeans, calmIsLow = true)
                        pointSdHr = std(hrMeans, mean(hrMeans))
                        pointRefRmssd = calmReference(rmssdVals, calmIsLow = false)
                        pointSdRmssd = std(rmssdVals, mean(rmssdVals))
                    }
                    is ScoringMode.BaselineRelative -> {
                        pointRefHr = refHr
                        pointSdHr = sdHr
                        pointRefRmssd = refRmssd
                        pointSdRmssd = sdRmssd
                    }
                }
                val referenceReady = when (mode) {
                    is ScoringMode.DayRelative -> gridAggs.count {
                        it.bucket < a.bucket && isWakingHour(it.bucket) && !ambulatory(it.bucket) &&
                            it.meanHr != null
                    } >= minimumCausalReferenceHours
                    is ScoringMode.BaselineRelative -> mode.hr.usable
                }
                val pointQuality = a.quality.withBaselineReadiness(referenceReady)
                val hourOfDay = (floorDiv(a.bucket, bucketSeconds) % 24).toInt()
                // The wall-clock bucket start (undo the local shift applied above).
                val wallStart = a.bucket - tzOffsetSeconds
                // Motion gate: an AMBULATORY hour — or the post-exercise shadow hour whose HR has not
                // yet recovered to the calm reference — is EXERTION, so its elevated HR is masked out
                // of the score instead of read as stress. The shadow is gated on refHr so it
                // self-limits to genuine cardiac recovery (a following hour already back at baseline
                // scores normally). Only meaningful when the hour actually HAD a reading to withhold
                // — a no-HR hour is plain no-data, not "masked". The look-back is one FULL window on
                // either grid, so the half-step pass shadows the same hour of exertion.
                val shadow = ambulatory(a.bucket - bucketSeconds) &&
                    a.meanHr != null && pointRefHr != null &&
                    a.meanHr > pointRefHr + postActivityShadowBpm
                val masked = a.meanHr != null && (ambulatory(a.bucket) || shadow)
                // Score only when HR cleared the temporal gate AND the hour was not motion-masked (HR is
                // the always-available anchor; RMSSD enriches it when beats allow).
                val level: Double? = if (pointQuality.accepted && a.meanHr != null && !masked) {
                    squash(rawScore(a.meanHr, pointRefHr, pointSdHr,
                        a.rmssd, pointRefRmssd, pointSdRmssd))
                } else {
                    null
                }
                out.add(HourPoint(hourOfDay, wallStart, level, a.meanHr, a.rmssd,
                    maskedForActivity = masked, quality = pointQuality))
            }
            return out
        }
        val points = scoreGrid(aggs, activeFracByBucket)
        val activityMaskedHours = points.count { it.maskedForActivity }

        // 4b) The half-step DISPLAY timeline: the same hour-long window re-read every
        //     [timelineStepSeconds], scored against the SAME references, and merged with the
        //     on-the-hour points. Every hourly point survives untouched; only the straddling
        //     midpoints are new, so the curve still passes through exactly the values scored above.
        //     Nothing that counts hours reads this — see [Result.timeline].
        val timeline = if (includeTimeline && timelineStepSeconds in 1 until bucketSeconds) {
            val midAggs = aggregate(hrBuckets(timelineStepSeconds), rrBuckets(timelineStepSeconds))
            (points + scoreGrid(midAggs, activeFractions(timelineStepSeconds)))
                .sortedBy { it.startTs }
        } else {
            points
        }

        val scored = points.mapNotNull { p -> p.level?.let { p to it } }
        if (scored.isEmpty()) {
            // No scorable waking hour — still return the (unscored) timeline so the UI can
            // show "not enough data" rather than nothing. hrOnlyFallback is a MODE property
            // (whether a personal RMSSD baseline existed to score against), so it's still worth
            // reporting even though nothing ended up scored.
            return if (points.isEmpty()) Result.EMPTY
            else Result(points, sustainedHigh = false, sustainedRun = 0, dayMean = null, peak = null,
                activityMaskedHours = activityMaskedHours,
                highStressMinutes = 0, hrOnlyFallback = hrOnlyFallback, timeline = timeline,
                baselineVersion = baselineVersion, asOfTimestamp = effectiveAsOf)
        }

        // 5) Sustained-high flag: walk back from the latest SCORED hour while each is HIGH.
        var run = 0
        for ((_, lvl) in scored.asReversed()) {
            if (lvl >= highBandFloor) run += 1 else break
        }
        val sustained = run >= sustainedHours

        val dayMean = mean(scored.map { it.second })
        val peak = scored.maxByOrNull { it.second }?.first

        // 6) Oura-comparable "time in high stress": each scored hour at/above highBandFloor is one
        //    full bucketSeconds bucket, converted to minutes. Uses the SAME threshold the
        //    sustained-high check above already uses, so all stay in lockstep by construction.
        val highStressMinutes = scored.count { it.second >= highBandFloor } * (bucketSeconds / 60L).toInt()

        return Result(points, sustained, run, dayMean, peak,
            timeline = timeline,
            activityMaskedHours = activityMaskedHours,
            highStressMinutes = highStressMinutes, hrOnlyFallback = hrOnlyFallback,
            baselineVersion = baselineVersion, asOfTimestamp = effectiveAsOf)
    }

    /** Canonical decoder entry point; legacy [HrSample] callers use the adapter in [analyze]. */
    fun analyzeCanonical(
        samples: List<StressSignalSample>,
        rr: List<RrInterval>,
        gravity: List<GravitySample> = emptyList(),
        tzOffsetSeconds: Long = 0L,
        mode: ScoringMode = ScoringMode.DayRelative,
        includeTimeline: Boolean = false,
        asOfTimestamp: Long? = null,
    ): Result = analyzeUncached(
        samples, rr, gravity, tzOffsetSeconds, mode, includeTimeline,
        asOfTimestamp ?: Long.MAX_VALUE,
    )

    private fun safeAdd(value: Long, positiveDelta: Long): Long =
        if (value > Long.MAX_VALUE - positiveDelta) Long.MAX_VALUE else value + positiveDelta

    // MARK: - Helpers

    /**
     * Floor-division that is correct for negative numerators (so a local time just before
     * the UTC epoch still buckets to the hour below, not toward zero).
     */
    internal fun floorDiv(a: Long, b: Long): Long {
        val q = a / b
        val r = a % b
        return if (r != 0L && (r < 0L) != (b < 0L)) q - 1 else q
    }

    /**
     * The bucket a local timestamp falls in for a grid offset by [phase].
     *
     * `phase = 0` is the on-the-hour grid every existing reading uses. `phase = timelineStepSeconds`
     * is the same grid slid forward, so its windows straddle the hour boundaries rather than
     * replacing them.
     */
    private fun bucketOf(localTs: Long, phase: Long): Long =
        floorDiv(localTs - phase, bucketSeconds) * bucketSeconds + phase

    /**
     * Whether a LOCAL hour-of-day falls inside the waking window the timeline scores (06:00-22:00).
     *
     * Split out from [isWakingHour] so a caller holding a wall-clock hour rather than a bucket can ask
     * the same question of the same constants. The stress widget needs exactly that: to say whether an
     * empty curve means "nothing is coming until morning" or "today has not produced a scorable hour
     * yet", it has to know the window, and reimplementing the comparison there would be a second copy
     * of a rule whose whole point is having one.
     */
    internal fun isWakingHourOfDay(hourOfDay: Int): Boolean =
        hourOfDay >= wakingStartHour && hourOfDay < wakingEndHour

    /**
     * Whether a local hour-bucket start falls inside the waking window the timeline scores
     * (06:00–22:00). The single source of truth for "waking" — used both to build the calm
     * reference and to pick the hours to score, so the two can never drift apart.
     */
    internal fun isWakingHour(bucket: Long): Boolean =
        isWakingHourOfDay((floorDiv(bucket, bucketSeconds) % 24).toInt())

    /**
     * The day's "calm" reference for a signal: the quartile toward the calm end (lower
     * quartile when calm is LOW, e.g. HR; upper quartile when calm is HIGH, e.g. RMSSD).
     * Falls back to the plain mean below 4 values, and to null when empty.
     */
    private fun calmReference(xs: List<Double>, calmIsLow: Boolean): Double? {
        if (xs.isEmpty()) return null
        if (xs.size < 4) return mean(xs)
        val s = xs.sorted()
        return if (calmIsLow) quantile(s, 0.25) else quantile(s, 0.75)
    }

    /** Linear-interpolated quantile of an already-sorted, non-empty list. */
    internal fun quantile(sorted: List<Double>, q: Double): Double {
        val n = sorted.size
        if (n == 0) return 0.0   // defensive: callers guard emptiness; never index []
        if (n == 1) return sorted[0]
        val pos = q * (n - 1)
        val lo = pos.toInt()
        val hi = min(lo + 1, n - 1)
        val frac = pos - lo
        return sorted[lo] + frac * (sorted[hi] - sorted[lo])
    }
}
