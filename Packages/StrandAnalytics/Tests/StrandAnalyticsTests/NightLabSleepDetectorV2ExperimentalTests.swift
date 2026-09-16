import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class NightLabSleepDetectorV2ExperimentalTests: XCTestCase {
    private let referenceMidnight = 1_749_513_600 // 2026-06-10 00:00:00 UTC

    private struct Signals {
        var hr: [HRSample]
        var gravity: [GravitySample]
    }

    private func hr(start: Int, duration: Int, bpm: Int, step: Int = 5) -> [HRSample] {
        stride(from: 0, to: duration, by: step).map {
            HRSample(ts: start + $0, bpm: bpm)
        }
    }

    private func gravity(start: Int,
                         duration: Int,
                         active: Bool,
                         step: Int = 5) -> [GravitySample] {
        stride(from: 0, to: duration, by: step).map { offset in
            let sampleIndex = offset / step
            let x = active ? (sampleIndex.isMultiple(of: 2) ? 0.0 : 0.4) : 0.0
            return GravitySample(ts: start + offset, x: x, y: 0, z: 1)
        }
    }

    private func episode(sleepStart: Int,
                         sleepDuration: Int,
                         preWake: Int = 30 * 60,
                         postWake: Int = 30 * 60,
                         awakeHR: Int = 75,
                         sleepHR: Int = 50,
                         step: Int = 5) -> Signals {
        let start = sleepStart - preWake
        let end = sleepStart + sleepDuration
        return Signals(
            hr: hr(start: start, duration: preWake, bpm: awakeHR, step: step)
                + hr(start: sleepStart, duration: sleepDuration, bpm: sleepHR, step: step)
                + hr(start: end, duration: postWake, bpm: awakeHR, step: step),
            gravity: gravity(start: start, duration: preWake, active: true, step: step)
                + gravity(start: sleepStart, duration: sleepDuration, active: false, step: step)
                + gravity(start: end, duration: postWake, active: true, step: step)
        )
    }

    private func interleaved<T>(_ values: [T]) -> [T] {
        stride(from: 0, to: values.count, by: 2).map { values[$0] }
            + stride(from: 1, to: values.count, by: 2).map { values[$0] }
    }

    func testIndependentDetectorHasIndependentIdentityAndDetectsCalibratedSleep() throws {
        let start = referenceMidnight + 23 * 3_600 + 30 * 60
        let signals = episode(sleepStart: start, sleepDuration: 7 * 3_600 + 45 * 60)

        let result = NightLabSleepDetectorV2.detectIndependentCandidates(
            hr: signals.hr,
            gravity: signals.gravity
        )

        XCTAssertEqual(result.status, .detected)
        XCTAssertNil(result.blocker)
        XCTAssertEqual(result.provenance.algorithmID, "nightlab.sleep-detection-v2-independent")
        XCTAssertEqual(result.provenance.algorithmVersion, "0.2.0-motion-hr-shadow")
        XCTAssertEqual(result.provenance.candidateSource, "nightlab.motion-hr-window-v1")
        let primary = try XCTUnwrap(result.primaryBoundary)
        XCTAssertEqual(primary.start, start)
        XCTAssertEqual(primary.end, start + 7 * 3_600 + 45 * 60)
    }

    func testInputOrderDoesNotChangeIndependentResult() {
        let start = referenceMidnight + 23 * 3_600 + 30 * 60
        let signals = episode(sleepStart: start, sleepDuration: 7 * 3_600)
        let ordered = NightLabSleepDetectorV2.detectIndependentCandidates(
            hr: signals.hr,
            gravity: signals.gravity
        )
        let reordered = NightLabSleepDetectorV2.detectIndependentCandidates(
            hr: interleaved(signals.hr),
            gravity: interleaved(signals.gravity)
        )

        XCTAssertEqual(reordered, ordered)
    }

    func testExactDuplicatePacketsDoNotMoveIndependentBoundaries() {
        let start = referenceMidnight + 23 * 3_600 + 30 * 60
        let signals = episode(sleepStart: start, sleepDuration: 7 * 3_600)
        let clean = NightLabSleepDetectorV2.detectIndependentCandidates(
            hr: signals.hr,
            gravity: signals.gravity
        )
        let duplicated = NightLabSleepDetectorV2.detectIndependentCandidates(
            hr: signals.hr + [signals.hr[100], signals.hr[100], signals.hr[400]],
            gravity: signals.gravity + [signals.gravity[100], signals.gravity[100], signals.gravity[400]]
        )

        XCTAssertEqual(duplicated.candidates, clean.candidates)
        XCTAssertEqual(duplicated.primaryBoundary, clean.primaryBoundary)
    }

    func testCrossMidnightSleepRemainsOneCandidate() throws {
        let start = referenceMidnight + 23 * 3_600 + 30 * 60
        let midnight = referenceMidnight + 24 * 3_600
        let signals = episode(sleepStart: start, sleepDuration: 7 * 3_600 + 45 * 60)
        let result = NightLabSleepDetectorV2.detectIndependentCandidates(
            hr: signals.hr,
            gravity: signals.gravity
        )

        XCTAssertEqual(result.candidates.count, 1)
        let primary = try XCTUnwrap(result.primaryBoundary)
        XCTAssertLessThan(primary.start, midnight)
        XCTAssertGreaterThan(primary.end, midnight)
    }

    func testVeryLateAndEarlySleepDoNotDependOnClockBand() throws {
        let lateStart = referenceMidnight + 27 * 3_600 // 03:00 next day
        let late = episode(sleepStart: lateStart, sleepDuration: 8 * 3_600)
        let lateResult = NightLabSleepDetectorV2.detectIndependentCandidates(
            hr: late.hr,
            gravity: late.gravity,
            tzOffsetSeconds: 9 * 3_600
        )
        XCTAssertEqual(try XCTUnwrap(lateResult.primaryBoundary).start, lateStart)

        let earlyStart = referenceMidnight + 20 * 3_600 + 30 * 60
        let early = episode(sleepStart: earlyStart, sleepDuration: 8 * 3_600)
        let earlyResult = NightLabSleepDetectorV2.detectIndependentCandidates(
            hr: early.hr,
            gravity: early.gravity,
            tzOffsetSeconds: -8 * 3_600
        )
        XCTAssertEqual(try XCTUnwrap(earlyResult.primaryBoundary).start, earlyStart)
    }

    func testSedentaryDaytimeLikeWindowWithoutHRDipIsRejected() {
        let start = referenceMidnight + 13 * 3_600
        let signals = episode(
            sleepStart: start,
            sleepDuration: 3 * 3_600,
            awakeHR: 72,
            sleepHR: 72
        )
        let result = NightLabSleepDetectorV2.detectIndependentCandidates(
            hr: signals.hr,
            gravity: signals.gravity
        )

        XCTAssertEqual(result.status, .noPlausibleSleep)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertTrue(result.diagnostics.contains {
            $0.rejectionReasons.contains(.insufficientHeartRateDip)
        })
    }

    func testMovieGamingStudyingPatternIsNotSleepFromStillnessAlone() {
        let start = referenceMidnight + 19 * 3_600
        let signals = episode(
            sleepStart: start,
            sleepDuration: 4 * 3_600,
            awakeHR: 78,
            sleepHR: 77
        )
        let result = NightLabSleepDetectorV2.detectIndependentCandidates(
            hr: signals.hr,
            gravity: signals.gravity
        )

        XCTAssertEqual(result.status, .noPlausibleSleep)
        XCTAssertNil(result.primaryBoundary)
    }

    func testLongWristOffOverlapRejectsOtherwiseSleepLikeCandidate() {
        let start = referenceMidnight + 23 * 3_600
        let duration = 7 * 3_600
        let signals = episode(sleepStart: start, sleepDuration: duration)
        let result = NightLabSleepDetectorV2.detectIndependentCandidates(
            hr: signals.hr,
            gravity: signals.gravity,
            wristOffIntervals: [(start: start + 60 * 60, end: start + 5 * 60 * 60)]
        )

        XCTAssertEqual(result.status, .noPlausibleSleep)
        XCTAssertTrue(result.diagnostics.contains {
            $0.rejectionReasons.contains(.excessiveWristOff)
        })
    }

    func testMissingAccelerometerIsExplicitlyInsufficient() {
        let start = referenceMidnight + 23 * 3_600
        let result = NightLabSleepDetectorV2.detectIndependentCandidates(
            hr: hr(start: start, duration: 8 * 3_600, bpm: 50),
            gravity: []
        )

        XCTAssertEqual(result.status, .insufficientEvidence)
        XCTAssertEqual(result.blocker, .missingGravity)
    }

    func testMissingHeartRateIsExplicitlyInsufficient() {
        let start = referenceMidnight + 23 * 3_600
        let result = NightLabSleepDetectorV2.detectIndependentCandidates(
            hr: [],
            gravity: gravity(start: start, duration: 8 * 3_600, active: false)
        )

        XCTAssertEqual(result.status, .insufficientEvidence)
        XCTAssertEqual(result.blocker, .missingHeartRate)
    }

    func testUniformStillnessWithoutWakeCalibrationDoesNotBecomeAutomaticSleep() {
        let start = referenceMidnight + 23 * 3_600
        let result = NightLabSleepDetectorV2.detectIndependentCandidates(
            hr: hr(start: start, duration: 8 * 3_600, bpm: 50),
            gravity: gravity(start: start, duration: 8 * 3_600, active: false)
        )

        XCTAssertEqual(result.status, .insufficientEvidence)
        XCTAssertEqual(result.blocker, .noMotionContrast)
    }

    func testShortNapCanBeRepresentedWhenEvidenceSupportsIt() throws {
        let start = referenceMidnight + 14 * 3_600
        let signals = episode(sleepStart: start, sleepDuration: 30 * 60)
        let result = NightLabSleepDetectorV2.detectIndependentCandidates(
            hr: signals.hr,
            gravity: signals.gravity
        )

        XCTAssertEqual(result.status, .detected)
        let primary = try XCTUnwrap(result.primaryBoundary)
        XCTAssertEqual(primary.start, start)
        XCTAssertEqual(primary.durationSeconds, 30 * 60)
    }

    func testTwoSleepCandidatesStaySeparateAndPrimarySelectionIsDeterministic() throws {
        let firstStart = referenceMidnight + 22 * 3_600
        let firstDuration = 60 * 60
        let wakeDuration = 30 * 60
        let secondStart = firstStart + firstDuration + wakeDuration
        let secondDuration = 90 * 60
        let preStart = firstStart - 30 * 60
        let postStart = secondStart + secondDuration

        let signals = Signals(
            hr: hr(start: preStart, duration: 30 * 60, bpm: 75)
                + hr(start: firstStart, duration: firstDuration, bpm: 50)
                + hr(start: firstStart + firstDuration, duration: wakeDuration, bpm: 75)
                + hr(start: secondStart, duration: secondDuration, bpm: 50)
                + hr(start: postStart, duration: 30 * 60, bpm: 75),
            gravity: gravity(start: preStart, duration: 30 * 60, active: true)
                + gravity(start: firstStart, duration: firstDuration, active: false)
                + gravity(start: firstStart + firstDuration, duration: wakeDuration, active: true)
                + gravity(start: secondStart, duration: secondDuration, active: false)
                + gravity(start: postStart, duration: 30 * 60, active: true)
        )

        let result = NightLabSleepDetectorV2.detectIndependentCandidates(
            hr: signals.hr,
            gravity: signals.gravity
        )
        let reversed = NightLabSleepDetectorV2.detectIndependentCandidates(
            hr: Array(signals.hr.reversed()),
            gravity: Array(signals.gravity.reversed())
        )

        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(result, reversed)
        XCTAssertEqual(try XCTUnwrap(result.primaryBoundary).start, secondStart)
    }

    func testTwentyFourHourShiftPreservesIndependentStructure() throws {
        let start = referenceMidnight + 23 * 3_600 + 30 * 60
        let duration = 7 * 3_600
        let shift = 24 * 3_600
        let base = episode(sleepStart: start, sleepDuration: duration)
        let shifted = episode(sleepStart: start + shift, sleepDuration: duration)

        let baseResult = NightLabSleepDetectorV2.detectIndependentCandidates(
            hr: base.hr,
            gravity: base.gravity
        )
        let shiftedResult = NightLabSleepDetectorV2.detectIndependentCandidates(
            hr: shifted.hr,
            gravity: shifted.gravity
        )
        let basePrimary = try XCTUnwrap(baseResult.primaryBoundary)
        let shiftedPrimary = try XCTUnwrap(shiftedResult.primaryBoundary)

        XCTAssertEqual(shiftedPrimary.start - basePrimary.start, shift)
        XCTAssertEqual(shiftedPrimary.end - basePrimary.end, shift)
        XCTAssertEqual(shiftedPrimary.durationSeconds, basePrimary.durationSeconds)
    }

    func testBenignSamplingDensityChangeDoesNotSwingBoundaries() {
        let start = referenceMidnight + 23 * 3_600 + 30 * 60
        let duration = 7 * 3_600
        let dense = episode(sleepStart: start, sleepDuration: duration, step: 5)
        let sparser = episode(sleepStart: start, sleepDuration: duration, step: 10)

        let denseResult = NightLabSleepDetectorV2.detectIndependentCandidates(
            hr: dense.hr,
            gravity: dense.gravity
        )
        let sparseResult = NightLabSleepDetectorV2.detectIndependentCandidates(
            hr: sparser.hr,
            gravity: sparser.gravity
        )

        XCTAssertEqual(denseResult.candidates, sparseResult.candidates)
        XCTAssertEqual(denseResult.primaryBoundary, sparseResult.primaryBoundary)
    }

    func testMissingAccelerometerGapBreaksRatherThanMasqueradingAsStillness() {
        let start = referenceMidnight + 22 * 3_600
        let firstSleep = 90 * 60
        let missing = 30 * 60
        let secondSleep = 90 * 60
        let pre = 30 * 60
        let post = 30 * 60
        let secondStart = start + firstSleep + missing
        let end = secondStart + secondSleep

        let signals = Signals(
            hr: hr(start: start - pre, duration: pre, bpm: 75)
                + hr(start: start, duration: firstSleep + missing + secondSleep, bpm: 50)
                + hr(start: end, duration: post, bpm: 75),
            gravity: gravity(start: start - pre, duration: pre, active: true)
                + gravity(start: start, duration: firstSleep, active: false)
                + gravity(start: secondStart, duration: secondSleep, active: false)
                + gravity(start: end, duration: post, active: true)
        )

        let result = NightLabSleepDetectorV2.detectIndependentCandidates(
            hr: signals.hr,
            gravity: signals.gravity
        )

        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertFalse(result.candidates.contains { $0.start <= start && $0.end >= end })
    }

    func testNonFiniteOnlyGravityIsInvalidEvidence() {
        let start = referenceMidnight + 23 * 3_600
        let result = NightLabSleepDetectorV2.detectIndependentCandidates(
            hr: hr(start: start, duration: 60 * 60, bpm: 50),
            gravity: [
                GravitySample(ts: start, x: .nan, y: 0, z: 1),
                GravitySample(ts: start + 5, x: .infinity, y: 0, z: 1),
            ]
        )

        XCTAssertEqual(result.status, .invalidEvidence)
        XCTAssertEqual(result.blocker, .invalidGravity)
    }

    func testShadowComparisonMeasuresDisagreementWithoutDeclaringWinner() {
        let start = referenceMidnight + 23 * 3_600 + 30 * 60
        let signals = episode(sleepStart: start, sleepDuration: 7 * 3_600)
        let comparison = NightLabSleepDetectorV2.shadowCompare(
            hr: signals.hr,
            gravity: signals.gravity
        )

        XCTAssertEqual(comparison.v2.provenance.candidateSource, "nightlab.motion-hr-window-v1")
        XCTAssertEqual(comparison.v2.status, .detected)
        if comparison.v1.status == .detected {
            XCTAssertNotNil(comparison.startDifferenceSeconds)
            XCTAssertNotNil(comparison.endDifferenceSeconds)
            XCTAssertNotNil(comparison.durationDifferenceSeconds)
        }
    }
}
