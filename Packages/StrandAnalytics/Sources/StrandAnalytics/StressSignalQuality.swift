import Foundation

/// One source-normalized observation presented to the stress quality gate. Source-specific decoders
/// populate provenance and missingness; the quality engine deliberately ignores provenance when deciding
/// acceptance so equivalent imported, native, and replay samples produce identical results.
public struct StressSignalSample: Codable, Equatable, Sendable {
    public enum Quality: String, Codable, Sendable {
        case valid
        case rejected
        case unknown
    }

    public enum ActivityContext: String, Codable, Sendable {
        case unknown
        case resting
        case active
    }

    public let timestamp: Int
    public let value: Double?
    public let durationSeconds: Int?
    public let source: String
    public let provenance: String?
    public let quality: Quality
    public let isMissing: Bool
    public let activityContext: ActivityContext

    public init(timestamp: Int,
                value: Double?,
                durationSeconds: Int? = nil,
                source: String,
                provenance: String? = nil,
                quality: Quality,
                isMissing: Bool = false,
                activityContext: ActivityContext = .unknown) {
        self.timestamp = timestamp
        self.value = value
        self.durationSeconds = durationSeconds
        self.source = source
        self.provenance = provenance
        self.quality = quality
        self.isMissing = isMissing
        self.activityContext = activityContext
    }
}

public enum StressQualityRejectionReason: String, Codable, Sendable, CaseIterable {
    case invalidWindow = "invalid_window"
    case noValidSamples = "no_valid_samples"
    case insufficientTemporalCoverage = "insufficient_temporal_coverage"
    case maximumGapExceeded = "maximum_gap_exceeded"
    case baselineNotReady = "baseline_not_ready"
}

public enum StressQualityDiagnostic: String, Codable, Sendable, CaseIterable {
    case duplicateTimestamps = "duplicate_timestamps"
    case outOfOrderInput = "out_of_order_input"
    case rejectedSamples = "rejected_samples"
}

/// Versioned, engineering-only signal requirements. These are not physiological coefficients.
public struct StressQualityConfiguration: Codable, Equatable, Sendable {
    public let version: String
    public let minimumCoverageFraction: Double
    public let minimumValidDurationSeconds: Int
    public let maximumGapSeconds: Int
    public let maximumCreditedIntervalSeconds: Int
    public let nominalSampleDurationSeconds: Int

    public init(version: String,
                minimumCoverageFraction: Double,
                minimumValidDurationSeconds: Int,
                maximumGapSeconds: Int,
                maximumCreditedIntervalSeconds: Int,
                nominalSampleDurationSeconds: Int) {
        self.version = version
        self.minimumCoverageFraction = minimumCoverageFraction
        self.minimumValidDurationSeconds = minimumValidDurationSeconds
        self.maximumGapSeconds = maximumGapSeconds
        self.maximumCreditedIntervalSeconds = maximumCreditedIntervalSeconds
        self.nominalSampleDurationSeconds = nominalSampleDurationSeconds
    }

    /// Keeps the previous five-minutes-per-hour evidence floor (300 seconds / 3,600 seconds), but unlike
    /// the old count rule it rejects a five-minute burst followed by a long hole. Explicit decoder-supplied
    /// durations may represent at most one minute; an observation with no duration earns only the nominal
    /// one second, so the gate never fabricates coverage from an unknown sampling interval.
    public static let daytimeV1 = StressQualityConfiguration(
        version: "stress-temporal-v1",
        minimumCoverageFraction: 300.0 / 3_600.0,
        minimumValidDurationSeconds: 300,
        maximumGapSeconds: 15 * 60,
        maximumCreditedIntervalSeconds: 60,
        nominalSampleDurationSeconds: 1
    )
}

public struct StressQualityDecision: Codable, Equatable, Sendable {
    public let accepted: Bool
    public let coveragePercentage: Double
    public let maximumGapSeconds: Int
    public let validDurationSeconds: Int
    public let rejectedDurationSeconds: Int
    public let windowDurationSeconds: Int
    public let baselineReady: Bool
    public let rejectionReasons: [StressQualityRejectionReason]
    public let diagnostics: [StressQualityDiagnostic]
    public let validSampleCount: Int
    public let rejectedSampleCount: Int
    public let duplicateTimestampCount: Int
    public let configurationVersion: String

    /// Twin of Kotlin `StressQualityDecision.withBaselineReadiness`.
    /// Attach causal baseline readiness without changing the signal evidence already measured for
    /// the window. Baseline rejection is always the final reason, preserving deterministic ordering.
    public func withBaselineReadiness(_ ready: Bool) -> StressQualityDecision {
        var reasons = rejectionReasons.filter { $0 != .baselineNotReady }
        if !ready { reasons.append(.baselineNotReady) }
        return StressQualityDecision(
            accepted: reasons.isEmpty, coveragePercentage: coveragePercentage,
            maximumGapSeconds: maximumGapSeconds, validDurationSeconds: validDurationSeconds,
            rejectedDurationSeconds: rejectedDurationSeconds, windowDurationSeconds: windowDurationSeconds,
            baselineReady: ready, rejectionReasons: reasons, diagnostics: diagnostics,
            validSampleCount: validSampleCount, rejectedSampleCount: rejectedSampleCount,
            duplicateTimestampCount: duplicateTimestampCount, configurationVersion: configurationVersion
        )
    }
}

public enum StressTemporalQuality {
    private struct CanonicalSample {
        let timestamp: Int
        let value: Double
        let durationSeconds: Int?
    }

    /// Twin of Kotlin `StressTemporalQuality.evaluate`.
    /// Analyze a half-open `[windowStart, windowEnd)` interval. Inputs are sorted and duplicate timestamps
    /// are collapsed before coverage or values are calculated, making replays deterministic.
    public static func evaluate(samples: [StressSignalSample],
                                windowStart: Int,
                                windowEnd: Int,
                                baselineReady: Bool,
                                configuration: StressQualityConfiguration = .daytimeV1)
        -> StressQualityDecision {
        let windowDelta = windowEnd.subtractingReportingOverflow(windowStart)
        let windowDuration = windowDelta.overflow ? 0 : max(0, windowDelta.partialValue)
        let inWindow = samples.filter { $0.timestamp >= windowStart && $0.timestamp < windowEnd }
        let outOfOrder = zip(inWindow, inWindow.dropFirst()).contains { pair in
            pair.0.timestamp > pair.1.timestamp
        }
        let duplicateCount = inWindow.count - Set(inWindow.map(\.timestamp)).count
        let canonical = canonicalValidSamples(inWindow)
        let invalid = inWindow.filter { !isValid($0) }

        let validIntervals = representedIntervals(canonical, windowStart: windowStart, windowEnd: windowEnd,
                                                 configuration: configuration)
        let rejectedIntervals = invalid.compactMap { sample -> Range<Int>? in
            guard windowDuration > 0 else { return nil }
            let duration = min(sample.durationSeconds.flatMap { $0 > 0 ? $0 : nil }
                                   ?? configuration.nominalSampleDurationSeconds,
                               configuration.maximumCreditedIntervalSeconds)
            let end = min(windowEnd, safeAdd(sample.timestamp, max(0, duration)))
            return end > sample.timestamp ? sample.timestamp..<end : nil
        }
        let validDuration = unionDuration(validIntervals)
        let rejectedDuration = unionDuration(rejectedIntervals)
        let maxGap = windowDuration > 0
            ? maximumGap(validIntervals, windowStart: windowStart, windowEnd: windowEnd) : 0
        let coverage = windowDuration > 0 ? Double(validDuration) / Double(windowDuration) : 0

        var reasons: [StressQualityRejectionReason] = []
        if windowDuration <= 0 { reasons.append(.invalidWindow) }
        if canonical.isEmpty { reasons.append(.noValidSamples) }
        if windowDuration > 0 && (validDuration < configuration.minimumValidDurationSeconds
            || coverage + 1e-12 < configuration.minimumCoverageFraction) {
            reasons.append(.insufficientTemporalCoverage)
        }
        if windowDuration > 0 && maxGap > configuration.maximumGapSeconds {
            reasons.append(.maximumGapExceeded)
        }
        if !baselineReady { reasons.append(.baselineNotReady) }

        var diagnostics: [StressQualityDiagnostic] = []
        if duplicateCount > 0 { diagnostics.append(.duplicateTimestamps) }
        if outOfOrder { diagnostics.append(.outOfOrderInput) }
        if !invalid.isEmpty { diagnostics.append(.rejectedSamples) }

        return StressQualityDecision(
            accepted: reasons.isEmpty,
            coveragePercentage: coverage * 100,
            maximumGapSeconds: maxGap,
            validDurationSeconds: validDuration,
            rejectedDurationSeconds: rejectedDuration,
            windowDurationSeconds: windowDuration,
            baselineReady: baselineReady,
            rejectionReasons: reasons,
            diagnostics: diagnostics,
            validSampleCount: canonical.count,
            rejectedSampleCount: invalid.count,
            duplicateTimestampCount: duplicateCount,
            configurationVersion: configuration.version
        )
    }

    /// Twin of Kotlin `StressTemporalQuality.canonicalMean`.
    /// Duration-weighted mean over canonical, non-overlapping represented intervals. This prevents a
    /// dense burst from outweighing a lower-cadence decoder that supplies honest interval durations.
    public static func canonicalMean(samples: [StressSignalSample], windowStart: Int, windowEnd: Int,
                                     configuration: StressQualityConfiguration = .daytimeV1) -> Double? {
        let canonical = canonicalValidSamples(
            samples.filter { $0.timestamp >= windowStart && $0.timestamp < windowEnd }
        )
        var weighted = 0.0
        var duration = 0
        for (index, sample) in canonical.enumerated() {
            let credit = min(sample.durationSeconds ?? configuration.nominalSampleDurationSeconds,
                             configuration.maximumCreditedIntervalSeconds)
            let next = index + 1 < canonical.count ? canonical[index + 1].timestamp : windowEnd
            let end = min(windowEnd, min(next, safeAdd(sample.timestamp, max(0, credit))))
            let seconds = max(0, end - max(windowStart, sample.timestamp))
            weighted += sample.value * Double(seconds)
            duration += seconds
        }
        return duration > 0 ? weighted / Double(duration) : nil
    }

    /// Twin of Kotlin `StressTemporalQuality.isValid`.
    private static func isValid(_ sample: StressSignalSample) -> Bool {
        guard sample.quality == .valid, !sample.isMissing,
              let value = sample.value, value.isFinite else { return false }
        if let duration = sample.durationSeconds, duration <= 0 { return false }
        return true
    }

    /// Twin of Kotlin `StressTemporalQuality.canonicalValidSamples`.
    private static func canonicalValidSamples(_ samples: [StressSignalSample]) -> [CanonicalSample] {
        let grouped = Dictionary(grouping: samples.filter(isValid), by: \.timestamp)
        return grouped.keys.sorted().compactMap { timestamp in
            guard let group = grouped[timestamp], !group.isEmpty else { return nil }
            let values = group.compactMap(\.value).sorted()
            guard !values.isEmpty else { return nil }
            let duration = group.compactMap(\.durationSeconds).max()
            return CanonicalSample(timestamp: timestamp,
                                   value: values.reduce(0, +) / Double(values.count),
                                   durationSeconds: duration)
        }
    }

    /// Twin of Kotlin `StressTemporalQuality.representedIntervals`.
    private static func representedIntervals(_ samples: [CanonicalSample],
                                             windowStart: Int,
                                             windowEnd: Int,
                                             configuration: StressQualityConfiguration) -> [Range<Int>] {
        guard windowEnd > windowStart else { return [] }
        return samples.enumerated().compactMap { index, sample in
            let duration = min(sample.durationSeconds ?? configuration.nominalSampleDurationSeconds,
                               configuration.maximumCreditedIntervalSeconds)
            let start = max(windowStart, sample.timestamp)
            let next = index + 1 < samples.count ? samples[index + 1].timestamp : windowEnd
            let end = min(windowEnd, min(next, safeAdd(sample.timestamp, max(0, duration))))
            return end > start ? start..<end : nil
        }
    }

    /// Twin of Kotlin `StressTemporalQuality.unionDuration`.
    private static func unionDuration(_ intervals: [Range<Int>]) -> Int {
        let ordered = intervals.sorted { $0.lowerBound < $1.lowerBound }
        guard var current = ordered.first else { return 0 }
        var total = 0
        for interval in ordered.dropFirst() {
            if interval.lowerBound <= current.upperBound {
                current = current.lowerBound..<max(current.upperBound, interval.upperBound)
            } else {
                total += current.count
                current = interval
            }
        }
        return total + current.count
    }

    /// Twin of Kotlin `StressTemporalQuality.maximumGap`.
    private static func maximumGap(_ intervals: [Range<Int>],
                                   windowStart: Int,
                                   windowEnd: Int) -> Int {
        guard windowEnd > windowStart else { return 0 }
        let ordered = intervals.sorted { $0.lowerBound < $1.lowerBound }
        guard var current = ordered.first else { return windowEnd - windowStart }
        var largest = max(0, current.lowerBound - windowStart)
        for interval in ordered.dropFirst() {
            if interval.lowerBound > current.upperBound {
                largest = max(largest, interval.lowerBound - current.upperBound)
                current = interval
            } else if interval.upperBound > current.upperBound {
                current = current.lowerBound..<interval.upperBound
            }
        }
        return max(largest, windowEnd - current.upperBound)
    }

    /// Twin of Kotlin `StressTemporalQuality.safeAdd`.
    private static func safeAdd(_ value: Int, _ nonnegativeDelta: Int) -> Int {
        let (sum, overflow) = value.addingReportingOverflow(nonnegativeDelta)
        return overflow ? Int.max : sum
    }
}
