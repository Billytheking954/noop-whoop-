import Foundation
import WhoopProtocol

extension NightLabSleepDetectorV2 {
    enum ExperimentalIdentity {
        static let algorithmID = "nightlab.sleep-detection-v2-independent"
        static let algorithmVersion = "0.2.0-motion-hr-shadow"
        static let candidateSource = "nightlab.motion-hr-window-v1"
    }

    struct ExperimentalConfiguration: Equatable, Sendable {
        let windowSeconds: Int
        let minimumCandidateSeconds: Int
        let minimumGravityCoverage: Double
        let minimumHRCoverage: Double
        let maximumRepresentedSampleSeconds: Int
        let maximumBridgeWindows: Int
        let minimumAwakeCalibrationWindows: Int
        let maximumCandidateToAwakeHRRatio: Double
        let maximumWristOffFraction: Double

        init(windowSeconds: Int = 5 * 60,
             minimumCandidateSeconds: Int = 20 * 60,
             minimumGravityCoverage: Double = 0.65,
             minimumHRCoverage: Double = 0.50,
             maximumRepresentedSampleSeconds: Int = 60,
             maximumBridgeWindows: Int = 1,
             minimumAwakeCalibrationWindows: Int = 2,
             maximumCandidateToAwakeHRRatio: Double = 0.95,
             maximumWristOffFraction: Double = 0.25) {
            self.windowSeconds = max(60, windowSeconds)
            self.minimumCandidateSeconds = max(60, minimumCandidateSeconds)
            self.minimumGravityCoverage = min(1, max(0, minimumGravityCoverage))
            self.minimumHRCoverage = min(1, max(0, minimumHRCoverage))
            self.maximumRepresentedSampleSeconds = max(1, maximumRepresentedSampleSeconds)
            self.maximumBridgeWindows = max(0, maximumBridgeWindows)
            self.minimumAwakeCalibrationWindows = max(1, minimumAwakeCalibrationWindows)
            self.maximumCandidateToAwakeHRRatio = min(1, max(0, maximumCandidateToAwakeHRRatio))
            self.maximumWristOffFraction = min(1, max(0, maximumWristOffFraction))
        }

        var identity: String {
            [
                "window=\(windowSeconds)s",
                "min-candidate=\(minimumCandidateSeconds)s",
                "gravity-coverage=\(minimumGravityCoverage)",
                "hr-coverage=\(minimumHRCoverage)",
                "sample-cap=\(maximumRepresentedSampleSeconds)s",
                "bridge=\(maximumBridgeWindows)",
                "awake-calibration=\(minimumAwakeCalibrationWindows)",
                "hr-ratio=\(maximumCandidateToAwakeHRRatio)",
                "wrist-off=\(maximumWristOffFraction)",
            ].joined(separator: ";")
        }
    }

    enum ExperimentalBlocker: String, Equatable, Sendable {
        case unsealedArchive
        case missingGravity
        case invalidGravity
        case missingHeartRate
        case insufficientMotionCoverage
        case noMotionContrast
        case missingAwakeHRCalibration
    }

    enum ExperimentalRejectionReason: String, Equatable, Hashable, Sendable {
        case tooShort
        case insufficientGravityCoverage
        case insufficientHRCoverage
        case missingHeartRateSummary
        case insufficientHeartRateDip
        case excessiveWristOff
    }

    struct ExperimentalCandidateDiagnostic: Equatable, Sendable {
        let boundary: CandidateBoundary
        let gravityCoverageFraction: Double
        let hrCoverageFraction: Double
        let medianMovementDeltaG: Double?
        let medianHR: Double?
        let awakeHRReference: Double
        let wristOffFraction: Double
        let rejectionReasons: [ExperimentalRejectionReason]

        var accepted: Bool { rejectionReasons.isEmpty }
    }

    struct ExperimentalProvenance: Equatable, Sendable {
        let algorithmID: String
        let algorithmVersion: String
        let candidateSource: String
        let configurationIdentity: String
        let timezoneOffsetSeconds: Int
        let nightID: String?
        let sourceStreamFingerprint: String?
    }

    struct ExperimentalResult: Equatable, Sendable {
        let status: Status
        let candidates: [CandidateBoundary]
        let primaryBoundary: CandidateBoundary?
        let diagnostics: [ExperimentalCandidateDiagnostic]
        let blocker: ExperimentalBlocker?
        let provenance: ExperimentalProvenance
    }

    enum ShadowDisagreement: String, Equatable, Sendable {
        case none
        case statusDifference
        case v1Only
        case v2Only
        case candidateCount
        case boundaryShift
    }

    struct ShadowComparison: Equatable, Sendable {
        let v1: Result
        let v2: ExperimentalResult
        let startDifferenceSeconds: Int?
        let endDifferenceSeconds: Int?
        let durationDifferenceSeconds: Int?
        let disagreement: ShadowDisagreement
    }

    private struct ExperimentalWindow {
        let start: Int
        let end: Int
        let gravityCoverage: Double
        let hrCoverage: Double
        let medianMovementDeltaG: Double?
        let medianHR: Double?
    }

    static func detectIndependentCandidates(
        streams: NightLabArchivedStreams,
        tzOffsetSeconds: Int? = nil,
        wristOffIntervals: [(start: Int, end: Int)] = [],
        configuration: ExperimentalConfiguration = ExperimentalConfiguration()
    ) -> ExperimentalResult {
        let effectiveTimezone = tzOffsetSeconds ?? streams.manifest.timezoneOffsetSeconds
        let base = detectIndependentCandidates(
            hr: streams.hr,
            gravity: streams.gravity,
            tzOffsetSeconds: effectiveTimezone,
            wristOffIntervals: wristOffIntervals,
            configuration: configuration,
            nightID: streams.manifest.nightID,
            sourceStreamFingerprint: streams.manifest.sourceStreamFingerprint
        )
        guard streams.manifest.state == .sealed else {
            return ExperimentalResult(
                status: .invalidEvidence,
                candidates: [],
                primaryBoundary: nil,
                diagnostics: [],
                blocker: .unsealedArchive,
                provenance: base.provenance
            )
        }
        return base
    }

    static func detectIndependentCandidates(
        hr: [HRSample],
        gravity: [GravitySample],
        tzOffsetSeconds: Int = 0,
        wristOffIntervals: [(start: Int, end: Int)] = [],
        configuration: ExperimentalConfiguration = ExperimentalConfiguration()
    ) -> ExperimentalResult {
        detectIndependentCandidates(
            hr: hr,
            gravity: gravity,
            tzOffsetSeconds: tzOffsetSeconds,
            wristOffIntervals: wristOffIntervals,
            configuration: configuration,
            nightID: nil,
            sourceStreamFingerprint: nil
        )
    }

    static func shadowCompare(
        streams: NightLabArchivedStreams,
        tzOffsetSeconds: Int? = nil,
        wristOffIntervals: [(start: Int, end: Int)] = [],
        configuration: ExperimentalConfiguration = ExperimentalConfiguration()
    ) -> ShadowComparison {
        let effectiveTimezone = tzOffsetSeconds ?? streams.manifest.timezoneOffsetSeconds
        let v1 = detect(
            streams: streams,
            tzOffsetSeconds: effectiveTimezone,
            wristOffIntervals: wristOffIntervals
        )
        let v2 = detectIndependentCandidates(
            streams: streams,
            tzOffsetSeconds: effectiveTimezone,
            wristOffIntervals: wristOffIntervals,
            configuration: configuration
        )
        return makeShadowComparison(v1: v1, v2: v2)
    }

    static func shadowCompare(
        hr: [HRSample],
        gravity: [GravitySample],
        tzOffsetSeconds: Int = 0,
        wristOffIntervals: [(start: Int, end: Int)] = [],
        configuration: ExperimentalConfiguration = ExperimentalConfiguration()
    ) -> ShadowComparison {
        let v1 = detect(
            hr: hr,
            gravity: gravity,
            tzOffsetSeconds: tzOffsetSeconds,
            wristOffIntervals: wristOffIntervals
        )
        let v2 = detectIndependentCandidates(
            hr: hr,
            gravity: gravity,
            tzOffsetSeconds: tzOffsetSeconds,
            wristOffIntervals: wristOffIntervals,
            configuration: configuration
        )
        return makeShadowComparison(v1: v1, v2: v2)
    }

    private static func detectIndependentCandidates(
        hr: [HRSample],
        gravity: [GravitySample],
        tzOffsetSeconds: Int,
        wristOffIntervals: [(start: Int, end: Int)],
        configuration: ExperimentalConfiguration,
        nightID: String?,
        sourceStreamFingerprint: String?
    ) -> ExperimentalResult {
        let provenance = ExperimentalProvenance(
            algorithmID: ExperimentalIdentity.algorithmID,
            algorithmVersion: ExperimentalIdentity.algorithmVersion,
            candidateSource: ExperimentalIdentity.candidateSource,
            configurationIdentity: configuration.identity,
            timezoneOffsetSeconds: tzOffsetSeconds,
            nightID: nightID,
            sourceStreamFingerprint: sourceStreamFingerprint
        )

        guard !gravity.isEmpty else {
            return ExperimentalResult(status: .insufficientEvidence,
                                      candidates: [], primaryBoundary: nil, diagnostics: [],
                                      blocker: .missingGravity, provenance: provenance)
        }

        let normalizedGravity = normalizeGravity(gravity)
        guard !normalizedGravity.samples.isEmpty else {
            return ExperimentalResult(status: .invalidEvidence,
                                      candidates: [], primaryBoundary: nil, diagnostics: [],
                                      blocker: .invalidGravity, provenance: provenance)
        }
        guard normalizedGravity.samples.count >= 2 else {
            return ExperimentalResult(status: .insufficientEvidence,
                                      candidates: [], primaryBoundary: nil, diagnostics: [],
                                      blocker: .insufficientMotionCoverage, provenance: provenance)
        }

        guard !hr.isEmpty else {
            return ExperimentalResult(status: .insufficientEvidence,
                                      candidates: [], primaryBoundary: nil, diagnostics: [],
                                      blocker: .missingHeartRate, provenance: provenance)
        }
        let normalizedHR = normalizeHR(hr).samples
        guard !normalizedHR.isEmpty else {
            return ExperimentalResult(status: .insufficientEvidence,
                                      candidates: [], primaryBoundary: nil, diagnostics: [],
                                      blocker: .missingHeartRate, provenance: provenance)
        }

        let normalizedWristOff = normalizeWristOffIntervals(wristOffIntervals)
        let gravitySpacing = experimentalTypicalSpacing(
            normalizedGravity.samples.map(\.ts),
            cap: configuration.maximumRepresentedSampleSeconds
        )
        let hrSpacing = experimentalTypicalSpacing(
            normalizedHR.map(\.ts),
            cap: configuration.maximumRepresentedSampleSeconds
        )
        guard let gravitySpacing else {
            return ExperimentalResult(status: .insufficientEvidence,
                                      candidates: [], primaryBoundary: nil, diagnostics: [],
                                      blocker: .insufficientMotionCoverage, provenance: provenance)
        }
        guard let hrSpacing else {
            return ExperimentalResult(status: .insufficientEvidence,
                                      candidates: [], primaryBoundary: nil, diagnostics: [],
                                      blocker: .missingHeartRate, provenance: provenance)
        }

        let windows = experimentalWindows(
            hr: normalizedHR,
            gravity: normalizedGravity.samples,
            gravitySpacing: gravitySpacing,
            hrSpacing: hrSpacing,
            configuration: configuration
        )
        let usableMotion = windows.compactMap { window -> Double? in
            guard window.gravityCoverage >= configuration.minimumGravityCoverage else { return nil }
            return window.medianMovementDeltaG
        }
        guard usableMotion.count >= 3 else {
            return ExperimentalResult(status: .insufficientEvidence,
                                      candidates: [], primaryBoundary: nil, diagnostics: [],
                                      blocker: .insufficientMotionCoverage, provenance: provenance)
        }

        let motionFloor = experimentalQuantile(usableMotion, q: 0.20)
        let motionCeiling = experimentalQuantile(usableMotion, q: 0.95)
        let separation = motionCeiling - motionFloor
        guard separation.isFinite, separation > max(1e-6, abs(motionCeiling) * 0.05) else {
            return ExperimentalResult(status: .insufficientEvidence,
                                      candidates: [], primaryBoundary: nil, diagnostics: [],
                                      blocker: .noMotionContrast, provenance: provenance)
        }
        let quietThreshold = motionFloor + separation * 0.20
        let activeThreshold = motionFloor + separation * 0.80

        let awakeHRWindows = windows.compactMap { window -> Double? in
            guard window.gravityCoverage >= configuration.minimumGravityCoverage,
                  window.hrCoverage >= configuration.minimumHRCoverage,
                  let movement = window.medianMovementDeltaG,
                  movement >= activeThreshold,
                  let medianHR = window.medianHR else { return nil }
            return medianHR
        }
        guard awakeHRWindows.count >= configuration.minimumAwakeCalibrationWindows else {
            return ExperimentalResult(status: .insufficientEvidence,
                                      candidates: [], primaryBoundary: nil, diagnostics: [],
                                      blocker: .missingAwakeHRCalibration, provenance: provenance)
        }
        let awakeHRReference = experimentalMedian(awakeHRWindows)

        let quietIndices = windows.indices.filter { index in
            let window = windows[index]
            guard window.gravityCoverage >= configuration.minimumGravityCoverage,
                  let movement = window.medianMovementDeltaG else { return false }
            return movement <= quietThreshold
        }
        let groups = experimentalQuietGroups(
            quietIndices: quietIndices,
            windows: windows,
            configuration: configuration
        )

        var diagnostics: [ExperimentalCandidateDiagnostic] = []
        for group in groups {
            guard let firstIndex = group.first, let lastIndex = group.last else { continue }
            let start = windows[firstIndex].start
            let end = windows[lastIndex].end
            guard end > start else { continue }
            let boundary = CandidateBoundary(start: start, end: end, hrOnly: false)

            let gravityTimestamps = normalizedGravity.samples
                .filter { $0.ts >= start && $0.ts < end }
                .map(\.ts)
            let hrRows = normalizedHR.filter { $0.ts >= start && $0.ts < end }
            let hrTimestamps = hrRows.map(\.ts)
            let gravityCoverage = experimentalCoverageFraction(
                timestamps: gravityTimestamps,
                representedSeconds: gravitySpacing,
                start: start,
                end: end
            )
            let hrCoverage = experimentalCoverageFraction(
                timestamps: hrTimestamps,
                representedSeconds: hrSpacing,
                start: start,
                end: end
            )
            let movementValues = windows[firstIndex...lastIndex].compactMap(\.medianMovementDeltaG)
            let medianMovement = movementValues.isEmpty ? nil : experimentalMedian(movementValues)
            let medianHR = hrRows.isEmpty ? nil : experimentalMedian(hrRows.map { Double($0.bpm) })
            let wristOffFraction = experimentalWristOffFraction(
                start: start,
                end: end,
                intervals: normalizedWristOff
            )

            var rejectionReasons: [ExperimentalRejectionReason] = []
            if boundary.durationSeconds < configuration.minimumCandidateSeconds {
                rejectionReasons.append(.tooShort)
            }
            if gravityCoverage < configuration.minimumGravityCoverage {
                rejectionReasons.append(.insufficientGravityCoverage)
            }
            if hrCoverage < configuration.minimumHRCoverage {
                rejectionReasons.append(.insufficientHRCoverage)
            }
            if wristOffFraction > configuration.maximumWristOffFraction {
                rejectionReasons.append(.excessiveWristOff)
            }
            if let medianHR {
                if medianHR > awakeHRReference * configuration.maximumCandidateToAwakeHRRatio {
                    rejectionReasons.append(.insufficientHeartRateDip)
                }
            } else {
                rejectionReasons.append(.missingHeartRateSummary)
            }

            diagnostics.append(
                ExperimentalCandidateDiagnostic(
                    boundary: boundary,
                    gravityCoverageFraction: gravityCoverage,
                    hrCoverageFraction: hrCoverage,
                    medianMovementDeltaG: medianMovement,
                    medianHR: medianHR,
                    awakeHRReference: awakeHRReference,
                    wristOffFraction: wristOffFraction,
                    rejectionReasons: Array(Set(rejectionReasons)).sorted { $0.rawValue < $1.rawValue }
                )
            )
        }

        let candidates = canonicalBoundaries(
            diagnostics.filter(\.accepted).map(\.boundary)
        )
        let status: Status = candidates.isEmpty ? .noPlausibleSleep : .detected
        return ExperimentalResult(
            status: status,
            candidates: candidates,
            primaryBoundary: selectPrimary(from: candidates),
            diagnostics: diagnostics.sorted {
                if $0.boundary.start != $1.boundary.start { return $0.boundary.start < $1.boundary.start }
                return $0.boundary.end < $1.boundary.end
            },
            blocker: nil,
            provenance: provenance
        )
    }

    private static func experimentalWindows(
        hr: [HRSample],
        gravity: [GravitySample],
        gravitySpacing: Int,
        hrSpacing: Int,
        configuration: ExperimentalConfiguration
    ) -> [ExperimentalWindow] {
        guard let firstGravity = gravity.first, let lastGravity = gravity.last else { return [] }
        let width = configuration.windowSeconds
        var start = experimentalGridFloor(firstGravity.ts, width: width)
        let endExclusive = lastGravity.ts + gravitySpacing
        var windows: [ExperimentalWindow] = []

        while start < endExclusive {
            let end = start + width
            let gravityRows = gravity.filter { $0.ts >= start && $0.ts < end }
            let hrRows = hr.filter { $0.ts >= start && $0.ts < end }
            let gravityCoverage = experimentalCoverageFraction(
                timestamps: gravityRows.map(\.ts),
                representedSeconds: gravitySpacing,
                start: start,
                end: end
            )
            let hrCoverage = experimentalCoverageFraction(
                timestamps: hrRows.map(\.ts),
                representedSeconds: hrSpacing,
                start: start,
                end: end
            )
            let motion = experimentalMedianMovement(
                gravityRows,
                maximumPairGapSeconds: min(width, max(5, gravitySpacing * 4))
            )
            let medianHR = hrRows.isEmpty ? nil : experimentalMedian(hrRows.map { Double($0.bpm) })
            windows.append(
                ExperimentalWindow(
                    start: start,
                    end: end,
                    gravityCoverage: gravityCoverage,
                    hrCoverage: hrCoverage,
                    medianMovementDeltaG: motion,
                    medianHR: medianHR
                )
            )
            start += width
        }
        return windows
    }

    private static func experimentalQuietGroups(
        quietIndices: [Int],
        windows: [ExperimentalWindow],
        configuration: ExperimentalConfiguration
    ) -> [[Int]] {
        guard let first = quietIndices.first else { return [] }
        var groups: [[Int]] = [[first]]
        var previousQuiet = first

        for nextQuiet in quietIndices.dropFirst() {
            let gapCount = max(0, nextQuiet - previousQuiet - 1)
            let intermediates = gapCount == 0 ? [] : Array((previousQuiet + 1)..<nextQuiet)
            let bridgeable = gapCount <= configuration.maximumBridgeWindows
                && intermediates.allSatisfy { index in
                    let window = windows[index]
                    return window.gravityCoverage >= configuration.minimumGravityCoverage
                        && window.medianMovementDeltaG != nil
                }
            if nextQuiet == previousQuiet + 1 || bridgeable {
                groups[groups.count - 1].append(nextQuiet)
            } else {
                groups.append([nextQuiet])
            }
            previousQuiet = nextQuiet
        }
        return groups
    }

    private static func experimentalMedianMovement(
        _ samples: [GravitySample],
        maximumPairGapSeconds: Int
    ) -> Double? {
        guard samples.count >= 2 else { return nil }
        let sorted = samples.sorted { $0.ts < $1.ts }
        var deltas: [Double] = []
        deltas.reserveCapacity(sorted.count - 1)
        for pair in zip(sorted, sorted.dropFirst()) {
            let dt = pair.1.ts - pair.0.ts
            guard dt > 0, dt <= maximumPairGapSeconds else { continue }
            let dx = pair.1.x - pair.0.x
            let dy = pair.1.y - pair.0.y
            let dz = pair.1.z - pair.0.z
            let delta = sqrt(dx * dx + dy * dy + dz * dz)
            if delta.isFinite { deltas.append(delta) }
        }
        return deltas.isEmpty ? nil : experimentalMedian(deltas)
    }

    private static func experimentalTypicalSpacing(_ timestamps: [Int], cap: Int) -> Int? {
        let sorted = Array(Set(timestamps)).sorted()
        guard sorted.count >= 2 else { return nil }
        let deltas = zip(sorted, sorted.dropFirst())
            .map { $0.1 - $0.0 }
            .filter { $0 > 0 }
            .sorted()
        guard !deltas.isEmpty else { return nil }
        let median = deltas[deltas.count / 2]
        return min(max(1, cap), max(1, median))
    }

    private static func experimentalCoverageFraction(
        timestamps: [Int],
        representedSeconds: Int,
        start: Int,
        end: Int
    ) -> Double {
        guard end > start, !timestamps.isEmpty else { return 0 }
        let width = end - start
        let represented = max(1, representedSeconds)
        let before = represented / 2
        let after = represented - before
        var intervals: [(start: Int, end: Int)] = timestamps.sorted().compactMap { timestamp in
            let lower = max(start, timestamp - before)
            let upper = min(end, timestamp + after)
            return upper > lower ? (start: lower, end: upper) : nil
        }
        guard !intervals.isEmpty else { return 0 }
        intervals.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }
        var covered = 0
        var current = intervals[0]
        for interval in intervals.dropFirst() {
            if interval.start <= current.end {
                current.end = max(current.end, interval.end)
            } else {
                covered += current.end - current.start
                current = interval
            }
        }
        covered += current.end - current.start
        return min(1, max(0, Double(covered) / Double(width)))
    }

    private static func experimentalWristOffFraction(
        start: Int,
        end: Int,
        intervals: [(start: Int, end: Int)]
    ) -> Double {
        guard end > start else { return 0 }
        let clipped = intervals.compactMap { interval -> (start: Int, end: Int)? in
            let lower = max(start, interval.start)
            let upper = min(end, interval.end)
            return upper > lower ? (start: lower, end: upper) : nil
        }
        guard !clipped.isEmpty else { return 0 }
        let normalized = normalizeWristOffIntervals(clipped)
        let covered = normalized.reduce(0) { $0 + ($1.end - $1.start) }
        return min(1, max(0, Double(covered) / Double(end - start)))
    }

    private static func experimentalMedian(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func experimentalQuantile(_ values: [Double], q: Double) -> Double {
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted.first ?? 0 }
        let clamped = min(1, max(0, q))
        let position = clamped * Double(sorted.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        if lower == upper { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    private static func experimentalGridFloor(_ timestamp: Int, width: Int) -> Int {
        let remainder = ((timestamp % width) + width) % width
        return timestamp - remainder
    }

    private static func makeShadowComparison(v1: Result, v2: ExperimentalResult) -> ShadowComparison {
        let v1Primary = v1.primaryBoundary
        let v2Primary = v2.primaryBoundary
        let startDifference = zipOptional(v1Primary?.start, v2Primary?.start).map { $1 - $0 }
        let endDifference = zipOptional(v1Primary?.end, v2Primary?.end).map { $1 - $0 }
        let durationDifference = zipOptional(v1Primary?.durationSeconds, v2Primary?.durationSeconds).map { $1 - $0 }

        let disagreement: ShadowDisagreement
        if v1.status == .detected && v2.status != .detected {
            disagreement = .v1Only
        } else if v1.status != .detected && v2.status == .detected {
            disagreement = .v2Only
        } else if v1.status != v2.status {
            disagreement = .statusDifference
        } else if v1.candidates.count != v2.candidates.count {
            disagreement = .candidateCount
        } else if v1Primary != v2Primary {
            disagreement = .boundaryShift
        } else {
            disagreement = .none
        }

        return ShadowComparison(
            v1: v1,
            v2: v2,
            startDifferenceSeconds: startDifference,
            endDifferenceSeconds: endDifference,
            durationDifferenceSeconds: durationDifference,
            disagreement: disagreement
        )
    }

    private static func zipOptional<T>(_ left: T?, _ right: T?) -> (T, T)? {
        guard let left, let right else { return nil }
        return (left, right)
    }
}
