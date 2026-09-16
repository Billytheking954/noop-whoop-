import Foundation
import WhoopProtocol

/// Canonical archive row for one raw WHOOP 5 nightly-telemetry frame.
/// Night Lab stores the original bytes as lowercase/uppercase-insensitive hex so replay can always
/// run a newer decoder against the exact evidence rather than persisting only derived percentages.
public struct NightLabSpO2FrameRow: Codable, Equatable, Sendable {
    public let hex: String

    public init(hex: String) {
        self.hex = hex
    }
}

public struct NightLabSpO2EpochDiagnostic: Equatable, Sendable {
    public let timestampUnix: Int?
    public let spo2Percent: Double?
    public let qualityScore: Int?
    public let motionVarianceG: Double?
    public let isSlowWaveSleep: Bool
    public let acceptedByQualityGate: Bool
    public let decodeError: String?
}

public struct NightLabSpO2Diagnostics: Equatable, Sendable {
    public static let rawAssetID = "whoop5-spo2-summary"

    public let archivedFrameCount: Int
    public let decodedFrameCount: Int
    public let decodeFailureCount: Int
    public let crcFailureCount: Int
    public let qualityRejectedCount: Int
    public let lowQualityCount: Int
    public let highMotionCount: Int
    public let expectedNightlyFrameCount: Int
    public let frameCoverageFraction: Double
    public let slowWaveFrameCount: Int
    public let validSlowWaveFrameCount: Int
    public let aggregate: SpO2NightlyAggregate?
    public let aggregationError: String?
    public let epochs: [NightLabSpO2EpochDiagnostic]

    public static func analyze(rows: [NightLabSpO2FrameRow],
                               windowStartUnix: Int,
                               windowEndUnix: Int,
                               baseline: SleepStagerV2BaselineArtifact?) -> Self {
        var decoded: [WHOOPSpO2Sample] = []
        var epochDiagnostics: [NightLabSpO2EpochDiagnostic] = []
        var decodeFailures = 0
        var crcFailures = 0

        for row in rows {
            guard let bytes = bytes(fromHex: row.hex) else {
                decodeFailures += 1
                epochDiagnostics.append(.init(timestampUnix: nil,
                                              spo2Percent: nil,
                                              qualityScore: nil,
                                              motionVarianceG: nil,
                                              isSlowWaveSleep: false,
                                              acceptedByQualityGate: false,
                                              decodeError: "Invalid hex encoding"))
                continue
            }

            do {
                let sample = try WHOOPSpO2Decoder.decode(bytes)
                decoded.append(sample)
                let sws = baseline.map {
                    isFullySlowWaveSleep(startUnix: Int(sample.timestampUnix), baseline: $0)
                } ?? false
                let accepted = sample.qualityScore >= SpO2QualityFilter.minimumQualityScore
                    && sample.motionVarianceG <= SpO2QualityFilter.maximumMotionVarianceG
                epochDiagnostics.append(.init(timestampUnix: Int(sample.timestampUnix),
                                              spo2Percent: sample.spo2Percent,
                                              qualityScore: Int(sample.qualityScore),
                                              motionVarianceG: sample.motionVarianceG,
                                              isSlowWaveSleep: sws,
                                              acceptedByQualityGate: accepted,
                                              decodeError: nil))
            } catch {
                decodeFailures += 1
                if let decoderError = error as? WHOOPSpO2DecoderError,
                   case .crcMismatch = decoderError {
                    crcFailures += 1
                }
                epochDiagnostics.append(.init(timestampUnix: nil,
                                              spo2Percent: nil,
                                              qualityScore: nil,
                                              motionVarianceG: nil,
                                              isSlowWaveSleep: false,
                                              acceptedByQualityGate: false,
                                              decodeError: error.localizedDescription))
            }
        }

        let duration = max(0, windowEndUnix - windowStartUnix)
        let expected = duration == 0 ? 0 : Int(ceil(Double(duration) / 300.0))
        let inWindowDecoded = decoded.filter {
            let ts = Int($0.timestampUnix)
            return ts >= windowStartUnix && ts < windowEndUnix
        }

        // Identical retransmissions must not inflate coverage or the trimmed mean. Conflicting frames at
        // one timestamp are ambiguous evidence, so retain neither interpretation and fail the aggregate.
        var uniqueByTimestamp: [UInt32: WHOOPSpO2Sample] = [:]
        var hasConflictingDuplicate = false
        for sample in inWindowDecoded {
            if let existing = uniqueByTimestamp[sample.timestampUnix], existing != sample {
                hasConflictingDuplicate = true
            } else {
                uniqueByTimestamp[sample.timestampUnix] = sample
            }
        }
        let canonicalDecoded = uniqueByTimestamp.values.sorted { $0.timestampUnix < $1.timestampUnix }
        let coverage = expected == 0 ? 0 : min(1, Double(canonicalDecoded.count) / Double(expected))
        var maximumGap = max(0, windowEndUnix - windowStartUnix)
        if let first = canonicalDecoded.first, let last = canonicalDecoded.last {
            maximumGap = max(0, Int(first.timestampUnix) - windowStartUnix)
            if canonicalDecoded.count > 1 {
                for index in 1..<canonicalDecoded.count {
                    maximumGap = max(
                        maximumGap,
                        Int(canonicalDecoded[index].timestampUnix)
                            - Int(canonicalDecoded[index - 1].timestampUnix)
                    )
                }
            }
            maximumGap = max(maximumGap, max(0, windowEndUnix - Int(last.timestampUnix)))
        }

        let quality = SpO2QualityFilter.filter(decoded)
        let aggregationEpochs = canonicalDecoded.map { sample in
            SpO2SleepEpoch(
                sample: sample,
                isSlowWaveSleep: baseline.map {
                    isFullySlowWaveSleep(startUnix: Int(sample.timestampUnix), baseline: $0)
                } ?? false
            )
        }

        let aggregate: SpO2NightlyAggregate?
        let aggregationError: String?
        // Research-only availability gates. They do not assert physiological accuracy; they prevent a
        // plausible-looking value from being emitted from sparse or heavily clustered evidence. A frame
        // represents five minutes, so 900 seconds permits at most two missing starts between observations.
        if hasConflictingDuplicate {
            aggregate = nil
            aggregationError = "SpO2 evidence contains conflicting frames with the same timestamp."
        } else if coverage < 0.80 {
            aggregate = nil
            aggregationError = String(
                format: "Insufficient whole-night SpO2 frame coverage: requires %.1f%%, got %.1f%%.",
                80.0,
                coverage * 100
            )
        } else if maximumGap > 15 * 60 {
            aggregate = nil
            aggregationError = "SpO2 evidence contains a frame gap of \(maximumGap) seconds; "
                + "the maximum allowed is \(15 * 60) seconds."
        } else {
            do {
                aggregate = try SpO2Aggregator.aggregate(aggregationEpochs)
                aggregationError = nil
            } catch {
                aggregate = nil
                aggregationError = error.localizedDescription
            }
        }
        let swsFrames = aggregationEpochs.filter(\.isSlowWaveSleep)
        let validSWS = SpO2QualityFilter.filter(swsFrames.map(\.sample)).acceptedCount

        return Self(
            archivedFrameCount: rows.count,
            decodedFrameCount: decoded.count,
            decodeFailureCount: decodeFailures,
            crcFailureCount: crcFailures,
            qualityRejectedCount: quality.rejectedCount,
            lowQualityCount: quality.rejectionCount(for: .lowQuality),
            highMotionCount: quality.rejectionCount(for: .excessiveMotion),
            expectedNightlyFrameCount: expected,
            frameCoverageFraction: coverage,
            slowWaveFrameCount: swsFrames.count,
            validSlowWaveFrameCount: validSWS,
            aggregate: aggregate,
            aggregationError: aggregationError,
            epochs: epochDiagnostics.sorted { ($0.timestampUnix ?? Int.max) < ($1.timestampUnix ?? Int.max) }
        )
    }

    private static func isFullySlowWaveSleep(startUnix: Int,
                                             baseline: SleepStagerV2BaselineArtifact) -> Bool {
        let endUnix = startUnix + SpO2SleepEpoch.canonicalDurationSeconds
        var coveredSeconds = 0

        if let leading = baseline.leadingBoundary,
           leading.endUnix > startUnix,
           leading.startUnix < endUnix {
            let overlap = max(0, min(endUnix, leading.endUnix) - max(startUnix, leading.startUnix))
            if overlap > 0 {
                guard leading.stage.rawValue == "deep" else { return false }
                coveredSeconds += overlap
            }
        }

        for epoch in baseline.epochs where epoch.endUnix > startUnix && epoch.startUnix < endUnix {
            let overlap = max(0, min(endUnix, epoch.endUnix) - max(startUnix, epoch.startUnix))
            if overlap > 0 {
                guard epoch.stage.rawValue == "deep" else { return false }
                coveredSeconds += overlap
            }
        }

        return coveredSeconds >= SpO2SleepEpoch.canonicalDurationSeconds
    }

    private static func bytes(fromHex string: String) -> [UInt8]? {
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count.isMultiple(of: 2) else { return nil }
        var result: [UInt8] = []
        result.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}
