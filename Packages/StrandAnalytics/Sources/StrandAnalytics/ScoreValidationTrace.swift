import Foundation

/// Stable, human-readable evidence emitted by the Test Centre for field validation of NOOP's
/// experimental Energy Reserve and Training Readiness estimates.
///
/// This is deliberately a formatter over engine results, not another scoring path. It cannot mutate
/// health history and it never fills missing measurements. The resulting lines travel through the
/// existing Test Centre redaction, review and export pipeline.
public enum ScoreValidationTrace {
    public struct Snapshot: Sendable, Equatable {
        public let targetDay: String
        public let generatedAt: Date
        public let dayInterval: Range<Date>
        public let dailyRowCount: Int
        public let activityEventCount: Int
        public let wakeTimeAvailable: Bool
        public let energy: EnergyReserveEngine.Estimate
        public let readiness: ReadinessEngine.Readiness

        public init(targetDay: String, generatedAt: Date, dayInterval: Range<Date>,
                    dailyRowCount: Int, activityEventCount: Int, wakeTimeAvailable: Bool,
                    energy: EnergyReserveEngine.Estimate, readiness: ReadinessEngine.Readiness) {
            self.targetDay = targetDay
            self.generatedAt = generatedAt
            self.dayInterval = dayInterval
            self.dailyRowCount = dailyRowCount
            self.activityEventCount = activityEventCount
            self.wakeTimeAvailable = wakeTimeAvailable
            self.energy = energy
            self.readiness = readiness
        }
    }

    /// Versioned lines so a maintainer can compare two physical-device captures without guessing which
    /// fields changed. Absolute sensor values appear only where the readiness engine already emitted
    /// explicit evidence; absent values remain `missing`.
    public static func lines(_ snapshot: Snapshot) -> [String] {
        let dayLength = Int(snapshot.dayInterval.upperBound.timeIntervalSince(snapshot.dayInterval.lowerBound).rounded())
        var output = [
            "phase4ScoreContext schema=1 day=\(token(snapshot.targetDay)) generatedAtUnix=\(Int(snapshot.generatedAt.timeIntervalSince1970)) dayLengthS=\(dayLength) dailyRows=\(max(0, snapshot.dailyRowCount)) activityEvents=\(max(0, snapshot.activityEventCount)) wake=\(snapshot.wakeTimeAvailable ? \"present\" : \"missing\")",
            "phase4Energy estimated=true value=\(integer(snapshot.energy.value)) morning=\(integer(snapshot.energy.morningValue)) completeness=\(decimal(snapshot.energy.completeness, places: 3)) confidence=\(snapshot.energy.confidence.rawValue) trendPoints=\(snapshot.energy.trend.count)",
        ]

        for factor in snapshot.energy.factors {
            output.append("phase4EnergyFactor key=\(token(factor.key)) value=\(decimal(factor.value, places: 2)) weight=\(decimal(factor.weight, places: 3)) direction=\(factor.direction.rawValue)")
        }
        output.append("phase4EnergyMissing inputs=\(list(snapshot.energy.missingInputs))")
        for point in snapshot.energy.trend {
            let offset = Int(point.timestamp.timeIntervalSince(snapshot.dayInterval.lowerBound).rounded())
            output.append("phase4EnergyTrend source=\(point.source.rawValue) offsetS=\(offset) value=\(point.value)")
        }

        output.append("phase4Readiness estimated=true score=\(integer(snapshot.readiness.score)) level=\(snapshot.readiness.level.rawValue) completeness=\(decimal(snapshot.readiness.dataCompleteness, places: 3)) confidence=\(snapshot.readiness.confidence.rawValue) acwr=\(decimal(snapshot.readiness.acwr, places: 3)) monotony=\(decimal(snapshot.readiness.monotony, places: 3))")
        for signal in snapshot.readiness.signals {
            output.append("phase4ReadinessSignal key=\(token(signal.key)) flag=\(signal.flag.rawValue) evidence=\(quoted(signal.evidence ?? \"missing\")) detail=\(quoted(signal.detail))")
        }
        output.append("phase4Limitations medical=false energyEstimate=true readinessEstimate=true minuteByMinuteFabricated=false missingDataImputed=false")
        return output
    }

    private static let locale = Locale(identifier: "en_US_POSIX")

    private static func decimal(_ value: Double?, places: Int) -> String {
        guard let value, value.isFinite else { return "missing" }
        return String(format: "%.*f", locale: locale, places, value)
    }

    private static func integer(_ value: Int?) -> String { value.map(String.init) ?? "missing" }

    private static func list(_ values: [String]) -> String {
        values.isEmpty ? "none" : values.map(token).joined(separator: ",")
    }

    private static func token(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let result = String(scalars)
        return result.isEmpty ? "missing" : result
    }

    private static func quoted(_ value: String) -> String {
        let safe = value.replacingOccurrences(of: "\\", with: "'")
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "\"\(safe)\""
    }
}
