import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class NightLabSleepDetectorV2Tests: XCTestCase {
    private let referenceMidnight = 1_749_513_600 // 2026-06-10 00:00:00 UTC

    private func stillGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1.0) }
    }

    private func activeGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { index in
            let x = Double(index % 2) * 0.5
            return GravitySample(ts: start + index, x: x, y: 0, z: 1.0)
        }
    }

    private func hrStream(start: Int, durationS: Int, bpm: Int) -> [HRSample] {
        (0..<durationS).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    private func interleaved<T>(_ values: [T]) -> [T] {
        var result: [T] = []
        result.reserveCapacity(values.count)
        result.append(contentsOf: stride(from: 0, to: values.count, by: 2).map { values[$0] })
        result.append(contentsOf: stride(from: 1, to: values.count, by: 2).map { values[$0] })
        return result
    }

    private func manifest(id: String,
                          state: NightRecordState,
                          start: Int,
                          end: Int,
                          timezoneOffsetSeconds: Int) -> NightRecordManifest {
        NightRecordManifest(nightID: id,
                            state: state,
                            windowStartUnix: start,
                            windowEndUnix: end,
                            timezoneOffsetSeconds: timezoneOffsetSeconds,
                            sourceDeviceID: "phase2-test-source",
                            sourceDeviceModel: "WHOOP 5.0",
                            sourceStoreSchemaVersion: 18,
                            sourceStreamFingerprint: "phase2-source-fingerprint",
                            noopVersion: "test",
                            rawAssets: [])
    }

    func testEmptyEvidenceIsExplicitlyInsufficient() {
        let result = NightLabSleepDetectorV2.detect(hr: [], gravity: [])
        XCTAssertEqual(result.status, .insufficientEvidence)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertNil(result.primaryBoundary)
    }

    func testBootstrapBoundaryMatchesExistingV1Detector() {
        let start = referenceMidnight + 2 * 3_600
        let duration = 90 * 60
        let gravity = stillGravity(start: start, durationS: duration)
        let hr = hrStream(start: start, durationS: duration, bpm: 50)

        let legacy = SleepStager.detectSleep(hr: hr, gravity: gravity)
        let result = NightLabSleepDetectorV2.detect(hr: hr, gravity: gravity)
        let expected = legacy.map {
            NightLabSleepDetectorV2.CandidateBoundary(start: $0.start, end: $0.end, hrOnly: $0.hrOnly)
        }

        XCTAssertEqual(result.status, .detected)
        XCTAssertEqual(result.candidates, NightLabSleepDetectorV2.canonicalBoundaries(expected))
        XCTAssertEqual(result.provenance.candidateSource, NightLabSleepDetectorV2.candidateSource)
    }

    func testReverseOrderedEvidenceProducesIdenticalResult() {
        let start = referenceMidnight + 2 * 3_600
        let duration = 90 * 60
        let gravity = stillGravity(start: start, durationS: duration)
        let hr = hrStream(start: start, durationS: duration, bpm: 50)

        let ordered = NightLabSleepDetectorV2.detect(hr: hr, gravity: gravity)
        let reversed = NightLabSleepDetectorV2.detect(hr: Array(hr.reversed()),
                                                       gravity: Array(gravity.reversed()))
        XCTAssertEqual(reversed, ordered)
    }

    func testDeterministicPermutationProducesIdenticalResult() {
        let start = referenceMidnight + 3 * 3_600
        let duration = 75 * 60
        let gravity = stillGravity(start: start, durationS: duration)
        let hr = hrStream(start: start, durationS: duration, bpm: 51)

        let ordered = NightLabSleepDetectorV2.detect(hr: hr, gravity: gravity)
        let permuted = NightLabSleepDetectorV2.detect(hr: interleaved(hr),
                                                       gravity: interleaved(gravity))
        XCTAssertEqual(permuted, ordered)
    }

    func testExactDuplicateTimestampsDoNotChangeDetectedBoundaries() {
        let start = referenceMidnight + 2 * 3_600
        let duration = 90 * 60
        let gravity = stillGravity(start: start, durationS: duration)
        let hr = hrStream(start: start, durationS: duration, bpm: 50)

        let clean = NightLabSleepDetectorV2.detect(hr: hr, gravity: gravity)
        let duplicated = NightLabSleepDetectorV2.detect(
            hr: hr + [hr[120], hr[120], hr[900]],
            gravity: gravity + [gravity[120], gravity[120], gravity[900]])

        XCTAssertEqual(duplicated.candidates, clean.candidates)
        XCTAssertEqual(duplicated.evidence.duplicateHRTimestampsRemoved, 3)
        XCTAssertEqual(duplicated.evidence.duplicateGravityTimestampsRemoved, 3)
        XCTAssertTrue(duplicated.warnings.contains(.duplicateHRTimestampsCanonicalized))
        XCTAssertTrue(duplicated.warnings.contains(.duplicateGravityTimestampsCanonicalized))
    }

    func testCrossMidnightSleepIsNotSplitAtCalendarBoundary() throws {
        let start = referenceMidnight + 23 * 3_600
        let midnight = referenceMidnight + 24 * 3_600
        let duration = 90 * 60
        let result = NightLabSleepDetectorV2.detect(
            hr: hrStream(start: start, durationS: duration, bpm: 50),
            gravity: stillGravity(start: start, durationS: duration))

        XCTAssertEqual(result.status, .detected)
        let primary = try XCTUnwrap(result.primaryBoundary)
        XCTAssertLessThan(primary.start, midnight)
        XCTAssertGreaterThan(primary.end, midnight)
    }

    func testShortStillBoutIsNoPlausibleSleepRatherThanFabricatedSession() {
        let start = referenceMidnight + 2 * 3_600
        let duration = 30 * 60
        let result = NightLabSleepDetectorV2.detect(
            hr: hrStream(start: start, durationS: duration, bpm: 50),
            gravity: stillGravity(start: start, durationS: duration))

        XCTAssertEqual(result.status, .noPlausibleSleep)
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testSedentaryDaytimeWindowKeepsExistingFalsePositiveGuard() {
        let activeStart = referenceMidnight + 10 * 3_600
        let activeDuration = 3 * 60 * 60
        let stillStart = activeStart + activeDuration
        let stillDuration = 70 * 60

        let result = NightLabSleepDetectorV2.detect(
            hr: hrStream(start: activeStart, durationS: activeDuration, bpm: 72)
                + hrStream(start: stillStart, durationS: stillDuration, bpm: 50),
            gravity: activeGravity(start: activeStart, durationS: activeDuration)
                + stillGravity(start: stillStart, durationS: stillDuration))

        XCTAssertEqual(result.status, .noPlausibleSleep)
    }

    func testMajorExplicitWristOffCoverageStillBlocksCandidate() {
        let start = referenceMidnight + 2 * 3_600
        let duration = 90 * 60
        let result = NightLabSleepDetectorV2.detect(
            hr: hrStream(start: start, durationS: duration, bpm: 50),
            gravity: stillGravity(start: start, durationS: duration),
            wristOffIntervals: [(start: start + 5 * 60, end: start + duration)])

        XCTAssertEqual(result.status, .noPlausibleSleep)
        XCTAssertEqual(result.evidence.explicitWristOffIntervalCount, 1)
    }

    func testGapDiagnosticsArePerSignalAndDoNotInventCoverage() {
        let config = NightLabSleepDetectorV2.Configuration(diagnosticGapSeconds: 60)
        let hr = [HRSample(ts: 1_000, bpm: 55), HRSample(ts: 1_121, bpm: 55)]
        let gravity = [
            GravitySample(ts: 1_000, x: 0, y: 0, z: 1),
            GravitySample(ts: 1_030, x: 0, y: 0, z: 1),
        ]
        let result = NightLabSleepDetectorV2.detect(hr: hr, gravity: gravity, configuration: config)

        XCTAssertEqual(result.evidence.hrGaps.gapCount, 1)
        XCTAssertEqual(result.evidence.hrGaps.largestGapSeconds, 121)
        XCTAssertEqual(result.evidence.gravityGaps.gapCount, 0)
        XCTAssertEqual(result.evidence.gravityGaps.largestGapSeconds, 30)
        XCTAssertTrue(result.warnings.contains(.largeHRGap))
        XCTAssertFalse(result.warnings.contains(.largeGravityGap))
    }

    func testNonFiniteGravityFailsSafeWhenItIsTheOnlyDetectorEvidence() {
        let gravity = [GravitySample(ts: 1_000, x: .nan, y: 0, z: 1)]
        let result = NightLabSleepDetectorV2.detect(hr: [], gravity: gravity)

        XCTAssertEqual(result.status, .invalidEvidence)
        XCTAssertEqual(result.evidence.rejectedNonFiniteGravitySamples, 1)
        XCTAssertTrue(result.warnings.contains(.nonFiniteGravityRejected))
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testPrimarySelectionIsDeterministicAndPrefersLongestCandidate() {
        let candidates = [
            NightLabSleepDetectorV2.CandidateBoundary(start: 500, end: 1_100, hrOnly: false),
            NightLabSleepDetectorV2.CandidateBoundary(start: 100, end: 1_100, hrOnly: true),
            NightLabSleepDetectorV2.CandidateBoundary(start: 200, end: 1_200, hrOnly: false),
        ]
        // Equal 1000-second longest candidates tie-break to the earlier start.
        XCTAssertEqual(NightLabSleepDetectorV2.selectPrimary(from: candidates), candidates[1])
        XCTAssertEqual(NightLabSleepDetectorV2.selectPrimary(from: Array(candidates.reversed())), candidates[1])
    }

    func testTwentyFourHourTimeShiftPreservesRelativeBoundary() throws {
        let start = referenceMidnight + 2 * 3_600
        let duration = 90 * 60
        let shift = 24 * 3_600
        let base = NightLabSleepDetectorV2.detect(
            hr: hrStream(start: start, durationS: duration, bpm: 50),
            gravity: stillGravity(start: start, durationS: duration))
        let shifted = NightLabSleepDetectorV2.detect(
            hr: hrStream(start: start + shift, durationS: duration, bpm: 50),
            gravity: stillGravity(start: start + shift, durationS: duration))

        let basePrimary = try XCTUnwrap(base.primaryBoundary)
        let shiftedPrimary = try XCTUnwrap(shifted.primaryBoundary)
        XCTAssertEqual(shiftedPrimary.start - basePrimary.start, shift)
        XCTAssertEqual(shiftedPrimary.end - basePrimary.end, shift)
        XCTAssertEqual(shiftedPrimary.durationSeconds, basePrimary.durationSeconds)
    }

    func testArchiveUsesManifestTimezoneAndCarriesProvenance() {
        let start = referenceMidnight + 2 * 3_600
        let duration = 70 * 60
        let archived = NightLabArchivedStreams(
            manifest: manifest(id: "timezone-night",
                               state: .sealed,
                               start: start,
                               end: start + duration,
                               timezoneOffsetSeconds: 10 * 3_600),
            hr: hrStream(start: start, durationS: duration, bpm: 50),
            rr: [],
            gravity: stillGravity(start: start, durationS: duration),
            respiration: [],
            wristStatus: [])

        // Same absolute evidence: +10 h places the session center in the stricter daytime band.
        let manifestTimezone = NightLabSleepDetectorV2.detect(streams: archived)
        XCTAssertEqual(manifestTimezone.status, .noPlausibleSleep)
        XCTAssertEqual(manifestTimezone.provenance.timezoneOffsetSeconds, 10 * 3_600)
        XCTAssertEqual(manifestTimezone.provenance.nightID, "timezone-night")
        XCTAssertEqual(manifestTimezone.provenance.sourceStreamFingerprint, "phase2-source-fingerprint")
        XCTAssertEqual(manifestTimezone.provenance.archiveWindowStartUnix, start)
        XCTAssertEqual(manifestTimezone.provenance.archiveWindowEndUnix, start + duration)

        // Controlled override back to UTC makes the same 70-min evidence an overnight candidate.
        let utcOverride = NightLabSleepDetectorV2.detect(streams: archived, tzOffsetSeconds: 0)
        XCTAssertEqual(utcOverride.status, .detected)
        XCTAssertEqual(utcOverride.provenance.timezoneOffsetSeconds, 0)
    }

    func testUnsealedArchiveIsRejectedEvenWhenStreamsAreConstructedDirectly() {
        let start = referenceMidnight + 2 * 3_600
        let duration = 90 * 60
        let archived = NightLabArchivedStreams(
            manifest: manifest(id: "recording-night",
                               state: .recording,
                               start: start,
                               end: start + duration,
                               timezoneOffsetSeconds: 0),
            hr: hrStream(start: start, durationS: duration, bpm: 50),
            rr: [],
            gravity: stillGravity(start: start, durationS: duration),
            respiration: [],
            wristStatus: [])

        let result = NightLabSleepDetectorV2.detect(streams: archived)
        XCTAssertEqual(result.status, .invalidEvidence)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertNil(result.primaryBoundary)
        XCTAssertTrue(result.warnings.contains(.unsealedArchiveRejected))
    }

    func testWristIntervalsAreSortedMergedAndInvalidIntervalsDropped() {
        let normalized = NightLabSleepDetectorV2.normalizeWristOffIntervals([
            (start: 30, end: 40),
            (start: 10, end: 20),
            (start: 18, end: 35),
            (start: 80, end: 70),
            (start: 40, end: 45),
        ])
        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(normalized[0].start, 10)
        XCTAssertEqual(normalized[0].end, 45)
    }

    func testConfigurationAndImplementationIdentityAreStableAndExplicit() {
        let config = NightLabSleepDetectorV2.Configuration(diagnosticGapSeconds: 321)
        let result = NightLabSleepDetectorV2.detect(hr: [], gravity: [], configuration: config)

        XCTAssertEqual(result.provenance.algorithmID, "nightlab.sleep-detection-v2")
        XCTAssertEqual(result.provenance.algorithmVersion, "0.1.0-bootstrap-v1-spine")
        XCTAssertEqual(result.provenance.candidateSource, "SleepStager.detectSleep.stage0-v1")
        XCTAssertEqual(result.provenance.timezoneOffsetSeconds, 0)
        XCTAssertTrue(result.provenance.configurationIdentity.contains("diagnostic-gap=321s"))
    }
}
