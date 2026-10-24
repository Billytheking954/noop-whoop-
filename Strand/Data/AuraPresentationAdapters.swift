import Foundation
import WhoopStore

// MARK: - Phase 2 Aura presentation boundary
//
// These pure mappings accept V2's existing records and explicitly supplied provenance.
// They cannot query Bluetooth, HealthKit or the database. A daily aggregate has a day key,
// NOT a measured timestamp. Never manufacture sample timestamps from its local midnight.

enum AuraPresentationState: Equatable {
    case loading
    case available
    case stale
    case unavailable
    case failed(String)
}

enum AuraValueKind: Equatable {
    case recordedAggregate
    case estimated
    case vendorDerived
    case unresolved
}

struct AuraDailyReading: Equatable {
    let value: Double?
    let unit: String
    let day: String?
    let measuredAt: Date?
    let sourceID: String?
    let kind: AuraValueKind
    let state: AuraPresentationState

    /// DailyMetric has no underlying sample timestamp. Report it as nil, not midnight.
    static func mapped(_ value: Double?, unit: String, day: String?, todayKey: String,
                       sourceID: String? = nil, kind: AuraValueKind = .recordedAggregate) -> Self {
        guard let value, value.isFinite, let day else {
            return Self(value: nil, unit: unit, day: day, measuredAt: nil,
                        sourceID: sourceID, kind: kind, state: .unavailable)
        }
        return Self(value: value, unit: unit, day: day, measuredAt: nil,
                    sourceID: sourceID, kind: kind,
                    state: day == todayKey ? .available : .stale)
    }
}

struct AuraTodayState: Equatable {
    let charge: AuraDailyReading
    let hrv: AuraDailyReading
    let restingHeartRate: AuraDailyReading
}

enum AuraTodayAdapter {
    static func map(_ day: DailyMetric?, todayKey: String, sourceID: String? = nil,
                    chargeKind: AuraValueKind = .unresolved) -> AuraTodayState {
        AuraTodayState(
            charge: .mapped(day?.recovery, unit: "%", day: day?.day, todayKey: todayKey,
                            sourceID: sourceID, kind: chargeKind),
            hrv: .mapped(day?.avgHrv, unit: "ms", day: day?.day, todayKey: todayKey,
                         sourceID: sourceID, kind: .recordedAggregate),
            restingHeartRate: .mapped(day?.restingHr.map(Double.init), unit: "bpm",
                                      day: day?.day, todayKey: todayKey,
                                      sourceID: sourceID, kind: .recordedAggregate)
        )
    }
}

struct AuraRestState: Equatable {
    let sleepMinutes: AuraDailyReading
    let sleepEfficiency: AuraDailyReading
    let deepMinutes: AuraDailyReading
    let remMinutes: AuraDailyReading
}

enum AuraRestAdapter {
    static func map(_ day: DailyMetric?, todayKey: String, sourceID: String? = nil,
                    stagesAreVendorDerived: Bool = false) -> AuraRestState {
        let kind: AuraValueKind = stagesAreVendorDerived ? .vendorDerived : .estimated
        return AuraRestState(
            sleepMinutes: .mapped(day?.totalSleepMin, unit: "min", day: day?.day, todayKey: todayKey,
                                  sourceID: sourceID, kind: .recordedAggregate),
            sleepEfficiency: .mapped(day?.efficiency.map { $0 * 100 }, unit: "%",
                                     day: day?.day, todayKey: todayKey,
                                     sourceID: sourceID, kind: .estimated),
            deepMinutes: .mapped(day?.deepMin, unit: "min", day: day?.day,
                                 todayKey: todayKey, sourceID: sourceID, kind: kind),
            remMinutes: .mapped(day?.remMin, unit: "min", day: day?.day,
                                todayKey: todayKey, sourceID: sourceID, kind: kind)
        )
    }
}

struct AuraFitnessState: Equatable {
    let effort: AuraDailyReading
    let steps: AuraDailyReading
}

enum AuraFitnessAdapter {
    static func map(_ day: DailyMetric?, todayKey: String, sourceID: String? = nil,
                    effortKind: AuraValueKind = .unresolved) -> AuraFitnessState {
        AuraFitnessState(
            effort: .mapped(day?.strain, unit: "/100", day: day?.day, todayKey: todayKey,
                            sourceID: sourceID, kind: effortKind),
            steps: .mapped(day?.steps.map(Double.init), unit: "steps", day: day?.day,
                           todayKey: todayKey, sourceID: sourceID)
        )
    }
}

struct AuraTrendSample: Equatable {
    let day: String
    let value: Double
    let sourceID: String?
}

enum AuraTrendsAdapter {
    enum Metric { case hrv, restingHeartRate, sleepMinutes, charge, effort }

    /// Only present real stored days. Gaps remain gaps; no interpolation or UTC-midnight synthesis.
    static func map(_ days: [DailyMetric], metric: Metric,
                    sourceID: String? = nil) -> [AuraTrendSample] {
        days.compactMap { day in
            let value: Double?
            switch metric {
            case .hrv: value = day.avgHrv
            case .restingHeartRate: value = day.restingHr.map(Double.init)
            case .sleepMinutes: value = day.totalSleepMin
            case .charge: value = day.recovery
            case .effort: value = day.strain
            }
            guard let value, value.isFinite else { return nil }
            return AuraTrendSample(day: day.day, value: value, sourceID: sourceID)
        }
    }
}

struct AuraDeviceState: Equatable {
    let batteryLabel: String
    let batterySourceID: String?
    let batteryMeasuredAt: Date?
    let state: AuraPresentationState
}

enum AuraDeviceAdapter {
    /// The existing V2 LiveState and DevicesView expose 0...100 percent, NOT a 0...1 fraction.
    /// Make the source contract explicit so a perfectly valid 86% never becomes unavailable.
    /// A cached battery must never silently display as today's live status.
    static func mapBatteryPercent(_ percent: Double?, connected: Bool, measuredAt: Date?,
                                  now: Date, sourceID: String?, maxAge: TimeInterval = 15 * 60) -> AuraDeviceState {
        guard let percent, percent.isFinite, (0...100).contains(percent) else {
            return AuraDeviceState(batteryLabel: "—", batterySourceID: sourceID,
                                   batteryMeasuredAt: measuredAt, state: .unavailable)
        }
        let label = "\(Int(percent.rounded()))%"
        let fresh = connected && measuredAt.map { $0 <= now && now.timeIntervalSince($0) <= maxAge } == true
        return AuraDeviceState(batteryLabel: label, batterySourceID: sourceID,
                               batteryMeasuredAt: measuredAt, state: fresh ? .available : .stale)
    }

    /// Retain an explicit fractional entry point for callers that truly supply 0...1.
    static func mapBattery(_ fraction: Double?, connected: Bool, measuredAt: Date?,
                           now: Date, sourceID: String?, maxAge: TimeInterval = 15 * 60) -> AuraDeviceState {
        guard let fraction, fraction.isFinite, (0...1).contains(fraction) else {
            return mapBatteryPercent(nil, connected: connected, measuredAt: measuredAt,
                                     now: now, sourceID: sourceID, maxAge: maxAge)
        }
        return mapBatteryPercent(fraction * 100, connected: connected, measuredAt: measuredAt,
                                 now: now, sourceID: sourceID, maxAge: maxAge)
    }
}
