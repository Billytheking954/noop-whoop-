package com.noop.ui

import com.noop.data.DailyMetric
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * StressModel.build carry (#543). The Today "Stress" metric derives against a 30-day RHR/HRV baseline.
 * Today's own daily row is often vitals-less until the overnight is analyzed (especially right after an
 * app update relaunches and re-runs the analyze pass), and every OTHER Today vital carries last night's
 * value — Stress used to be the one card that didn't, so it dropped to "Calibrating" while the rest showed
 * numbers. These pin the carry: score the newest day that actually has RHR/HRV. Twin of the Swift
 * StressModelCarryTests.
 */
class StressModelTest {

    private fun day(d: String, rhr: Int?, hrv: Double?) =
        DailyMetric(deviceId = "my-whoop", day = d, restingHr = rhr, avgHrv = hrv)

    // 31 days that all carry RHR + HRV: a full 30-day baseline plus one more scorable day.
    private val baseline = (1..30).map { day("2026-06-%02d".format(it), rhr = 55, hrv = 60.0) } +
        day("2026-07-01", rhr = 55, hrv = 60.0)

    @Test
    fun vitalsLessTodayCarriesInsteadOfCalibrating() {
        // Control: today HAS vitals -> builds (unchanged behaviour).
        assertNotNull(StressModel.build(baseline + day("2026-07-02", rhr = 58, hrv = 45.0), emptyMap()))
        // The fix: today has NO RHR/HRV yet (the post-update window) but a prior day does -> carries, not null.
        assertNotNull(
            "a vitals-less today must carry the last day with RHR/HRV, not calibrate",
            StressModel.build(baseline + day("2026-07-02", rhr = null, hrv = null), emptyMap()),
        )
    }

    @Test
    fun noVitalsAnywhereStillCalibrates() {
        // Genuine cold start: no day has RHR/HRV and nothing stored -> honestly calibrating (null).
        val days = (1..5).map { day("2026-07-0$it", rhr = null, hrv = null) }
        assertNull(StressModel.build(days, emptyMap()))
    }

    @Test
    fun storedStressOnLatestVitalsLessDayIsUsedNotSkipped() {
        // An imported latest day carries a STORED vendor stress value but no RHR/HRV (e.g. a Xiaomi /
        // Garmin export). The original gate honoured it; the carry must NOT skip it back to an older vitals
        // day. The stored 2.5 must win over any derived carry.
        val days = baseline + day("2026-07-02", rhr = null, hrv = null)
        val model = StressModel.build(days, mapOf("2026-07-02" to 2.5))
        assertNotNull(model)
        assertEquals("the latest day's stored stress must win over a carry", 2.5, model!!.score, 0.001)
    }

    @Test
    fun storedFallbackIsClampedToSharedScale() {
        val days = listOf(day("2026-07-02", rhr = null, hrv = null))
        assertEquals(3.0, StressModel.build(days, mapOf("2026-07-02" to 99.0))!!.score, 0.0)
    }

    @Test
    fun storedStressCannotOverrideDerivableImportedOrNativeVitals() {
        val days = baseline + day("2026-07-02", rhr = 58, hrv = 45.0)
        val native = StressModel.build(days, emptyMap())!!
        val importedWithLegacyStoredRow = StressModel.build(days, mapOf("2026-07-02" to 0.0))!!
        assertEquals(native.score, importedWithLegacyStoredRow.score, 0.0)
        assertFalse(importedWithLegacyStoredRow.usingStored)
        assertEquals("stress-daily-v2", native.algorithmVersion)
        assertEquals("trailing-mean-sd-30d-causal-v1", native.baselineVersion)
    }

    @Test
    fun futureDaysCannotChangeAnEarlierHistoricalScore() {
        val history = (1..6).map { day("2026-06-0$it", 50 + it, 72.0 - it * 2) }
        val target = day("2026-06-07", 61, 48.0)
        val before = StressModel.build(history + target, emptyMap())!!
        val after = StressModel.build(history + listOf(
            target, day("2026-06-08", 120, 5.0), day("2026-06-09", 35, 250.0),
        ), emptyMap())!!
        val beforeValue = before.fullTrend.first { it.day == "2026-06-07" }.value
        val afterValue = after.fullTrend.first { it.day == "2026-06-07" }.value
        assertEquals("future observations leaked into the target baseline", beforeValue, afterValue, 0.0)
    }

    @Test
    fun targetDayIsExcludedFromItsOwnBaseline() {
        val history = (1..6).map { day("2026-06-0$it", 50 + it, 72.0 - it * 2) }
        val calm = StressModel.build(history + day("2026-06-07", 58, 58.0), emptyMap())!!
        val extreme = StressModel.build(history + day("2026-06-07", 118, 8.0), emptyMap())!!
        assertEquals(58.0 - calm.rhrDelta!!, 118.0 - extreme.rhrDelta!!, 0.0)
        assertEquals(58.0 - calm.hrvDelta!!, 8.0 - extreme.hrvDelta!!, 0.0)
    }

    @Test
    fun outOfOrderReplayMatchesChronologicalInput() {
        val ordered = (1..9).map { day("2026-06-0$it", 50 + it, 75.0 - it * 2) }
        val chronological = StressModel.build(ordered, emptyMap())!!
        val replayed = StressModel.build(
            listOf(ordered[7], ordered[1], ordered[8], ordered[0], ordered[5],
                   ordered[3], ordered[6], ordered[2], ordered[4]),
            emptyMap(),
        )!!
        assertEquals(chronological.score, replayed.score, 0.0)
        assertEquals(chronological.fullTrend, replayed.fullTrend)
    }

    @Test
    fun rebuildFromPersistedInputsMatchesUninterruptedExecution() {
        val persistedPrefix = (1..7).map { day("2026-06-0$it", 50 + it, 75.0 - it * 2) }
        val continuation = listOf(
            day("2026-06-08", 59, 55.0),
            day("2026-06-09", 61, 51.0),
        )
        StressModel.build(persistedPrefix, emptyMap())
        val uninterrupted = StressModel.build(persistedPrefix + continuation, emptyMap())!!
        val afterRestart = StressModel.build(persistedPrefix + continuation, emptyMap())!!

        assertEquals(uninterrupted.score, afterRestart.score, 0.0)
        assertEquals(uninterrupted.fullTrend, afterRestart.fullTrend)
    }
}
