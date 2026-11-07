import Foundation

public enum SpO2RejectionReason: String, Codable, CaseIterable, Equatable, Sendable {
    case lowQuality
    case excessiveMotion
    case invalidValue
}

public struct SpO2RejectedSample: Codable, Equatable, Sendable {
    public let sample: WHOOPSpO2Sample
    public let reasons: [SpO2RejectionReason]

    public init(sample: WHOOPSpO2Sample, reasons: [SpO2RejectionReason]) {
        self.sample = sample
        self.reasons = reasons
    }
}

public struct SpO2QualityFilterResult: Codable, Equatable, Sendable {
    public let validSamples: [WHOOPSpO2Sample]
    public let rejectedSamples: [SpO2RejectedSample]

    public var rejectedCount: Int { rejectedSamples.count }
    public var acceptedCount: Int { validSamples.count }
    public var totalCount: Int { validSamples.count + rejectedSamples.count }
    public var acceptanceFraction: Double? {
        guard totalCount > 0 else { return nil }
        return Double(acceptedCount) / Double(totalCount)
    }

    public func rejectionCount(for reason: SpO2RejectionReason) -> Int {
        rejectedSamples.reduce(into: 0) { count, rejected in
            if rejected.reasons.contains(reason) { count += 1 }
        }
    }
}

/// Research quality gate for the unverified summary-frame hypothesis; not a clinical validity gate.
public enum SpO2QualityFilter {
    public static let minimumQualityScore: UInt8 = 70
    public static let maximumMotionVarianceG = 0.05

    public static func filter(_ samples: [WHOOPSpO2Sample]) -> SpO2QualityFilterResult {
        var accepted: [WHOOPSpO2Sample] = []
        var rejected: [SpO2RejectedSample] = []
        accepted.reserveCapacity(samples.count)

        for sample in samples {
            var reasons: [SpO2RejectionReason] = []
            if sample.qualityScore < minimumQualityScore {
                reasons.append(.lowQuality)
            }
            // Public initialization and Codable can bypass the byte decoder. Validate here as well,
            // before sorting/averaging: NaN comparisons otherwise silently pass threshold checks.
            if !sample.spo2Percent.isFinite || !(70.0...100.0).contains(sample.spo2Percent)
                || sample.spo2Percent != Double(sample.rawSpO2) / 100.0
                || sample.qualityScore > 100
                || !sample.motionVarianceG.isFinite || sample.motionVarianceG < 0 {
                reasons.append(.invalidValue)
            }
            if sample.motionVarianceG > maximumMotionVarianceG {
                reasons.append(.excessiveMotion)
            }

            if reasons.isEmpty {
                accepted.append(sample)
            } else {
                rejected.append(SpO2RejectedSample(sample: sample, reasons: reasons))
            }
        }

        return SpO2QualityFilterResult(validSamples: accepted, rejectedSamples: rejected)
    }
}
