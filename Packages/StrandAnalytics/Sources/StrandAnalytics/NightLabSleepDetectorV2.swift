import Foundation
import WhoopProtocol

/// Experimental Night Lab seam for developing sleep-session detection independently of sleep staging.
///
/// Phase 2 starts conservatively: the existing, battle-tested `SleepStager.detectSleep` Stage-0 detector
/// is used as the candidate spine, but its staged `SleepSession` output is immediately projected down to
/// boundaries. Night Lab therefore gains a deterministic/versioned detection contract without changing
/// production call sites, production coefficients, or `SleepStagerV2`.
///
/// Future detector revisions can replace `bootstrapCandidates` behind this API while keeping replay,
/// diagnostics, comparison and provenance stable.
public enum NightLabSleepDetectorV2 {
    public static let algorithmID = "nightlab.sleep-detection-v2"
    public static let algorithmVersion = "0.1.0-bootstrap-v1-spine"
    public static let candidateSource = "SleepStager.detectSleep.stage0-v1"

    public struct Configuration: Equatable, Codable, Sendable {
        /// Diagnostic only. A gap larger than this is surfaced in evidence quality; it does not tune
        /// the production detector. The default deliberately inherits V1's existing run-break threshold.
        public let diagnosticGapSeconds: Int

        public init(diagnosticGapSeconds: Int = SleepStager.maxGapMin * 60) {
            self.diagnosticGapSeconds = max(1, diagnosticGapSeconds)
        }

        public var identity: String {
            "candidate=v1-stage0;diagnostic-gap=\(diagnosticGapSeconds)s;duplicates=median-existing-sample"
        }
    }

    public enum Status: String, Equatable, Codable, Sendable {
        case detected
        case insufficientEvidence
        case noPlausibleSleep
        case invalidEvidence
    }

    /// Detection-only projection. This is deliberately not another persisted SleepSession model.
    public struct CandidateBoundary: Equatable, Hashable, Codable, Sendable {
        public let start: Int
        public let end: Int
        public let hrOnly: Bool

        public init(start: Int, end: Int, hrOnly: Bool) {
            self.start = start
            self.end = end
            self.hrOnly = hrOnly
        }

        public var durationSeconds: Int { max(0, end - start) }
    }

    public struct GapDiagnostics: Equatable, Codable, Sendable {
        public let gapCount: Int
        public let largestGapSeconds: Int

        public init(gapCount: Int, largestGapSeconds: Int) {
            self.gapCount = gapCount
            self.largestGapSeconds = largestGapSeconds
        }
    }

    public struct EvidenceSummary: Equatable, Codable, Sendable {
        public let inputHRSampleCount: Int
        public let normalizedHRSampleCount: Int
        public let duplicateHRTimestampsRemoved: Int
        public let inputGravitySampleCount: Int
        public let normalizedGravitySampleCount: Int
        public let duplicateGravityTimestampsRemoved: Int
        public let rejectedNonFiniteGravitySamples: Int
        public let availableRRIntervalCount: Int
        public let availableRespirationSampleCount: Int
        public let availableWristStatusCount: Int
        public let explicitWristOffIntervalCount: Int
        public let hrGaps: GapDiagnostics
        public let gravityGaps: GapDiagnostics
    }

    public enum Warning: String, Equatable, Hashable, Codable, Sendable {
        case duplicateHRTimestampsCanonicalized
        case duplicateGravityTimestampsCanonicalized
        case nonFiniteGravityRejected
        case largeHRGap
        case largeGravityGap
        case rrArchivedButNotUsedForBoundarySelection
        case respirationArchivedButNotUsedForBoundarySelection
        case wristStatusArchivedButNotInterpreted
        case unsealedArchiveRejected
    }

    public struct Provenance: Equatable, Codable, Sendable {
        public let algorithmID: String
        public let algorithmVersion: String
        public let candidateSource: String
        public let configurationIdentity: String
        public let timezoneOffsetSeconds: Int
        public let nightID: String?
        public let sourceStreamFingerprint: String?
        public let archiveWindowStartUnix: Int?
        public let archiveWindowEndUnix: Int?
    }

    public struct Result: Equatable, Codable, Sendable {
        public let status: Status
        public let candidates: [CandidateBoundary]
        public let primaryBoundary: CandidateBoundary?
        public let evidence: EvidenceSummary
        public let warnings: [Warning]
        public let provenance: Provenance
    }

    /// Run against a Night Lab archive projection. The manifest's recorded timezone is authoritative by
    /// default; an explicit override is allowed for controlled comparison experiments and is recorded in
    /// provenance. Unsealed manifests are rejected even if a caller manually constructed the streams value.
    ///
    /// RR/respiration/contact rows are included in evidence diagnostics but intentionally do not affect
    /// bootstrap boundary selection yet. `wristOffIntervals` stays explicit until archive contact-state raw
    /// values have a validated, version-stable semantic decoder.
    public static func detect(streams: NightLabArchivedStreams,
                              tzOffsetSeconds: Int? = nil,
                              wristOffIntervals: [(start: Int, end: Int)] = [],
                              configuration: Configuration = Configuration()) -> Result {
        let effectiveTimezoneOffset = tzOffsetSeconds ?? streams.manifest.timezoneOffsetSeconds
        let result = detect(hr: streams.hr,
                            gravity: streams.gravity,
                            tzOffsetSeconds: effectiveTimezoneOffset,
                            wristOffIntervals: wristOffIntervals,
                            availableRRIntervalCount: streams.rr.count,
                            availableRespirationSampleCount: streams.respiration.count,
                            availableWristStatusCount: streams.wristStatus.count,
                            archiveContext: ArchiveContext(nightID: streams.manifest.nightID,
                                                           sourceStreamFingerprint: streams.manifest.sourceStreamFingerprint,
                                                           windowStartUnix: streams.manifest.windowStartUnix,
                                                           windowEndUnix: streams.manifest.windowEndUnix),
                            configuration: configuration)
        guard streams.manifest.state == .sealed else {
            return Result(status: .invalidEvidence,
                          candidates: [],
                          primaryBoundary: nil,
                          evidence: result.evidence,
                          warnings: canonicalWarnings(result.warnings + [.unsealedArchiveRejected]),
                          provenance: result.provenance)
        }
        return result
    }

    /// Direct signal entry point for synthetic/property tests and future comparison benches.
    public static func detect(hr: [HRSample],
                              gravity: [GravitySample],
                              tzOffsetSeconds: Int = 0,
                              wristOffIntervals: [(start: Int, end: Int)] = [],
                              configuration: Configuration = Configuration()) -> Result {
        detect(hr: hr,
               gravity: gravity,
               tzOffsetSeconds: tzOffsetSeconds,
               wristOffIntervals: wristOffIntervals,
               availableRRIntervalCount: 0,
               availableRespirationSampleCount: 0,
               availableWristStatusCount: 0,
               archiveContext: nil,
               configuration: configuration)
    }

    private struct ArchiveContext {
        let nightID: String
        let sourceStreamFingerprint: String?
        let windowStartUnix: Int
        let windowEndUnix: Int
    }

    struct Normalized<T> {
        let samples: [T]
        let duplicateTimestampsRemoved: Int
        let rejectedSamples: Int
    }

    private static func detect(hr: [HRSample],
                               gravity: [GravitySample],
                               tzOffsetSeconds: Int,
                               wristOffIntervals: [(start: Int, end: Int)],
                               availableRRIntervalCount: Int,
                               availableRespirationSampleCount: Int,
                               availableWristStatusCount: Int,
                               archiveContext: ArchiveContext?,
                               configuration: Configuration) -> Result {
        let normalizedHR = normalizeHR(hr)
        let normalizedGravity = normalizeGravity(gravity)
        let normalizedWristOff = normalizeWristOffIntervals(wristOffIntervals)

        let evidence = EvidenceSummary(
            inputHRSampleCount: hr.count,
            normalizedHRSampleCount: normalizedHR.samples.count,
            duplicateHRTimestampsRemoved: normalizedHR.duplicateTimestampsRemoved,
            inputGravitySampleCount: gravity.count,
            normalizedGravitySampleCount: normalizedGravity.samples.count,
            duplicateGravityTimestampsRemoved: normalizedGravity.duplicateTimestampsRemoved,
            rejectedNonFiniteGravitySamples: normalizedGravity.rejectedSamples,
            availableRRIntervalCount: availableRRIntervalCount,
            availableRespirationSampleCount: availableRespirationSampleCount,
            availableWristStatusCount: availableWristStatusCount,
            explicitWristOffIntervalCount: normalizedWristOff.count,
            hrGaps: gapDiagnostics(timestamps: normalizedHR.samples.map(\.ts),
                                   threshold: configuration.diagnosticGapSeconds),
            gravityGaps: gapDiagnostics(timestamps: normalizedGravity.samples.map(\.ts),
                                        threshold: configuration.diagnosticGapSeconds)
        )

        var warnings: [Warning] = []
        if evidence.duplicateHRTimestampsRemoved > 0 { warnings.append(.duplicateHRTimestampsCanonicalized) }
        if evidence.duplicateGravityTimestampsRemoved > 0 { warnings.append(.duplicateGravityTimestampsCanonicalized) }
        if evidence.rejectedNonFiniteGravitySamples > 0 { warnings.append(.nonFiniteGravityRejected) }
        if evidence.hrGaps.gapCount > 0 { warnings.append(.largeHRGap) }
        if evidence.gravityGaps.gapCount > 0 { warnings.append(.largeGravityGap) }
        if availableRRIntervalCount > 0 { warnings.append(.rrArchivedButNotUsedForBoundarySelection) }
        if availableRespirationSampleCount > 0 { warnings.append(.respirationArchivedButNotUsedForBoundarySelection) }
        if availableWristStatusCount > 0 && normalizedWristOff.isEmpty {
            warnings.append(.wristStatusArchivedButNotInterpreted)
        }

        let provenance = Provenance(
            algorithmID: algorithmID,
            algorithmVersion: algorithmVersion,
            candidateSource: candidateSource,
            configurationIdentity: configuration.identity,
            timezoneOffsetSeconds: tzOffsetSeconds,
            nightID: archiveContext?.nightID,
            sourceStreamFingerprint: archiveContext?.sourceStreamFingerprint,
            archiveWindowStartUnix: archiveContext?.windowStartUnix,
            archiveWindowEndUnix: archiveContext?.windowEndUnix
        )

        let hadDetectorInput = !hr.isEmpty || !gravity.isEmpty
        let hasUsableDetectorInput = !normalizedHR.samples.isEmpty || !normalizedGravity.samples.isEmpty
        guard hasUsableDetectorInput else {
            return Result(status: hadDetectorInput ? .invalidEvidence : .insufficientEvidence,
                          candidates: [],
                          primaryBoundary: nil,
                          evidence: evidence,
                          warnings: canonicalWarnings(warnings),
                          provenance: provenance)
        }

        let sessions = bootstrapCandidates(hr: normalizedHR.samples,
                                           gravity: normalizedGravity.samples,
                                           tzOffsetSeconds: tzOffsetSeconds,
                                           wristOffIntervals: normalizedWristOff)
        let projected = sessions.map {
            CandidateBoundary(start: $0.start, end: $0.end, hrOnly: $0.hrOnly)
        }

        guard projected.allSatisfy({ $0.end > $0.start }) else {
            return Result(status: .invalidEvidence,
                          candidates: [],
                          primaryBoundary: nil,
                          evidence: evidence,
                          warnings: canonicalWarnings(warnings),
                          provenance: provenance)
        }

        let candidates = canonicalBoundaries(projected)
        guard !candidates.isEmpty else {
            return Result(status: .noPlausibleSleep,
                          candidates: [],
                          primaryBoundary: nil,
                          evidence: evidence,
                          warnings: canonicalWarnings(warnings),
                          provenance: provenance)
        }

        return Result(status: .detected,
                      candidates: candidates,
                      primaryBoundary: selectPrimary(from: candidates),
                      evidence: evidence,
                      warnings: canonicalWarnings(warnings),
                      provenance: provenance)
    }

    /// Bootstrap only: preserve all existing V1 candidate guards while Phase 2 builds the deterministic
    /// laboratory seam. No RR/respiration is supplied because this layer owns boundaries, not staging.
    /// `SleepStagerV2` is not invoked from here.
    static func bootstrapCandidates(hr: [HRSample],
                                    gravity: [GravitySample],
                                    tzOffsetSeconds: Int,
                                    wristOffIntervals: [(start: Int, end: Int)]) -> [SleepSession] {
        SleepStager.detectSleep(hr: hr,
                                gravity: gravity,
                                tzOffsetSeconds: tzOffsetSeconds,
                                wristOff: wristOffIntervals)
    }

    static func normalizeHR(_ samples: [HRSample]) -> Normalized<HRSample> {
        let sorted = samples.sorted {
            if $0.ts != $1.ts { return $0.ts < $1.ts }
            return $0.bpm < $1.bpm
        }
        var result: [HRSample] = []
        var index = 0
        while index < sorted.count {
            let timestamp = sorted[index].ts
            var end = index + 1
            while end < sorted.count && sorted[end].ts == timestamp { end += 1 }
            // Pick an existing median sample rather than averaging conflicting duplicates into invented data.
            result.append(sorted[index + (end - index) / 2])
            index = end
        }
        return Normalized(samples: result,
                          duplicateTimestampsRemoved: max(0, samples.count - result.count),
                          rejectedSamples: 0)
    }

    static func normalizeGravity(_ samples: [GravitySample]) -> Normalized<GravitySample> {
        let finite = samples.filter { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
        let sorted = finite.sorted {
            if $0.ts != $1.ts { return $0.ts < $1.ts }
            if $0.x.bitPattern != $1.x.bitPattern { return $0.x.bitPattern < $1.x.bitPattern }
            if $0.y.bitPattern != $1.y.bitPattern { return $0.y.bitPattern < $1.y.bitPattern }
            return $0.z.bitPattern < $1.z.bitPattern
        }
        var result: [GravitySample] = []
        var index = 0
        while index < sorted.count {
            let timestamp = sorted[index].ts
            var end = index + 1
            while end < sorted.count && sorted[end].ts == timestamp { end += 1 }
            result.append(sorted[index + (end - index) / 2])
            index = end
        }
        return Normalized(samples: result,
                          duplicateTimestampsRemoved: max(0, finite.count - result.count),
                          rejectedSamples: max(0, samples.count - finite.count))
    }

    static func normalizeWristOffIntervals(_ intervals: [(start: Int, end: Int)]) -> [(start: Int, end: Int)] {
        let sorted = intervals
            .filter { $0.end > $0.start }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.end < $1.end
            }
        guard var current = sorted.first else { return [] }
        var merged: [(start: Int, end: Int)] = []
        for interval in sorted.dropFirst() {
            if interval.start <= current.end {
                current.end = max(current.end, interval.end)
            } else {
                merged.append(current)
                current = interval
            }
        }
        merged.append(current)
        return merged
    }

    static func gapDiagnostics(timestamps: [Int], threshold: Int) -> GapDiagnostics {
        guard timestamps.count > 1 else { return GapDiagnostics(gapCount: 0, largestGapSeconds: 0) }
        var count = 0
        var largest = 0
        for pair in zip(timestamps, timestamps.dropFirst()) {
            let gap = max(0, pair.1 - pair.0)
            largest = max(largest, gap)
            if gap > threshold { count += 1 }
        }
        return GapDiagnostics(gapCount: count, largestGapSeconds: largest)
    }

    static func canonicalBoundaries(_ boundaries: [CandidateBoundary]) -> [CandidateBoundary] {
        Array(Set(boundaries)).sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return ($0.hrOnly ? 1 : 0) < ($1.hrOnly ? 1 : 0)
        }
    }

    static func selectPrimary(from candidates: [CandidateBoundary]) -> CandidateBoundary? {
        candidates.sorted {
            if $0.durationSeconds != $1.durationSeconds { return $0.durationSeconds > $1.durationSeconds }
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return ($0.hrOnly ? 1 : 0) < ($1.hrOnly ? 1 : 0)
        }.first
    }

    private static func canonicalWarnings(_ warnings: [Warning]) -> [Warning] {
        Array(Set(warnings)).sorted { $0.rawValue < $1.rawValue }
    }
}
