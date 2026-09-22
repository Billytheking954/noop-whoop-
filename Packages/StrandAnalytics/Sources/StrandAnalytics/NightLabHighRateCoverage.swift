import Foundation

/// Coverage for high-rate signals such as IMU/gyro/optical data. The original second-resolution helper is
/// intentionally kept for existing 1 Hz-style decoded streams; this type is the canonical path whenever
/// a source can emit more than one sample per second.
public struct NightHighRateCoverageReport: Codable, Sendable, Equatable {
    public let kind: NightSignalKind
    public let sampleCount: Int
    public let windowMilliseconds: Int64
    public let expectedSamples: Int?
    public let coverageFraction: Double?
    public let largestGapMilliseconds: Int64?
    public let gapCount: Int?

    public init(kind: NightSignalKind,
                sampleCount: Int,
                windowMilliseconds: Int64,
                expectedSamples: Int?,
                coverageFraction: Double?,
                largestGapMilliseconds: Int64?,
                gapCount: Int?) {
        self.kind = kind
        self.sampleCount = sampleCount
        self.windowMilliseconds = windowMilliseconds
        self.expectedSamples = expectedSamples
        self.coverageFraction = coverageFraction
        self.largestGapMilliseconds = largestGapMilliseconds
        self.gapCount = gapCount
    }
}

public enum NightHighRateCoverage {
    /// Analyze millisecond timestamps inside `[windowStartMilliseconds, windowEndMilliseconds)`.
    ///
    /// Important: sampleCount preserves every in-window sample. Timestamps are de-duplicated only for gap
    /// geometry, not for the sample-count coverage fraction. This matters for sources whose decoder can place
    /// more than one valid sample on the same millisecond.
    public static func analyze(kind: NightSignalKind,
                               timestampsMilliseconds: [Int64],
                               windowStartMilliseconds: Int64,
                               windowEndMilliseconds: Int64,
                               expectedCadenceHz: Double? = nil) -> NightHighRateCoverageReport {
        let difference = windowEndMilliseconds.subtractingReportingOverflow(windowStartMilliseconds)
        guard !difference.overflow, difference.partialValue > 0 else {
            return NightHighRateCoverageReport(kind: kind, sampleCount: 0, windowMilliseconds: 0,
                                               expectedSamples: nil, coverageFraction: nil,
                                               largestGapMilliseconds: nil, gapCount: nil)
        }
        let durationMs = difference.partialValue
        let inWindow = timestampsMilliseconds.filter {
            $0 >= windowStartMilliseconds && $0 < windowEndMilliseconds
        }
        let orderedUnique = Array(Set(inWindow)).sorted()

        let largestGap: Int64? = {
            guard durationMs > 0 else { return nil }
            guard let first = orderedUnique.first, let last = orderedUnique.last else { return durationMs }
            var largest = max(0, first - windowStartMilliseconds)
            if orderedUnique.count > 1 {
                for i in 1..<orderedUnique.count {
                    largest = max(largest, orderedUnique[i] - orderedUnique[i - 1])
                }
            }
            largest = max(largest, windowEndMilliseconds - last)
            return largest
        }()

        guard let cadence = expectedCadenceHz,
              cadence.isFinite,
              cadence > 0,
              let expectedCount = Int(exactly: (Double(durationMs) / 1_000.0 * cadence).rounded()) else {
            return NightHighRateCoverageReport(kind: kind,
                                               sampleCount: inWindow.count,
                                               windowMilliseconds: durationMs,
                                               expectedSamples: nil,
                                               coverageFraction: nil,
                                               largestGapMilliseconds: largestGap,
                                               gapCount: nil)
        }

        let expected = max(1, expectedCount)
        let coverage = min(1.0, Double(inWindow.count) / Double(expected))
        let expectedIntervalMs = 1_000.0 / cadence
        let gapThresholdMs = expectedIntervalMs * 1.5

        var gaps = 0
        if let first = orderedUnique.first {
            if Double(first - windowStartMilliseconds) > gapThresholdMs { gaps += 1 }
            if orderedUnique.count > 1 {
                for i in 1..<orderedUnique.count
                    where Double(orderedUnique[i] - orderedUnique[i - 1]) > gapThresholdMs {
                    gaps += 1
                }
            }
            if let last = orderedUnique.last,
               Double(windowEndMilliseconds - last) > gapThresholdMs {
                gaps += 1
            }
        } else {
            gaps = 1
        }

        return NightHighRateCoverageReport(kind: kind,
                                           sampleCount: inWindow.count,
                                           windowMilliseconds: durationMs,
                                           expectedSamples: expected,
                                           coverageFraction: coverage,
                                           largestGapMilliseconds: largestGap,
                                           gapCount: gaps)
    }
}
