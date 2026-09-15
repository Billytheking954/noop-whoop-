package com.noop.analytics

data class StressSignalSample(
    val timestamp: Long,
    val value: Double?,
    val durationSeconds: Long? = null,
    val source: String,
    val provenance: String? = null,
    val quality: Quality,
    val isMissing: Boolean = false,
    val activityContext: ActivityContext = ActivityContext.UNKNOWN,
) {
    enum class Quality { VALID, REJECTED, UNKNOWN }
    enum class ActivityContext { UNKNOWN, RESTING, ACTIVE }
}

enum class StressQualityRejectionReason(val wire: String) {
    INVALID_WINDOW("invalid_window"),
    NO_VALID_SAMPLES("no_valid_samples"),
    INSUFFICIENT_TEMPORAL_COVERAGE("insufficient_temporal_coverage"),
    MAXIMUM_GAP_EXCEEDED("maximum_gap_exceeded"),
    BASELINE_NOT_READY("baseline_not_ready"),
}

enum class StressQualityDiagnostic(val wire: String) {
    DUPLICATE_TIMESTAMPS("duplicate_timestamps"),
    OUT_OF_ORDER_INPUT("out_of_order_input"),
    REJECTED_SAMPLES("rejected_samples"),
}

data class StressQualityConfiguration(
    val version: String,
    val minimumCoverageFraction: Double,
    val minimumValidDurationSeconds: Long,
    val maximumGapSeconds: Long,
    val maximumCreditedIntervalSeconds: Long,
    val nominalSampleDurationSeconds: Long,
) {
    companion object {
        val DAYTIME_V1 = StressQualityConfiguration(
            version = "stress-temporal-v1",
            minimumCoverageFraction = 300.0 / 3_600.0,
            minimumValidDurationSeconds = 300L,
            maximumGapSeconds = 15 * 60L,
            maximumCreditedIntervalSeconds = 60L,
            nominalSampleDurationSeconds = 1L,
        )
    }
}

data class StressQualityDecision(
    val accepted: Boolean,
    val coveragePercentage: Double,
    val maximumGapSeconds: Long,
    val validDurationSeconds: Long,
    val rejectedDurationSeconds: Long,
    val windowDurationSeconds: Long,
    val baselineReady: Boolean,
    val rejectionReasons: List<StressQualityRejectionReason>,
    val diagnostics: List<StressQualityDiagnostic>,
    val validSampleCount: Int,
    val rejectedSampleCount: Int,
    val duplicateTimestampCount: Int,
    val configurationVersion: String,
) {
    fun withBaselineReadiness(ready: Boolean): StressQualityDecision {
        val reasons = rejectionReasons.filterNot {
            it == StressQualityRejectionReason.BASELINE_NOT_READY
        }.toMutableList()
        if (!ready) reasons += StressQualityRejectionReason.BASELINE_NOT_READY
        return copy(accepted = reasons.isEmpty(), baselineReady = ready, rejectionReasons = reasons)
    }
}

object StressTemporalQuality {
    private data class CanonicalSample(val timestamp: Long, val value: Double, val durationSeconds: Long?)
    private data class Interval(val start: Long, val endExclusive: Long)

    fun evaluate(
        samples: List<StressSignalSample>,
        windowStart: Long,
        windowEnd: Long,
        baselineReady: Boolean,
        configuration: StressQualityConfiguration = StressQualityConfiguration.DAYTIME_V1,
    ): StressQualityDecision {
        val validWindow = windowEnd > windowStart &&
            !(windowStart < 0L && windowEnd > Long.MAX_VALUE + windowStart)
        val windowDuration = if (validWindow) windowEnd - windowStart else 0L
        val inWindow = samples.filter { it.timestamp >= windowStart && it.timestamp < windowEnd }
        val outOfOrder = inWindow.zipWithNext().any { (a, b) -> a.timestamp > b.timestamp }
        val duplicateCount = inWindow.size - inWindow.map { it.timestamp }.toSet().size
        val canonical = canonicalValidSamples(inWindow)
        val invalid = inWindow.filterNot(::isValid)
        val validIntervals = representedIntervals(canonical, windowStart, windowEnd, configuration)
        val rejectedIntervals = invalid.mapNotNull { sample ->
            if (windowDuration <= 0L) return@mapNotNull null
            val duration = minOf(
                sample.durationSeconds?.takeIf { it > 0L }
                    ?: configuration.nominalSampleDurationSeconds,
                configuration.maximumCreditedIntervalSeconds,
            )
            val end = minOf(windowEnd, safeAdd(sample.timestamp, duration.coerceAtLeast(0L)))
            if (end > sample.timestamp) Interval(sample.timestamp, end) else null
        }
        val validDuration = unionDuration(validIntervals)
        val rejectedDuration = unionDuration(rejectedIntervals)
        val maxGap = if (windowDuration > 0L) maximumGap(validIntervals, windowStart, windowEnd) else 0L
        val coverage = if (windowDuration > 0L) validDuration.toDouble() / windowDuration else 0.0

        val reasons = buildList {
            if (windowDuration <= 0L) add(StressQualityRejectionReason.INVALID_WINDOW)
            if (canonical.isEmpty()) add(StressQualityRejectionReason.NO_VALID_SAMPLES)
            if (windowDuration > 0L && (validDuration < configuration.minimumValidDurationSeconds ||
                    coverage + 1e-12 < configuration.minimumCoverageFraction)) {
                add(StressQualityRejectionReason.INSUFFICIENT_TEMPORAL_COVERAGE)
            }
            if (windowDuration > 0L && maxGap > configuration.maximumGapSeconds) {
                add(StressQualityRejectionReason.MAXIMUM_GAP_EXCEEDED)
            }
            if (!baselineReady) add(StressQualityRejectionReason.BASELINE_NOT_READY)
        }
        val diagnostics = buildList {
            if (duplicateCount > 0) add(StressQualityDiagnostic.DUPLICATE_TIMESTAMPS)
            if (outOfOrder) add(StressQualityDiagnostic.OUT_OF_ORDER_INPUT)
            if (invalid.isNotEmpty()) add(StressQualityDiagnostic.REJECTED_SAMPLES)
        }
        return StressQualityDecision(
            accepted = reasons.isEmpty(),
            coveragePercentage = coverage * 100.0,
            maximumGapSeconds = maxGap,
            validDurationSeconds = validDuration,
            rejectedDurationSeconds = rejectedDuration,
            windowDurationSeconds = windowDuration,
            baselineReady = baselineReady,
            rejectionReasons = reasons,
            diagnostics = diagnostics,
            validSampleCount = canonical.size,
            rejectedSampleCount = invalid.size,
            duplicateTimestampCount = duplicateCount,
            configurationVersion = configuration.version,
        )
    }

    fun canonicalMean(
        samples: List<StressSignalSample>, windowStart: Long, windowEnd: Long,
        configuration: StressQualityConfiguration = StressQualityConfiguration.DAYTIME_V1,
    ): Double? {
        val canonical = canonicalValidSamples(
            samples.filter { it.timestamp >= windowStart && it.timestamp < windowEnd },
        )
        var weighted = 0.0
        var duration = 0L
        for ((index, sample) in canonical.withIndex()) {
            val credit = minOf(sample.durationSeconds ?: configuration.nominalSampleDurationSeconds,
                configuration.maximumCreditedIntervalSeconds)
            val next = if (index + 1 < canonical.size) canonical[index + 1].timestamp else windowEnd
            val end = minOf(windowEnd, next, safeAdd(sample.timestamp, credit.coerceAtLeast(0L)))
            val seconds = (end - maxOf(windowStart, sample.timestamp)).coerceAtLeast(0L)
            weighted += sample.value * seconds
            duration += seconds
        }
        return if (duration > 0L) weighted / duration else null
    }

    private fun isValid(sample: StressSignalSample): Boolean =
        sample.quality == StressSignalSample.Quality.VALID && !sample.isMissing &&
            sample.value?.isFinite() == true && (sample.durationSeconds == null || sample.durationSeconds > 0L)

    private fun canonicalValidSamples(samples: List<StressSignalSample>): List<CanonicalSample> =
        samples.filter(::isValid).groupBy { it.timestamp }.toSortedMap().map { (timestamp, group) ->
            val values = group.mapNotNull { it.value }.sorted()
            CanonicalSample(timestamp, values.sum() / values.size, group.mapNotNull { it.durationSeconds }.maxOrNull())
        }

    private fun representedIntervals(
        samples: List<CanonicalSample>,
        windowStart: Long,
        windowEnd: Long,
        configuration: StressQualityConfiguration,
    ): List<Interval> {
        if (windowEnd <= windowStart) return emptyList()
        return samples.mapIndexedNotNull { index, sample ->
            val duration = minOf(
                sample.durationSeconds ?: configuration.nominalSampleDurationSeconds,
                configuration.maximumCreditedIntervalSeconds,
            )
            val start = maxOf(windowStart, sample.timestamp)
            val next = if (index + 1 < samples.size) samples[index + 1].timestamp else windowEnd
            val end = minOf(windowEnd, next, safeAdd(sample.timestamp, duration.coerceAtLeast(0L)))
            if (end > start) Interval(start, end) else null
        }
    }

    private fun unionDuration(intervals: List<Interval>): Long {
        val ordered = intervals.sortedBy { it.start }
        if (ordered.isEmpty()) return 0L
        var current = ordered.first()
        var total = 0L
        for (interval in ordered.drop(1)) {
            if (interval.start <= current.endExclusive) {
                current = Interval(current.start, maxOf(current.endExclusive, interval.endExclusive))
            } else {
                total += current.endExclusive - current.start
                current = interval
            }
        }
        return total + current.endExclusive - current.start
    }

    private fun maximumGap(intervals: List<Interval>, windowStart: Long, windowEnd: Long): Long {
        if (windowEnd <= windowStart) return 0L
        val ordered = intervals.sortedBy { it.start }
        if (ordered.isEmpty()) return windowEnd - windowStart
        var current = ordered.first()
        var largest = (current.start - windowStart).coerceAtLeast(0L)
        for (interval in ordered.drop(1)) {
            if (interval.start > current.endExclusive) {
                largest = maxOf(largest, interval.start - current.endExclusive)
                current = interval
            } else if (interval.endExclusive > current.endExclusive) {
                current = Interval(current.start, interval.endExclusive)
            }
        }
        return maxOf(largest, windowEnd - current.endExclusive)
    }

    private fun safeAdd(value: Long, positiveDelta: Long): Long =
        if (value > Long.MAX_VALUE - positiveDelta) Long.MAX_VALUE else value + positiveDelta
}
