import XCTest
@testable import StrandAnalytics

final class NightLabDataQualityTests: XCTestCase {
    func testSummarySeparatesIntegrityAvailabilityAndAccuracy() {
        let coverage = [
            report(.heartRate, count: 100, fraction: 1, gaps: 0),
            report(.rrIntervals, count: 80, fraction: nil, gaps: nil),
            report(.accelerometer, count: 50, fraction: 0.5, gaps: 2),
            report(.respiration, count: 0, fraction: 0, gaps: 1),
            report(.wristStatus, count: 3, fraction: nil, gaps: nil),
        ]

        let summary = NightDataQualitySummary(coverage: coverage,
                                              archiveIntegrityVerified: true,
                                              hasSavedSleepResult: true)

        XCTAssertTrue(summary.archiveIntegrityVerified)
        XCTAssertEqual(summary.signals.map(\.availability), [
            .complete, .completenessUnknown, .partial, .unavailable, .completenessUnknown,
        ])
        XCTAssertEqual(summary.savedResultEvidence, .limited)
        XCTAssertEqual(summary.limitingSignals, [.accelerometer, .respiration])
        XCTAssertEqual(summary.unknownCompletenessSignals, [.rrIntervals])
    }

    func testUnknownCadenceNeverBecomesCompleteFromRowPresence() {
        let summary = NightDataQualitySummary(
            coverage: [report(.rrIntervals, count: 25, fraction: nil, gaps: nil)],
            archiveIntegrityVerified: true,
            hasSavedSleepResult: true
        )

        XCTAssertEqual(summary.signals.first?.availability, .completenessUnknown)
        XCTAssertEqual(summary.savedResultEvidence, .completenessUnknown)
    }

    func testNoBaselineDoesNotClaimResultQuality() {
        let coverage = [
            report(.heartRate, count: 10, fraction: 0.2, gaps: 3),
            report(.accelerometer, count: 0, fraction: 0, gaps: 1),
        ]

        let summary = NightDataQualitySummary(coverage: coverage,
                                              archiveIntegrityVerified: true,
                                              hasSavedSleepResult: false)

        XCTAssertEqual(summary.savedResultEvidence, .noSavedResult)
        XCTAssertEqual(summary.limitingSignals, [.heartRate, .accelerometer])
    }

    private func report(_ kind: NightSignalKind,
                        count: Int,
                        fraction: Double?,
                        gaps: Int?) -> NightSignalCoverageReport {
        NightSignalCoverageReport(kind: kind,
                                  sampleCount: count,
                                  windowSeconds: 100,
                                  expectedSamples: fraction == nil ? nil : 100,
                                  coverageFraction: fraction,
                                  largestGapSeconds: gaps == nil ? nil : 10,
                                  gapCount: gaps)
    }
}
