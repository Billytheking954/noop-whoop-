import XCTest
@testable import StrandAnalytics

final class ReliabilityCoreTests: XCTestCase {
    private func hr(_ start: Int, _ seconds: Int, _ bpm: Int, every step: Int = 10) -> [(ts: Int, bpm: Int)] {
        stride(from: start, through: start + seconds, by: step).map { ($0, bpm) }
    }

    private func recoveryRows(_ rows: [(Int, Int)], source: String = "whoop") -> [RecoveryTimedSample] {
        rows.map { RecoveryTimedSample(timestampSec: $0.0, value: $0.1, source: source) }
    }

    func testSustainedActivityWithMotionCanBeConfirmed() {
        let start = 1_000_000
        let heart = hr(start, 15 * 60, 140) + hr(start + 15 * 60 + 10, 4 * 60, 95)
        let motion = stride(from: start, through: start + 15 * 60, by: 10).map {
            AutoWorkoutDetector.MotionPoint(ts: $0, intensity: 0.12)
        }
        let out = ActivityCandidateEngine.assess(hr: heart, restingBpm: 60, motion: motion)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].state, .confirmed)
        XCTAssertEqual(out[0].activityConfidence, .high)
        XCTAssertNil(out[0].suggestedType, "Motion magnitude cannot honestly identify the sport")
    }

    func testShortHeartRateSpikeIsNotActivity() {
        let start = 2_000_000
        let heart = hr(start, 5 * 60, 145)
        XCTAssertTrue(ActivityCandidateEngine.assess(hr: heart, restingBpm: 60).isEmpty)
    }

    func testStressLikeElevationWithoutMovementIsNeverConfirmed() {
        let start = 3_000_000
        let heart = hr(start, 15 * 60, 135)
        let motion = stride(from: start, through: start + 15 * 60, by: 10).map {
            AutoWorkoutDetector.MotionPoint(ts: $0, intensity: 0.001)
        }
        let out = ActivityCandidateEngine.assess(hr: heart, restingBpm: 60, motion: motion)
        XCTAssertEqual(out.count, 1)
        XCTAssertNotEqual(out[0].state, .confirmed)
        XCTAssertTrue(out[0].evidence.contains { $0.kind == .movement && !$0.supportsActivity })
    }

    func testBriefPauseDoesNotDestroyCandidate() {
        let start = 4_000_000
        var heart = hr(start, 7 * 60, 140)
        heart += hr(start + 7 * 60 + 10, 60, 70)
        heart += hr(start + 8 * 60 + 20, 7 * 60, 140)
        let out = ActivityCandidateEngine.assess(hr: heart, restingBpm: 60)
        XCTAssertEqual(out.count, 1)
        XCTAssertGreaterThanOrEqual(out[0].durationMin, 12)
    }

    func testUnobservedGapIsDetectedAndCannotCountAsContinuousEvidence() {
        let start = 5_000_000
        let timestamps = [start, start + 10, start + 20, start + 400, start + 410]
        let gaps = SampleGapDetector.detect(timestamps: timestamps)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0].startSec, start + 20)
        XCTAssertEqual(gaps[0].endSec, start + 400)
    }

    func testCompleteHistoricalRecoveryIsIdempotent() {
        let base = 6_000_000
        let existing = recoveryRows([(base, 80), (base + 10, 82), (base + 300, 90)])
        let requested = SampleGapDetector.detect(timestamps: existing.map(\.timestampSec), gapThresholdSeconds: 120)
        let fill = recoveryRows(stride(from: base + 20, through: base + 290, by: 10).map { ($0, 85) })
        let once = HistoricalRecoveryReconciler.reconcile(existing: existing, recovered: fill,
                                                           requestedRanges: requested, gapThresholdSeconds: 120)
        XCTAssertEqual(once.ranges.first?.status, .recovered)
        XCTAssertEqual(once.quality.level, .recovered)
        let twice = HistoricalRecoveryReconciler.reconcile(existing: once.samples, recovered: fill,
                                                            requestedRanges: requested, gapThresholdSeconds: 120)
        XCTAssertEqual(twice.insertedSampleCount, 0)
        XCTAssertEqual(twice.duplicateSampleCount, fill.count)
        XCTAssertEqual(twice.samples.count, once.samples.count)
    }

    func testPartialRecoveryStaysPartial() {
        let base = 7_000_000
        let existing = recoveryRows([(base, 80), (base + 600, 90)])
        let requested = SampleGapDetector.detect(timestamps: existing.map(\.timestampSec))
        let recovered = recoveryRows([(base + 100, 84), (base + 200, 85)])
        let out = HistoricalRecoveryReconciler.reconcile(existing: existing, recovered: recovered,
                                                          requestedRanges: requested)
        XCTAssertEqual(out.ranges.first?.status, .partiallyRecovered)
        XCTAssertEqual(out.quality.level, .partial)
    }

    func testNoHistoricalDataMarksRequestedRangeUnavailable() {
        let range = MissingSampleRange(startSec: 100, endSec: 500)
        let out = HistoricalRecoveryReconciler.reconcile(existing: recoveryRows([(100, 80), (500, 90)]),
                                                          recovered: [], requestedRanges: [range])
        XCTAssertEqual(out.ranges[0].status, .unavailable)
    }

    func testOutOfOrderAndOverlappingOffloadDeduplicatesByEventIdentity() {
        let existing = [RecoveryTimedSample(timestampSec: 100, value: 70, source: "whoop")]
        let recovered = [
            RecoveryTimedSample(timestampSec: 120, value: 73, source: "whoop"),
            RecoveryTimedSample(timestampSec: 100, value: 99, source: "whoop"),
            RecoveryTimedSample(timestampSec: 110, value: 72, source: "whoop")
        ]
        let out = HistoricalRecoveryReconciler.reconcile(existing: existing, recovered: recovered, requestedRanges: [])
        XCTAssertEqual(out.samples.map(\.timestampSec), [100, 110, 120])
        XCTAssertEqual(out.samples.first?.value, 70, "Stored raw event wins an exact replay collision")
        XCTAssertEqual(out.duplicateSampleCount, 1)
    }

    func testSessionCheckpointPolicyPersistsStateChangesAndPeriodicProgress() {
        XCTAssertTrue(SessionCheckpointPolicy.shouldCheckpoint(lastPersistedSec: 100, nowSec: 101, stateChanged: true))
        XCTAssertFalse(SessionCheckpointPolicy.shouldCheckpoint(lastPersistedSec: 100, nowSec: 159, stateChanged: false))
        XCTAssertTrue(SessionCheckpointPolicy.shouldCheckpoint(lastPersistedSec: 100, nowSec: 160, stateChanged: false))
    }

    func testSessionRestorePreservesIdentityAndConsumesDelayedOffloadWithoutDuplicates() {
        let id = UUID()
        let base = 8_000_000
        let snapshot = ActiveSessionSnapshot(id: id, startSec: base, sessionType: "Hike", source: .manual,
                                             latestValidSampleSec: base + 20, accumulatedSampleCount: 3,
                                             whoopConnected: false, lastPersistedSec: base + 40)
        let existing = recoveryRows([(base, 90), (base + 10, 92), (base + 20, 95), (base + 400, 130)])
        let delayed = recoveryRows(stride(from: base + 30, through: base + 390, by: 10).map { ($0, 110) })
            + [RecoveryTimedSample(timestampSec: base + 20, value: 95, source: "whoop")]
        let out = SessionReconciler.reconcile(snapshot: snapshot, existingSamples: existing,
                                              delayedSamples: delayed, nowSec: base + 500)
        XCTAssertEqual(out.snapshot.id, id)
        XCTAssertEqual(out.duplicateSampleCount, 1)
        XCTAssertTrue(out.gaps.isEmpty)
        XCTAssertEqual(Set(out.snapshot.accumulatedSampleCount.description).isEmpty, false)
    }

    func testSessionAcrossMidnightUsesAbsoluteEventTimeNotCalendarBoundaries() {
        let start = 86_390
        let snapshot = ActiveSessionSnapshot(startSec: start, sessionType: "Activity", source: .automatic,
                                             lastPersistedSec: start)
        let rows = recoveryRows([(86_395, 100), (86_405, 105)])
        let out = SessionReconciler.reconcile(snapshot: snapshot, existingSamples: rows,
                                              delayedSamples: [], nowSec: 86_410)
        XCTAssertEqual(out.snapshot.latestValidSampleSec, 86_405)
    }

    func testAlgorithmVersionRoundTripsWithDerivedMetricProvenance() throws {
        let provenance = DerivedMetricProvenance(algorithm: ProductionAlgorithmVersions.recovery,
                                                 generatedAtSec: 12345,
                                                 quality: .init(level: .partial, reasons: ["missing HRV"] ))
        let data = try JSONEncoder().encode(provenance)
        let decoded = try JSONDecoder().decode(DerivedMetricProvenance.self, from: data)
        XCTAssertEqual(decoded, provenance)
        XCTAssertEqual(decoded.algorithm.description, "Recovery/1.0")
    }

    func testSleepTimingValidationReportsMAEAndMedianWithoutClaimingPhysiologicalAccuracy() {
        let cases = [
            SleepTimingValidationCase(referenceStartSec: 100, referenceEndSec: 500,
                                      predictedStartSec: 130, predictedEndSec: 560),
            SleepTimingValidationCase(referenceStartSec: 1000, referenceEndSec: 1500,
                                      predictedStartSec: 940, predictedEndSec: 1470)
        ]
        let m = SleepValidationMetrics.timing(cases)
        XCTAssertEqual(m.startMAESeconds, 45, accuracy: 0.001)
        XCTAssertEqual(m.endMAESeconds, 45, accuracy: 0.001)
        XCTAssertEqual(m.medianStartAbsoluteErrorSeconds, 45, accuracy: 0.001)
    }

    func testBinaryValidationMetricsExposeFalsePositivesAndFalseNegatives() {
        let m = ValidationMetrics.binary(reference: [true, true, false, false],
                                         predicted: [true, false, true, false])
        XCTAssertEqual(m.truePositive, 1)
        XCTAssertEqual(m.falsePositive, 1)
        XCTAssertEqual(m.trueNegative, 1)
        XCTAssertEqual(m.falseNegative, 1)
        XCTAssertEqual(m.precision, 0.5, accuracy: 0.001)
        XCTAssertEqual(m.recall, 0.5, accuracy: 0.001)
    }

    func testEndToEndHikeGapOffloadRestartReconciliation() {
        // Synthetic engineering fixture matching the reliability scenario. It validates state/data
        // mechanics only; it is deliberately not presented as a physiological benchmark dataset.
        let start = 10_000_000
        let disconnect = start + 8 * 60
        let reconnect = start + 14 * 60
        let end = start + 82 * 60

        let beforeGap = hr(start, 8 * 60, 132)
        let afterGap = hr(reconnect, end - reconnect, 135)
        let recoveredGap = hr(disconnect + 10, reconnect - disconnect - 20, 134)
        let allHR = beforeGap + recoveredGap + afterGap
        let motion = stride(from: start, through: end, by: 10).map {
            AutoWorkoutDetector.MotionPoint(ts: $0, intensity: 0.10)
        }
        let candidates = ActivityCandidateEngine.assess(hr: allHR, restingBpm: 60, motion: motion)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].state, .confirmed)

        let existing = recoveryRows((beforeGap + afterGap).map { ($0.ts, $0.bpm) })
        let delayed = recoveryRows(recoveredGap.map { ($0.ts, $0.bpm) })
        let gaps = SampleGapDetector.detect(timestamps: existing.map(\.timestampSec))
        XCTAssertEqual(gaps.count, 1)
        let reconciled = HistoricalRecoveryReconciler.reconcile(existing: existing, recovered: delayed,
                                                                 requestedRanges: gaps)
        XCTAssertEqual(reconciled.ranges.first?.status, .recovered)

        let sessionID = UUID()
        let killedAt = start + 30 * 60
        let snapshot = ActiveSessionSnapshot(id: sessionID, startSec: start, sessionType: "Hike",
                                             source: .automatic, latestValidSampleSec: killedAt,
                                             whoopConnected: false, lastPersistedSec: killedAt)
        let restored = SessionReconciler.reconcile(snapshot: snapshot,
                                                   existingSamples: reconciled.samples,
                                                   delayedSamples: [], nowSec: killedAt + 10 * 60)
        XCTAssertEqual(restored.snapshot.id, sessionID)
        XCTAssertEqual(restored.snapshot.latestValidSampleSec, end)
        XCTAssertTrue(restored.gaps.isEmpty)
    }
}
