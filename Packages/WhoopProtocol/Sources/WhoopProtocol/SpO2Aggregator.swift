import Foundation

/// A decoded summary sample associated with one sleep epoch.
///
/// The stage flag is supplied by the sleep-staging layer so `WhoopProtocol` does not depend upward on
/// `StrandAnalytics`. Canonical nightly aggregation consumes only five-minute Slow-Wave Sleep epochs.
public struct SpO2SleepEpoch: Codable, Equatable, Sendable {
    public static let canonicalDurationSeconds = 5 * 60

    public let sample: WHOOPSpO2Sample
    public let isSlowWaveSleep: Bool
    public let durationSeconds: Int

    public init(sample: WHOOPSpO2Sample,
                isSlowWaveSleep: Bool,
                durationSeconds: Int = SpO2SleepEpoch.canonicalDurationSeconds) {
        self.sample = sample
        self.isSlowWaveSleep = isSlowWaveSleep
        self.durationSeconds = durationSeconds
    }
}

public struct SpO2NightlyAggregate: Codable, Equatable, Sendable {
    public let spo2Percent: Double
    public let validEpochCount: Int
    public let rejectedQualityEpochCount: Int
    public let nonCanonicalDurationCount: Int
    public let slowWaveEpochCount: Int
    public let trimCountPerTail: Int
    public let coverageFraction: Double
    public let minimumPercent: Double
    public let maximumPercent: Double

    public init(spo2Percent: Double,
                validEpochCount: Int,
                rejectedQualityEpochCount: Int,
                nonCanonicalDurationCount: Int,
                slowWaveEpochCount: Int,
                trimCountPerTail: Int,
                coverageFraction: Double,
                minimumPercent: Double,
                maximumPercent: Double) {
        self.spo2Percent = spo2Percent
        self.validEpochCount = validEpochCount
        self.rejectedQualityEpochCount = rejectedQualityEpochCount
        self.nonCanonicalDurationCount = nonCanonicalDurationCount
        self.slowWaveEpochCount = slowWaveEpochCount
        self.trimCountPerTail = trimCountPerTail
        self.coverageFraction = coverageFraction
        self.minimumPercent = minimumPercent
        self.maximumPercent = maximumPercent
    }
}

public enum SpO2AggregatorError: Error, Equatable, Sendable {
    case noSlowWaveSleepEpochs
    case insufficientValidEpochs(required: Int, actual: Int)
    case conflictingTimestamp(UInt32)
    case overlappingEpochs
}

extension SpO2AggregatorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noSlowWaveSleepEpochs:
            return "No canonical five-minute Slow-Wave Sleep SpO2 epochs were available."
        case .insufficientValidEpochs(let required, let actual):
            return "Insufficient valid Slow-Wave Sleep SpO2 coverage: requires at least \(required) epochs, got \(actual)."
        case .conflictingTimestamp(let timestamp):
            return "Conflicting experimental SpO2 evidence at timestamp \(timestamp)."
        case .overlappingEpochs:
            return "Experimental SpO2 five-minute epochs overlap."
        }
    }
}

/// Research aggregation under the unverified five-minute summary-frame hypothesis.
/// This helper alone does not establish whole-night coverage or physiological validity.
///
/// A "10% trimmed mean" removes floor(10% of N) observations from EACH tail, the conventional
/// statistical definition. Samples first pass the canonical quality/motion filter and must represent
/// five-minute SWS epochs. At least ten valid epochs are required before a nightly value is emitted.
public enum SpO2Aggregator {
    public static let minimumValidEpochs = 10
    public static let trimFractionPerTail = 0.10

    public static func aggregate(_ epochs: [SpO2SleepEpoch]) throws -> SpO2NightlyAggregate {
        // Deduplicate BEFORE stage/quality filtering: conflicting stage or quality evidence at one
        // timestamp must not be silently resolved by discarding the inconvenient interpretation.
        var unique: [UInt32: SpO2SleepEpoch] = [:]
        for epoch in epochs {
            if let existing = unique[epoch.sample.timestampUnix], existing != epoch {
                throw SpO2AggregatorError.conflictingTimestamp(epoch.sample.timestampUnix)
            }
            unique[epoch.sample.timestampUnix] = epoch
        }
        let ordered = unique.values.sorted { $0.sample.timestampUnix < $1.sample.timestampUnix }
        let sws = ordered.filter(\.isSlowWaveSleep)
        let canonical = sws.filter { $0.durationSeconds == SpO2SleepEpoch.canonicalDurationSeconds }
        guard !canonical.isEmpty else {
            throw SpO2AggregatorError.noSlowWaveSleepEpochs
        }

        let quality = SpO2QualityFilter.filter(canonical.map(\.sample))
        // Ten slightly shifted copies of the same five minutes are not ten independent epochs.
        for pair in zip(quality.validSamples, quality.validSamples.dropFirst()) {
            guard UInt64(pair.1.timestampUnix) - UInt64(pair.0.timestampUnix)
                >= UInt64(SpO2SleepEpoch.canonicalDurationSeconds) else {
                throw SpO2AggregatorError.overlappingEpochs
            }
        }
        guard quality.validSamples.count >= minimumValidEpochs else {
            throw SpO2AggregatorError.insufficientValidEpochs(
                required: minimumValidEpochs,
                actual: quality.validSamples.count
            )
        }

        // Tie-break on timestamp to make the operation deterministic even when values are equal.
        let sorted = quality.validSamples.sorted {
            if $0.spo2Percent != $1.spo2Percent { return $0.spo2Percent < $1.spo2Percent }
            return $0.timestampUnix < $1.timestampUnix
        }
        let trimCount = Int(floor(Double(sorted.count) * trimFractionPerTail))
        let lower = trimCount
        let upper = sorted.count - trimCount
        let trimmed = sorted[lower..<upper]
        let mean = trimmed.reduce(0.0) { $0 + $1.spo2Percent } / Double(trimmed.count)

        return SpO2NightlyAggregate(
            spo2Percent: mean,
            validEpochCount: quality.validSamples.count,
            rejectedQualityEpochCount: quality.rejectedCount,
            nonCanonicalDurationCount: sws.count - canonical.count,
            slowWaveEpochCount: sws.count,
            trimCountPerTail: trimCount,
            coverageFraction: Double(quality.validSamples.count) / Double(sws.count),
            minimumPercent: sorted.first?.spo2Percent ?? mean,
            maximumPercent: sorted.last?.spo2Percent ?? mean
        )
    }
}
