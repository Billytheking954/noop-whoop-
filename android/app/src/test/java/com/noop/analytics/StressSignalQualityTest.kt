package com.noop.analytics

import com.noop.data.HrSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId
import java.time.ZonedDateTime

class StressSignalQualityTest {
    private val start = 10_000L
    private val end = 13_600L

    private fun sample(
        timestamp: Long,
        value: Double? = 70.0,
        source: String = "native",
        quality: StressSignalSample.Quality = StressSignalSample.Quality.VALID,
        missing: Boolean = false,
        duration: Long? = null,
    ) = StressSignalSample(timestamp, value, duration, source, "fixture", quality, missing)

    private fun distributed(source: String = "native") =
        (start until end step 60L).map { sample(it, source = source, duration = 60L) }

    @Test fun sparseHighCountBurstFailsMaximumGap() {
        val burst = (0 until 300).map { sample(start + it) }
        val decision = StressTemporalQuality.evaluate(burst, start, end, true)
        assertFalse(decision.accepted)
        assertEquals(300, decision.validSampleCount)
        assertEquals(300L, decision.validDurationSeconds)
        assertEquals(listOf(StressQualityRejectionReason.MAXIMUM_GAP_EXCEEDED), decision.rejectionReasons)
    }

    @Test fun lowCountEvenlyDistributedSamplesPass() {
        val decision = StressTemporalQuality.evaluate(distributed(), start, end, true)
        assertTrue(decision.accepted)
        assertEquals(60, decision.validSampleCount)
        assertTrue(decision.coveragePercentage > 98.0)
        assertEquals(0L, decision.maximumGapSeconds)
        assertEquals("stress-temporal-v1", decision.configurationVersion)
    }

    @Test fun oneExcessiveGapFails() {
        val holed = distributed().filter { it.timestamp !in (start + 1_200) until (start + 2_400) }
        val decision = StressTemporalQuality.evaluate(holed, start, end, true)
        assertEquals(listOf(StressQualityRejectionReason.MAXIMUM_GAP_EXCEEDED), decision.rejectionReasons)
        assertTrue(decision.maximumGapSeconds > StressQualityConfiguration.DAYTIME_V1.maximumGapSeconds)
    }

    @Test fun duplicatesCollapseWithoutInflatingCoverage() {
        val base = distributed()
        val duplicated = base + base.map { sample(it.timestamp, 90.0, "imported") }
        val decision = StressTemporalQuality.evaluate(duplicated, start, end, true)
        assertTrue(decision.accepted)
        assertEquals(base.size, decision.validSampleCount)
        assertEquals(base.size, decision.duplicateTimestampCount)
        assertTrue(StressQualityDiagnostic.DUPLICATE_TIMESTAMPS in decision.diagnostics)
        assertEquals(80.0, StressTemporalQuality.canonicalMean(duplicated, start, end) ?: 0.0, 0.0)
    }

    @Test fun outOfOrderInputSortsDeterministically() {
        val ordered = distributed()
        val shuffled = ordered.reversed()
        val a = StressTemporalQuality.evaluate(ordered, start, end, true)
        val b = StressTemporalQuality.evaluate(shuffled, start, end, true)
        assertEquals(a.accepted, b.accepted)
        assertEquals(a.coveragePercentage, b.coveragePercentage, 0.0)
        assertEquals(a.maximumGapSeconds, b.maximumGapSeconds)
        assertTrue(StressQualityDiagnostic.OUT_OF_ORDER_INPUT in b.diagnostics)
        assertEquals(StressTemporalQuality.canonicalMean(ordered, start, end),
            StressTemporalQuality.canonicalMean(shuffled, start, end))
    }

    @Test fun irregularSamplingPassesWhenCoverageAndGapsPass() {
        val timestamps = ArrayList<Long>()
        val gaps = listOf(15L, 45L, 30L, 60L)
        var t = start
        var i = 0
        while (t < end) { timestamps += t; t += gaps[i++ % gaps.size] }
        val decision = StressTemporalQuality.evaluate(
            timestamps.map { sample(it, duration = 60L) }, start, end, true)
        assertTrue(decision.accepted)
        assertTrue(decision.maximumGapSeconds <= 60L)
    }

    @Test fun unknownDurationNeverBorrowsTheNextSampleInterval() {
        val six = (start until end step 600L).map(::sample)
        val decision = StressTemporalQuality.evaluate(six, start, end, true)
        assertFalse(decision.accepted)
        assertEquals(six.size.toLong(), decision.validDurationSeconds)
        assertTrue(StressQualityRejectionReason.INSUFFICIENT_TEMPORAL_COVERAGE in decision.rejectionReasons)
    }

    @Test fun explicitDurationIsCapped() {
        val decision = StressTemporalQuality.evaluate(
            listOf(sample(start, duration = 3_600L)), start, end, true,
        )
        assertEquals(StressQualityConfiguration.DAYTIME_V1.maximumCreditedIntervalSeconds,
            decision.validDurationSeconds)
        assertFalse(decision.accepted)
    }

    @Test fun exactCoverageAndMaximumGapThresholdsAreInclusive() {
        val rows = listOf(
            sample(start, duration = 60L), sample(start + 900L, duration = 60L),
            sample(start + 1_800L, duration = 60L), sample(start + 2_700L, duration = 60L),
            sample(end - 60L, duration = 60L),
        )
        val decision = StressTemporalQuality.evaluate(rows, start, end, true)
        assertTrue(decision.accepted)
        assertEquals(300L, decision.validDurationSeconds)
        assertEquals(840L, decision.maximumGapSeconds)
    }

    @Test fun invalidAndOverflowingWindowsRejectWithoutWrapping() {
        for ((windowStart, windowEnd) in listOf(end to start, start to start,
            Long.MIN_VALUE to Long.MAX_VALUE)) {
            val decision = StressTemporalQuality.evaluate(emptyList(), windowStart, windowEnd, true)
            assertFalse(decision.accepted)
            assertTrue(StressQualityRejectionReason.INVALID_WINDOW in decision.rejectionReasons)
        }
    }

    @Test fun canonicalMeanWeightsExplicitDurations() {
        val rows = listOf(sample(start, 60.0, duration = 60L),
            sample(start + 60L, 120.0, duration = 30L))
        assertEquals(80.0, StressTemporalQuality.canonicalMean(rows, start, start + 90L) ?: 0.0, 0.0)
    }

    @Test fun missingInvalidAndRejectedDurationAreExplicit() {
        val unusable = listOf(
            sample(start, null, missing = true, duration = 10),
            sample(start + 30, Double.NaN, duration = 5),
            sample(start + 60, quality = StressSignalSample.Quality.REJECTED, duration = 20),
        )
        val decision = StressTemporalQuality.evaluate(unusable, start, end, true)
        assertFalse(decision.accepted)
        assertEquals(0L, decision.validDurationSeconds)
        assertEquals(35L, decision.rejectedDurationSeconds)
        assertEquals(3, decision.rejectedSampleCount)
        assertTrue(StressQualityDiagnostic.REJECTED_SAMPLES in decision.diagnostics)
        assertEquals(listOf(
            StressQualityRejectionReason.NO_VALID_SAMPLES,
            StressQualityRejectionReason.INSUFFICIENT_TEMPORAL_COVERAGE,
            StressQualityRejectionReason.MAXIMUM_GAP_EXCEEDED,
        ), decision.rejectionReasons)
    }

    @Test fun halfOpenBoundaryExcludesWindowEnd() {
        val rows = listOf(sample(start), sample(end - 1), sample(end))
        val decision = StressTemporalQuality.evaluate(rows, start, end, true)
        assertEquals(2, decision.validSampleCount)
    }

    @Test fun baselineWarmupRejectsOtherwiseUsableSignal() {
        val decision = StressTemporalQuality.evaluate(distributed(), start, end, false)
        assertEquals(listOf(StressQualityRejectionReason.BASELINE_NOT_READY), decision.rejectionReasons)
        assertFalse(decision.baselineReady)
    }

    @Test fun importedAndNativeProvenanceDoesNotChangeDecision() {
        assertEquals(
            StressTemporalQuality.evaluate(distributed("native"), start, end, true),
            StressTemporalQuality.evaluate(distributed("imported"), start, end, true),
        )
    }

    @Test fun futureSamplesCannotChangeEarlierDecision() {
        val original = distributed()
        val future = (0 until 300).reversed().map { sample(end + 10_000 + it, 220.0) }
        assertEquals(StressTemporalQuality.evaluate(original, start, end, true),
            StressTemporalQuality.evaluate(original + future, start, end, true))
    }

    @Test fun participantAndHoldoutEvaluationsHaveNoSharedState() {
        val participantA = distributed()
        val participantB = (0 until 300).map { sample(start + it, 110.0, "holdout-b") }
        val firstA = StressTemporalQuality.evaluate(participantA, start, end, true)
        StressTemporalQuality.evaluate(participantB, start, end, true)
        val secondA = StressTemporalQuality.evaluate(participantA, start, end, true)
        assertEquals(firstA, secondA)
        assertTrue(firstA.accepted)
    }

    @Test fun repeatedReplayIsDeterministic() {
        val rows = distributed()
        val first = StressTemporalQuality.evaluate(rows, start, end, true)
        repeat(20) { assertEquals(first, StressTemporalQuality.evaluate(rows, start, end, true)) }
    }

    @Test fun localHourAcrossLondonDstUsesTheCorrectOffset() {
        val zone = ZoneId.of("Europe/London")
        for (date in listOf(
            ZonedDateTime.of(2026, 3, 29, 7, 0, 0, 0, zone),
            ZonedDateTime.of(2026, 10, 25, 7, 0, 0, 0, zone),
        )) {
            val startTs = date.toEpochSecond()
            val hr = (0 until 3_600).map { HrSample("t", startTs + it, 70) }
            val result = DaytimeStress.analyze(hr, emptyList(),
                tzOffsetSeconds = date.offset.totalSeconds.toLong())
            assertTrue(result.hours.first { it.hour == 7 }.quality?.accepted == true)
        }
    }
}
