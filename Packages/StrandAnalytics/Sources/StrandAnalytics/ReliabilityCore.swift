import Foundation

// ReliabilityCore.swift
// Shared, headless reliability primitives for activity detection, missing-data recovery,
// algorithm provenance and crash-safe session reconstruction. These types never fabricate
// physiological samples and do not change production sleep/recovery scoring.

public enum DataQualityLevel: String, Codable, Sendable, CaseIterable {
    case complete
    case recovered
    case partial
    case estimated
    case lowConfidence
    case unavailable
}

public struct DataQualityAssessment: Equatable, Codable, Sendable {
    public var level: DataQualityLevel
    public var reasons: [String]
    public var observedSampleCount: Int
    public var largestGapSeconds: Int

    public init(level: DataQualityLevel,
                reasons: [String] = [],
                observedSampleCount: Int = 0,
                largestGapSeconds: Int = 0) {
        self.level = level
        self.reasons = reasons
        self.observedSampleCount = observedSampleCount
        self.largestGapSeconds = largestGapSeconds
    }
}

public enum MissingRangeStatus: String, Codable, Sendable {
    case detected
    case recoveryRequested
    case recovered
    case partiallyRecovered
    case unavailable
}

public struct MissingSampleRange: Equatable, Codable, Sendable, Identifiable {
    public var id: String { "\(startSec):\(endSec)" }
    public let startSec: Int
    public let endSec: Int
    public var status: MissingRangeStatus
    public var reason: String

    public init(startSec: Int, endSec: Int,
                status: MissingRangeStatus = .detected,
                reason: String = "sample interval exceeded continuity threshold") {
        self.startSec = startSec
        self.endSec = endSec
        self.status = status
        self.reason = reason
    }

    public var durationSeconds: Int { max(0, endSec - startSec) }
}

public enum SampleGapDetector {
    /// Detects genuinely unobserved wall-clock ranges. Duplicate and out-of-order timestamps are
    /// normalised before evaluation. A gap starts after the previous observed event timestamp and
    /// ends at the next observed event timestamp; receive time is intentionally irrelevant.
    public static func detect(timestamps: [Int], gapThresholdSeconds: Int = 120) -> [MissingSampleRange] {
        guard gapThresholdSeconds > 0 else { return [] }
        let sorted = Array(Set(timestamps)).sorted()
        guard sorted.count > 1 else { return [] }
        var result: [MissingSampleRange] = []
        for pair in zip(sorted, sorted.dropFirst()) where pair.1 - pair.0 > gapThresholdSeconds {
            result.append(MissingSampleRange(startSec: pair.0, endSec: pair.1))
        }
        return result
    }

    public static func quality(timestamps: [Int], gapThresholdSeconds: Int = 120,
                               recovered: Bool = false) -> DataQualityAssessment {
        let gaps = detect(timestamps: timestamps, gapThresholdSeconds: gapThresholdSeconds)
        let largest = gaps.map(\.durationSeconds).max() ?? 0
        if timestamps.isEmpty {
            return DataQualityAssessment(level: .unavailable,
                                         reasons: ["no physiological samples are available"],
                                         observedSampleCount: 0, largestGapSeconds: 0)
        }
        if gaps.isEmpty {
            return DataQualityAssessment(level: recovered ? .recovered : .complete,
                                         reasons: recovered ? ["previous missing range was restored from retained samples"] : [],
                                         observedSampleCount: Set(timestamps).count,
                                         largestGapSeconds: 0)
        }
        return DataQualityAssessment(level: .partial,
                                     reasons: ["one or more sample ranges remain unavailable"],
                                     observedSampleCount: Set(timestamps).count,
                                     largestGapSeconds: largest)
    }
}

public struct RecoveryTimedSample: Equatable, Hashable, Codable, Sendable {
    public let timestampSec: Int
    public let value: Int
    public let source: String
    public let receivedAtSec: Int?

    public init(timestampSec: Int, value: Int, source: String, receivedAtSec: Int? = nil) {
        self.timestampSec = timestampSec
        self.value = value
        self.source = source
        self.receivedAtSec = receivedAtSec
    }
}

public struct RecoveredRange: Equatable, Codable, Sendable {
    public let requested: MissingSampleRange
    public let status: MissingRangeStatus
    public let recoveredSampleCount: Int
    public let remainingGaps: [MissingSampleRange]
}

public struct RecoveryReconciliation: Equatable, Codable, Sendable {
    public let samples: [RecoveryTimedSample]
    public let ranges: [RecoveredRange]
    public let insertedSampleCount: Int
    public let duplicateSampleCount: Int
    public let quality: DataQualityAssessment
}

public enum HistoricalRecoveryReconciler {
    /// Idempotently combines already-stored samples and historical/offloaded samples. Identity is
    /// physiological event timestamp + source; arrival time is metadata, never event time. Existing
    /// samples win exact collisions so replaying the same offload cannot rewrite history.
    public static func reconcile(existing: [RecoveryTimedSample],
                                 recovered: [RecoveryTimedSample],
                                 requestedRanges: [MissingSampleRange],
                                 gapThresholdSeconds: Int = 120) -> RecoveryReconciliation {
        struct Key: Hashable { let ts: Int; let source: String }
        var table: [Key: RecoveryTimedSample] = [:]
        for sample in existing.sorted(by: { $0.timestampSec < $1.timestampSec }) {
            table[Key(ts: sample.timestampSec, source: sample.source)] = sample
        }
        var inserted = 0
        var duplicates = 0
        for sample in recovered.sorted(by: { $0.timestampSec < $1.timestampSec }) {
            let key = Key(ts: sample.timestampSec, source: sample.source)
            if table[key] != nil {
                duplicates += 1
            } else {
                table[key] = sample
                inserted += 1
            }
        }
        let merged = table.values.sorted {
            if $0.timestampSec == $1.timestampSec { return $0.source < $1.source }
            return $0.timestampSec < $1.timestampSec
        }
        let timestamps = merged.map(\.timestampSec)
        let remainingAll = SampleGapDetector.detect(timestamps: timestamps, gapThresholdSeconds: gapThresholdSeconds)

        let outcomes = requestedRanges.map { requested -> RecoveredRange in
            let recoveredCount = recovered.filter { $0.timestampSec > requested.startSec && $0.timestampSec < requested.endSec }.count
            let remaining = remainingAll.filter { gap in
                gap.startSec < requested.endSec && requested.startSec < gap.endSec
            }
            let status: MissingRangeStatus
            if recoveredCount == 0 {
                status = .unavailable
            } else if remaining.isEmpty {
                status = .recovered
            } else {
                status = .partiallyRecovered
            }
            return RecoveredRange(requested: requested, status: status,
                                  recoveredSampleCount: recoveredCount, remainingGaps: remaining)
        }
        let allRequestedRecovered = !outcomes.isEmpty && outcomes.allSatisfy { $0.status == .recovered }
        let quality = SampleGapDetector.quality(timestamps: timestamps,
                                                gapThresholdSeconds: gapThresholdSeconds,
                                                recovered: allRequestedRecovered)
        return RecoveryReconciliation(samples: merged, ranges: outcomes,
                                      insertedSampleCount: inserted,
                                      duplicateSampleCount: duplicates,
                                      quality: quality)
    }
}

public enum ActivityCandidateState: String, Codable, Sendable {
    case possible
    case likely
    case confirmed
    case rejected
}

public enum EvidenceConfidence: String, Codable, Sendable, Comparable {
    case low
    case moderate
    case high

    private var rank: Int { self == .low ? 0 : (self == .moderate ? 1 : 2) }
    public static func < (lhs: EvidenceConfidence, rhs: EvidenceConfidence) -> Bool { lhs.rank < rhs.rank }
}

public enum ActivityEvidenceKind: String, Codable, Sendable {
    case sustainedHeartRate
    case movement
    case postActivityRecovery
    case missingData
    case existingWorkoutOverlap
}

public struct ActivityEvidence: Equatable, Codable, Sendable {
    public let kind: ActivityEvidenceKind
    public let supportsActivity: Bool
    public let detail: String
}

public struct ActivityCandidateAssessment: Equatable, Codable, Sendable, Identifiable {
    public var id: String { "\(startSec):\(endSec)" }
    public let startSec: Int
    public let endSec: Int
    public let avgBpm: Int
    public let peakBpm: Int
    public let state: ActivityCandidateState
    public let activityConfidence: EvidenceConfidence
    public let typeConfidence: EvidenceConfidence
    public let suggestedType: String?
    public let evidence: [ActivityEvidence]
    public let quality: DataQualityAssessment

    public var durationMin: Int { max(0, endSec - startSec) / 60 }
}

public enum ActivityCandidateEngine {
    public static let continuityGapSeconds = 120
    public static let recoveryWindowSeconds = 5 * 60
    public static let recoveryDropBPM = 15
    public static let minimumMotionPoints = 30
    public static let minimumMotionSpanSeconds = 6 * 60

    /// Wraps the existing published AutoWorkoutDetector and adds evidence/confidence without changing
    /// its production threshold. HR alone can only yield Possible/Likely; Confirmed requires usable
    /// movement evidence. Sport type remains unknown because gravity magnitude does not identify a sport.
    public static func assess(hr: [(ts: Int, bpm: Int)],
                              restingBpm: Int?,
                              motion: [AutoWorkoutDetector.MotionPoint] = [],
                              savedSpans: [SavedWorkoutSpan] = []) -> [ActivityCandidateAssessment] {
        // De-duplicate physiological timestamps before detection. A replayed historical packet must not
        // double-weight average HR or create a new candidate.
        var byTimestamp: [Int: Int] = [:]
        for row in hr.sorted(by: { $0.ts < $1.ts }) { byTimestamp[row.ts] = row.bpm }
        let cleanHR = byTimestamp.map { (ts: $0.key, bpm: $0.value) }.sorted { $0.ts < $1.ts }
        let windows = AutoWorkoutDetector.detect(hr: cleanHR, restingBpm: restingBpm,
                                                  motion: nil, savedSpans: savedSpans)
        return windows.map { window in
            let inMotion = motion.filter { $0.ts >= window.startSec && $0.ts <= window.endSec }
            let sortedMotion = inMotion.sorted { $0.ts < $1.ts }
            let usableMotion = sortedMotion.count >= minimumMotionPoints
                && ((sortedMotion.last?.ts ?? 0) - (sortedMotion.first?.ts ?? 0) >= minimumMotionSpanSeconds)
            let meanMotion = sortedMotion.isEmpty ? 0 : sortedMotion.map(\.intensity).reduce(0, +) / Double(sortedMotion.count)
            let motionSupports = usableMotion && meanMotion >= AutoWorkoutDetector.motionConfirmMean

            let post = cleanHR.filter { $0.ts > window.endSec && $0.ts <= window.endSec + recoveryWindowSeconds }
            let postMin = post.map(\.bpm).min()
            let recoverySupports = postMin.map { window.avgBpm - $0 >= recoveryDropBPM } ?? false

            var evidence = [ActivityEvidence(kind: .sustainedHeartRate, supportsActivity: true,
                                             detail: "sustained HR met the published candidate threshold")]
            if usableMotion {
                evidence.append(ActivityEvidence(kind: .movement, supportsActivity: motionSupports,
                                                 detail: motionSupports ? "continuous movement supports activity" : "continuous movement did not support activity"))
            }
            if postMin != nil {
                evidence.append(ActivityEvidence(kind: .postActivityRecovery, supportsActivity: recoverySupports,
                                                 detail: recoverySupports ? "post-activity HR recovery pattern present" : "no clear post-activity HR recovery pattern"))
            }
            let gaps = SampleGapDetector.detect(timestamps: cleanHR.filter { $0.ts >= window.startSec && $0.ts <= window.endSec }.map(\.ts),
                                                gapThresholdSeconds: continuityGapSeconds)
            if !gaps.isEmpty {
                evidence.append(ActivityEvidence(kind: .missingData, supportsActivity: false,
                                                 detail: "candidate contains an unobserved physiological interval"))
            }

            let state: ActivityCandidateState
            let confidence: EvidenceConfidence
            if motionSupports && gaps.isEmpty {
                state = .confirmed
                confidence = .high
            } else if recoverySupports && gaps.isEmpty {
                state = .likely
                confidence = .moderate
            } else {
                state = .possible
                confidence = .low
            }
            let quality = SampleGapDetector.quality(timestamps: cleanHR.filter { $0.ts >= window.startSec && $0.ts <= window.endSec }.map(\.ts),
                                                    gapThresholdSeconds: continuityGapSeconds)
            return ActivityCandidateAssessment(startSec: window.startSec, endSec: window.endSec,
                                               avgBpm: window.avgBpm, peakBpm: window.peakBpm,
                                               state: state, activityConfidence: confidence,
                                               typeConfidence: .low, suggestedType: nil,
                                               evidence: evidence, quality: quality)
        }
    }
}

public enum SessionSource: String, Codable, Sendable {
    case manual
    case automatic
    case imported
    case healthKit
    case watch
}

public enum DurableSessionState: String, Codable, Sendable {
    case active
    case paused
    case closing
}

public struct ActiveSessionSnapshot: Equatable, Codable, Sendable, Identifiable {
    public let id: UUID
    public var startSec: Int
    public var sessionType: String
    public var source: SessionSource
    public var state: DurableSessionState
    public var latestValidSampleSec: Int?
    public var elapsedActiveSeconds: Int
    public var accumulatedSampleCount: Int
    public var watchSessionIdentifier: String?
    public var healthKitWorkoutIdentifier: String?
    public var whoopConnected: Bool
    public var lastPersistedSec: Int
    public var quality: DataQualityAssessment

    public init(id: UUID = UUID(), startSec: Int, sessionType: String, source: SessionSource,
                state: DurableSessionState = .active, latestValidSampleSec: Int? = nil,
                elapsedActiveSeconds: Int = 0, accumulatedSampleCount: Int = 0,
                watchSessionIdentifier: String? = nil, healthKitWorkoutIdentifier: String? = nil,
                whoopConnected: Bool = false, lastPersistedSec: Int,
                quality: DataQualityAssessment = .init(level: .partial, reasons: ["session is still in progress"])) {
        self.id = id
        self.startSec = startSec
        self.sessionType = sessionType
        self.source = source
        self.state = state
        self.latestValidSampleSec = latestValidSampleSec
        self.elapsedActiveSeconds = elapsedActiveSeconds
        self.accumulatedSampleCount = accumulatedSampleCount
        self.watchSessionIdentifier = watchSessionIdentifier
        self.healthKitWorkoutIdentifier = healthKitWorkoutIdentifier
        self.whoopConnected = whoopConnected
        self.lastPersistedSec = lastPersistedSec
        self.quality = quality
    }
}

public enum SessionCheckpointPolicy {
    /// Persist on meaningful state changes immediately; otherwise checkpoint at most once per minute.
    public static let periodicCheckpointSeconds = 60
    public static func shouldCheckpoint(lastPersistedSec: Int, nowSec: Int, stateChanged: Bool) -> Bool {
        stateChanged || nowSec - lastPersistedSec >= periodicCheckpointSeconds
    }
}

public struct SessionReconciliationResult: Equatable, Sendable {
    public let snapshot: ActiveSessionSnapshot
    public let recoveredSampleCount: Int
    public let duplicateSampleCount: Int
    public let gaps: [MissingSampleRange]
}

public enum SessionReconciler {
    /// Rebuilds a persisted session from real samples only. It never creates a second session UUID and
    /// never infers continuous activity across missing ranges. Offloaded samples can improve coverage
    /// after a crash/restart while preserving the original session identity.
    public static func reconcile(snapshot: ActiveSessionSnapshot,
                                 existingSamples: [RecoveryTimedSample],
                                 delayedSamples: [RecoveryTimedSample],
                                 nowSec: Int) -> SessionReconciliationResult {
        let requested = SampleGapDetector.detect(timestamps: existingSamples.map(\.timestampSec))
        let merged = HistoricalRecoveryReconciler.reconcile(existing: existingSamples,
                                                             recovered: delayedSamples,
                                                             requestedRanges: requested)
        var out = snapshot
        out.latestValidSampleSec = merged.samples.map(\.timestampSec).max() ?? snapshot.latestValidSampleSec
        out.accumulatedSampleCount = merged.samples.count
        out.whoopConnected = snapshot.whoopConnected
        out.lastPersistedSec = nowSec
        out.quality = merged.quality
        return SessionReconciliationResult(snapshot: out,
                                           recoveredSampleCount: merged.insertedSampleCount,
                                           duplicateSampleCount: merged.duplicateSampleCount,
                                           gaps: SampleGapDetector.detect(timestamps: merged.samples.map(\.timestampSec)))
    }
}

public struct AlgorithmVersion: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let family: String
    public let version: String
    public init(family: String, version: String) { self.family = family; self.version = version }
    public var description: String { "\(family)/\(version)" }
}

public enum ProductionAlgorithmVersions {
    /// Provenance labels for the current production implementations. Adding these labels does not alter
    /// the algorithms or rescore history; migrations must explicitly opt into any future version.
    public static let sleepDetection = AlgorithmVersion(family: "SleepDetection", version: "1.0")
    public static let recovery = AlgorithmVersion(family: "Recovery", version: "1.0")
}

public struct DerivedMetricProvenance: Equatable, Codable, Sendable {
    public let algorithm: AlgorithmVersion
    public let generatedAtSec: Int
    public let quality: DataQualityAssessment
}

public struct SleepTimingValidationCase: Equatable, Sendable {
    public let referenceStartSec: Int
    public let referenceEndSec: Int
    public let predictedStartSec: Int
    public let predictedEndSec: Int
    public init(referenceStartSec: Int, referenceEndSec: Int, predictedStartSec: Int, predictedEndSec: Int) {
        self.referenceStartSec = referenceStartSec
        self.referenceEndSec = referenceEndSec
        self.predictedStartSec = predictedStartSec
        self.predictedEndSec = predictedEndSec
    }
}

public struct SleepTimingValidationSummary: Equatable, Sendable {
    public let startMAESeconds: Double
    public let endMAESeconds: Double
    public let totalSleepTimeMAESeconds: Double
    public let medianStartAbsoluteErrorSeconds: Double
    public let medianEndAbsoluteErrorSeconds: Double
}

public enum SleepValidationMetrics {
    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted(); let m = s.count / 2
        return s.count.isMultiple(of: 2) ? (s[m - 1] + s[m]) / 2 : s[m]
    }
    private static func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }

    public static func timing(_ cases: [SleepTimingValidationCase]) -> SleepTimingValidationSummary {
        let start = cases.map { Double(abs($0.predictedStartSec - $0.referenceStartSec)) }
        let end = cases.map { Double(abs($0.predictedEndSec - $0.referenceEndSec)) }
        let tst = cases.map {
            Double(abs(($0.predictedEndSec - $0.predictedStartSec) - ($0.referenceEndSec - $0.referenceStartSec)))
        }
        return SleepTimingValidationSummary(startMAESeconds: mean(start), endMAESeconds: mean(end),
                                            totalSleepTimeMAESeconds: mean(tst),
                                            medianStartAbsoluteErrorSeconds: median(start),
                                            medianEndAbsoluteErrorSeconds: median(end))
    }
}

public struct BinaryClassificationMetrics: Equatable, Sendable {
    public let truePositive: Int
    public let falsePositive: Int
    public let trueNegative: Int
    public let falseNegative: Int
    public var precision: Double { ratio(truePositive, truePositive + falsePositive) }
    public var recall: Double { ratio(truePositive, truePositive + falseNegative) }
    public var falsePositiveRate: Double { ratio(falsePositive, falsePositive + trueNegative) }
    public var falseNegativeRate: Double { ratio(falseNegative, falseNegative + truePositive) }
    private func ratio(_ a: Int, _ b: Int) -> Double { b == 0 ? 0 : Double(a) / Double(b) }
}

public enum ValidationMetrics {
    public static func binary(reference: [Bool], predicted: [Bool]) -> BinaryClassificationMetrics {
        let n = min(reference.count, predicted.count)
        var tp = 0, fp = 0, tn = 0, fn = 0
        for i in 0..<n {
            switch (reference[i], predicted[i]) {
            case (true, true): tp += 1
            case (false, true): fp += 1
            case (false, false): tn += 1
            case (true, false): fn += 1
            }
        }
        return BinaryClassificationMetrics(truePositive: tp, falsePositive: fp,
                                           trueNegative: tn, falseNegative: fn)
    }
}
