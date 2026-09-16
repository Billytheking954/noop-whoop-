import Foundation
import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class StressSignalQualityTests: XCTestCase {
    private let start = 10_000
    private let end = 13_600

    private func sample(_ timestamp: Int,
                        value: Double? = 70,
                        source: String = "native",
                        quality: StressSignalSample.Quality = .valid,
                        missing: Bool = false,
                        duration: Int? = nil) -> StressSignalSample {
        StressSignalSample(timestamp: timestamp, value: value, durationSeconds: duration,
                           source: source, provenance: "fixture", quality: quality,
                           isMissing: missing)
    }

    private func distributed(source: String = "native") -> [StressSignalSample] {
        stride(from: start, to: end, by: 60).map { sample($0, source: source, duration: 60) }
    }

    func testSparseHighCountBurstFailsMaximumGap() {
        let burst = (0..<300).map { sample(start + $0) }
        let decision = StressTemporalQuality.evaluate(samples: burst, windowStart: start,
                                                      windowEnd: end, baselineReady: true)
        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.validSampleCount, 300)
        XCTAssertEqual(decision.validDurationSeconds, 300)
        XCTAssertEqual(decision.rejectionReasons, [.maximumGapExceeded])
    }

    func testLowCountEvenlyDistributedSamplesPass() {
        let decision = StressTemporalQuality.evaluate(samples: distributed(), windowStart: start,
                                                      windowEnd: end, baselineReady: true)
        XCTAssertTrue(decision.accepted)
        XCTAssertEqual(decision.validSampleCount, 60)
        XCTAssertGreaterThan(decision.coveragePercentage, 98)
        XCTAssertEqual(decision.maximumGapSeconds, 0)
        XCTAssertEqual(decision.configurationVersion, "stress-temporal-v1")
    }

    func testOneExcessiveGapFails() {
        let holed = distributed().filter { !((start + 1_200)..<(start + 2_400)).contains($0.timestamp) }
        let decision = StressTemporalQuality.evaluate(samples: holed, windowStart: start,
                                                      windowEnd: end, baselineReady: true)
        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.rejectionReasons, [.maximumGapExceeded])
        XCTAssertGreaterThan(decision.maximumGapSeconds,
                             StressQualityConfiguration.daytimeV1.maximumGapSeconds)
    }

    func testDuplicatesCollapseWithoutInflatingCoverage() {
        let base = distributed()
        let duplicated = base + base.map { sample($0.timestamp, value: 90, source: "imported") }
        let decision = StressTemporalQuality.evaluate(samples: duplicated, windowStart: start,
                                                      windowEnd: end, baselineReady: true)
        XCTAssertTrue(decision.accepted)
        XCTAssertEqual(decision.validSampleCount, base.count)
        XCTAssertEqual(decision.duplicateTimestampCount, base.count)
        XCTAssertTrue(decision.diagnostics.contains(.duplicateTimestamps))
        XCTAssertEqual(StressTemporalQuality.canonicalMean(samples: duplicated,
                                                           windowStart: start, windowEnd: end), 80)
    }

    func testOutOfOrderInputSortsDeterministically() {
        let ordered = distributed()
        let shuffled = Array(ordered.reversed())
        let a = StressTemporalQuality.evaluate(samples: ordered, windowStart: start,
                                               windowEnd: end, baselineReady: true)
        let b = StressTemporalQuality.evaluate(samples: shuffled, windowStart: start,
                                               windowEnd: end, baselineReady: true)
        XCTAssertEqual(a.accepted, b.accepted)
        XCTAssertEqual(a.coveragePercentage, b.coveragePercentage)
        XCTAssertEqual(a.maximumGapSeconds, b.maximumGapSeconds)
        XCTAssertTrue(b.diagnostics.contains(.outOfOrderInput))
        XCTAssertEqual(StressTemporalQuality.canonicalMean(samples: ordered,
                                                           windowStart: start, windowEnd: end),
                       StressTemporalQuality.canonicalMean(samples: shuffled,
                                                           windowStart: start, windowEnd: end))
    }

    func testIrregularSamplingPassesWhenCoverageAndGapsPass() {
        var timestamps: [Int] = []
        var t = start
        let gaps = [15, 45, 30, 60]
        var i = 0
        while t < end {
            timestamps.append(t)
            t += gaps[i % gaps.count]
            i += 1
        }
        let decision = StressTemporalQuality.evaluate(samples: timestamps.map { sample($0, duration: 60) }, windowStart: start,
                                                      windowEnd: end, baselineReady: true)
        XCTAssertTrue(decision.accepted)
        XCTAssertLessThanOrEqual(decision.maximumGapSeconds, 60)
    }

    func testUnknownDurationNeverBorrowsTheNextSampleInterval() {
        let six = stride(from: start, to: end, by: 600).map { sample($0) }
        let decision = StressTemporalQuality.evaluate(samples: six, windowStart: start,
                                                      windowEnd: end, baselineReady: true)
        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.validDurationSeconds, six.count)
        XCTAssertTrue(decision.rejectionReasons.contains(.insufficientTemporalCoverage))
    }

    func testExplicitDurationIsCapped() {
        let decision = StressTemporalQuality.evaluate(
            samples: [sample(start, duration: 3_600)], windowStart: start,
            windowEnd: end, baselineReady: true
        )
        XCTAssertEqual(decision.validDurationSeconds,
                       StressQualityConfiguration.daytimeV1.maximumCreditedIntervalSeconds)
        XCTAssertFalse(decision.accepted)
    }

    func testExactCoverageAndMaximumGapThresholdsAreInclusive() {
        let rows = [
            sample(start, duration: 60), sample(start + 900, duration: 60),
            sample(start + 1_800, duration: 60), sample(start + 2_700, duration: 60),
            sample(end - 60, duration: 60),
        ]
        let decision = StressTemporalQuality.evaluate(samples: rows, windowStart: start,
                                                      windowEnd: end, baselineReady: true)
        XCTAssertTrue(decision.accepted)
        XCTAssertEqual(decision.validDurationSeconds, 300)
        XCTAssertEqual(decision.maximumGapSeconds, 840)
    }

    func testInvalidAndOverflowingWindowsRejectWithoutTrapping() {
        for bounds in [(end, start), (start, start), (Int.min, Int.max)] {
            let decision = StressTemporalQuality.evaluate(samples: [], windowStart: bounds.0,
                                                          windowEnd: bounds.1, baselineReady: true)
            XCTAssertFalse(decision.accepted)
            XCTAssertTrue(decision.rejectionReasons.contains(.invalidWindow))
        }
    }

    func testCanonicalMeanWeightsExplicitDurations() {
        let rows = [sample(start, value: 60, duration: 60),
                    sample(start + 60, value: 120, duration: 30)]
        XCTAssertEqual(StressTemporalQuality.canonicalMean(samples: rows, windowStart: start,
                                                           windowEnd: start + 90), 80)
    }

    func testMissingInvalidAndRejectedDurationAreExplicit() {
        let unusable = [
            sample(start, value: nil, missing: true, duration: 10),
            sample(start + 30, value: Double.nan, duration: 5),
            sample(start + 60, quality: .rejected, duration: 20),
        ]
        let decision = StressTemporalQuality.evaluate(samples: unusable, windowStart: start,
                                                      windowEnd: end, baselineReady: true)
        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.validDurationSeconds, 0)
        XCTAssertEqual(decision.rejectedDurationSeconds, 35)
        XCTAssertEqual(decision.rejectedSampleCount, 3)
        XCTAssertTrue(decision.diagnostics.contains(.rejectedSamples))
        XCTAssertEqual(decision.rejectionReasons,
                       [.noValidSamples, .insufficientTemporalCoverage, .maximumGapExceeded])
    }

    func testHalfOpenBoundaryExcludesWindowEnd() {
        let rows = [sample(start), sample(end - 1), sample(end)]
        let decision = StressTemporalQuality.evaluate(samples: rows, windowStart: start,
                                                      windowEnd: end, baselineReady: true)
        XCTAssertEqual(decision.validSampleCount, 2)
    }

    func testBaselineWarmupRejectsOtherwiseUsableSignal() {
        let decision = StressTemporalQuality.evaluate(samples: distributed(), windowStart: start,
                                                      windowEnd: end, baselineReady: false)
        XCTAssertFalse(decision.accepted)
        XCTAssertEqual(decision.rejectionReasons, [.baselineNotReady])
        XCTAssertFalse(decision.baselineReady)
    }

    func testImportedAndNativeProvenanceDoesNotChangeDecision() {
        let native = distributed(source: "native")
        let imported = distributed(source: "imported")
        XCTAssertEqual(
            StressTemporalQuality.evaluate(samples: native, windowStart: start, windowEnd: end,
                                           baselineReady: true),
            StressTemporalQuality.evaluate(samples: imported, windowStart: start, windowEnd: end,
                                           baselineReady: true)
        )
    }

    func testFutureSamplesCannotChangeEarlierDecision() {
        let original = distributed()
        let future = (0..<300).reversed().map { sample(end + 10_000 + $0, value: 220) }
        XCTAssertEqual(
            StressTemporalQuality.evaluate(samples: original, windowStart: start, windowEnd: end,
                                           baselineReady: true),
            StressTemporalQuality.evaluate(samples: original + future, windowStart: start, windowEnd: end,
                                           baselineReady: true)
        )
    }

    func testParticipantAndHoldoutEvaluationsHaveNoSharedState() {
        let participantA = distributed()
        let participantB = (0..<300).map { sample(start + $0, value: 110, source: "holdout-b") }
        let firstA = StressTemporalQuality.evaluate(samples: participantA, windowStart: start,
                                                    windowEnd: end, baselineReady: true)
        _ = StressTemporalQuality.evaluate(samples: participantB, windowStart: start,
                                           windowEnd: end, baselineReady: true)
        let secondA = StressTemporalQuality.evaluate(samples: participantA, windowStart: start,
                                                     windowEnd: end, baselineReady: true)
        XCTAssertEqual(firstA, secondA)
        XCTAssertTrue(firstA.accepted)
    }

    func testRepeatedReplayIsDeterministic() {
        let rows = distributed()
        let first = StressTemporalQuality.evaluate(samples: rows, windowStart: start,
                                                   windowEnd: end, baselineReady: true)
        for _ in 0..<20 {
            XCTAssertEqual(StressTemporalQuality.evaluate(samples: rows, windowStart: start,
                                                          windowEnd: end, baselineReady: true), first)
        }
    }

    func testLocalHourAcrossLondonDSTUsesTheCorrectOffset() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        for components in [
            DateComponents(year: 2026, month: 3, day: 29, hour: 7),
            DateComponents(year: 2026, month: 10, day: 25, hour: 7),
        ] {
            let date = try XCTUnwrap(calendar.date(from: components))
            let startTs = Int(date.timeIntervalSince1970)
            let offset = zone.secondsFromGMT(for: date)
            let hr = (0..<3_600).map { HRSample(ts: startTs + $0, bpm: 70) }
            let result = DaytimeStress.analyze(hr: hr, rr: [], tzOffsetSeconds: offset)
            let hour = try XCTUnwrap(result.hours.first(where: { $0.hour == 7 }))
            XCTAssertTrue(hour.quality?.accepted == true)
        }
    }
}
