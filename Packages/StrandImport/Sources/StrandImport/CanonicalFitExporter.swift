import Foundation

/// Deterministic FIT export for ``CanonicalWorkout``.
///
/// The existing `RouteExporter` predates the canonical workout model and interpolates timestamps for
/// a lat/lon-only stored route. This exporter deliberately does NOT do that. FIT record messages are
/// emitted only for genuinely timestamped canonical samples. Untimed route points remain represented
/// in the canonical workout but are omitted from FIT rather than being given invented times.
public enum CanonicalFitExporter {
    public struct Export: Sendable, Equatable {
        public let data: Data
        public let externalID: String
        public let recordCount: Int
        public let omittedUntimedRoutePointCount: Int
        /// Garmin's activity recipe expects record messages, and Strava needs timed records for a useful
        /// activity. A summary-only workout can still be encoded losslessly as session/lap metadata, but
        /// it is not claimed to be ready for upload until at least one genuine timed record exists.
        public let stravaUploadReady: Bool
    }

    private struct RecordRow {
        var timestamp: Int
        var latitude: Double?
        var longitude: Double?
        var altitudeM: Double?
        var heartRateBpm: Int?
        var cadenceRpm: Int?
        var distanceM: Double?
        var speedMps: Double?
        var powerWatts: Int?
    }

    private struct FitField {
        let number: Int
        let baseType: Int
        let bytes: [UInt8]
    }

    public static func render(_ workout: CanonicalWorkout) -> Export {
        let records = canonicalRecords(workout)
        let timedRouteCount = workout.route.reduce(into: 0) { if $1.timestamp != nil { $0 += 1 } }
        let omittedRouteCount = workout.route.count - timedRouteCount
        var body: [UInt8] = []

        // file_id (global 0). 255 is FIT's development manufacturer value. We deliberately omit product
        // and serial rather than pretending to be WHOOP, Apple, Garmin, or another registered vendor.
        emit(&body, local: 0, global: 0, fields: [
            enum8(0, 4),
            uint16(1, 255),
            uint32(4, fitTime(workout.startTimestamp))
        ])

        // One definition per record is a little larger than reusing a superset definition, but it lets
        // absent measurements be genuinely absent instead of encoded as plausible-looking sentinels.
        for record in records {
            var fields: [FitField] = [uint32(253, fitTime(record.timestamp))]
            if let latitude = record.latitude, let longitude = record.longitude {
                fields.append(sint32(0, semicircles(latitude)))
                fields.append(sint32(1, semicircles(longitude)))
            }
            if let altitudeM = finiteNonnegativeOrSigned(record.altitudeM) {
                fields.append(uint16(2, scaledAltitude(altitudeM)))
            }
            if let heartRateBpm = record.heartRateBpm, heartRateBpm > 0, heartRateBpm < 255 {
                fields.append(uint8(3, heartRateBpm))
            }
            if let cadenceRpm = record.cadenceRpm, cadenceRpm >= 0, cadenceRpm < 255 {
                fields.append(uint8(4, cadenceRpm))
            }
            if let distanceM = finiteNonnegative(record.distanceM) {
                fields.append(uint32(5, scaledUInt32(distanceM, scale: 100)))
            }
            if let speedMps = finiteNonnegative(record.speedMps) {
                fields.append(uint16(6, scaledUInt16(speedMps, scale: 1000)))
            }
            if let powerWatts = record.powerWatts, powerWatts >= 0, powerWatts < 65_535 {
                fields.append(uint16(7, UInt16(powerWatts)))
            }
            emit(&body, local: 1, global: 20, fields: fields)
        }

        let laps = workout.laps.isEmpty ? [wholeWorkoutLap(workout)] : workout.laps
        for lap in laps {
            emit(&body, local: 2, global: 19, fields: lapFields(lap, sport: workout.sport))
        }

        emit(&body, local: 3, global: 18, fields: sessionFields(workout, lapCount: laps.count))

        // activity (global 34): timestamp, number of sessions, type=manual. "manual" here is the FIT
        // activity message trigger/type, not provenance of the underlying workout.
        emit(&body, local: 4, global: 34, fields: [
            uint32(253, fitTime(workout.endTimestamp)),
            uint16(1, 1),
            enum8(2, 0)
        ])

        var out: [UInt8] = []
        appendUInt8(&out, 12)
        appendUInt8(&out, 0x20)
        appendUInt16(&out, 2140)
        appendUInt32(&out, UInt32(body.count))
        out.append(contentsOf: Array(".FIT".utf8))
        out.append(contentsOf: body)
        appendUInt16(&out, UInt16(RouteExporter.fitCrc(out)))

        return Export(data: Data(out),
                      externalID: workout.externalID,
                      recordCount: records.count,
                      omittedUntimedRoutePointCount: omittedRouteCount,
                      stravaUploadReady: !records.isEmpty)
    }

    // MARK: - Canonical stream

    private static func canonicalRecords(_ workout: CanonicalWorkout) -> [RecordRow] {
        // Merge already-canonical measurements by their real timestamp. This is NOT cross-source source
        // resolution: the caller has already decided what belongs in CanonicalWorkout and each field kept
        // provenance there. Here we merely avoid writing two FIT records for the same second when a route
        // fix and the canonical HR stream coincide.
        //
        // Corrupt/out-of-window samples are omitted rather than turned into plausible FIT data. A Record
        // message must contain timestamp PLUS at least one actual measurement, so timestamp-only rows are
        // filtered at the end after route and HR streams have had a chance to merge.
        var byTimestamp: [Int: RecordRow] = [:]

        for point in workout.route {
            guard let timestamp = point.timestamp,
                  timestamp >= workout.startTimestamp,
                  timestamp <= workout.endTimestamp else { continue }
            byTimestamp[timestamp] = RecordRow(
                timestamp: timestamp,
                latitude: validLatitude(point.latitude) ? point.latitude : nil,
                longitude: validLongitude(point.longitude) ? point.longitude : nil,
                altitudeM: point.altitudeM,
                heartRateBpm: point.heartRateBpm,
                cadenceRpm: point.cadenceRpm,
                distanceM: point.distanceM,
                speedMps: point.speedMps,
                powerWatts: point.powerWatts
            )
        }

        for sample in workout.heartRateSamples
        where sample.timestamp >= workout.startTimestamp
            && sample.timestamp <= workout.endTimestamp
            && sample.bpm > 0 && sample.bpm < 255 {
            if var existing = byTimestamp[sample.timestamp] {
                if existing.heartRateBpm == nil { existing.heartRateBpm = sample.bpm }
                byTimestamp[sample.timestamp] = existing
            } else {
                byTimestamp[sample.timestamp] = RecordRow(
                    timestamp: sample.timestamp,
                    latitude: nil,
                    longitude: nil,
                    altitudeM: nil,
                    heartRateBpm: sample.bpm,
                    cadenceRpm: nil,
                    distanceM: nil,
                    speedMps: nil,
                    powerWatts: nil
                )
            }
        }

        return byTimestamp.values
            .filter(hasMeasurement)
            .sorted { $0.timestamp < $1.timestamp }
    }

    private static func hasMeasurement(_ record: RecordRow) -> Bool {
        let hasPosition = record.latitude.map(validLatitude) == true
            && record.longitude.map(validLongitude) == true
        let hasAltitude = finiteNonnegativeOrSigned(record.altitudeM) != nil
        let hasHeartRate = record.heartRateBpm.map { $0 > 0 && $0 < 255 } == true
        let hasCadence = record.cadenceRpm.map { $0 >= 0 && $0 < 255 } == true
        let hasDistance = finiteNonnegative(record.distanceM) != nil
        let hasSpeed = finiteNonnegative(record.speedMps) != nil
        let hasPower = record.powerWatts.map { $0 >= 0 && $0 < 65_535 } == true
        return hasPosition || hasAltitude || hasHeartRate || hasCadence
            || hasDistance || hasSpeed || hasPower
    }

    private static func wholeWorkoutLap(_ w: CanonicalWorkout) -> CanonicalWorkout.Lap {
        CanonicalWorkout.Lap(
            startTimestamp: w.startTimestamp,
            endTimestamp: w.endTimestamp,
            elapsedDurationS: w.elapsedDurationS ?? Double(max(0, w.endTimestamp - w.startTimestamp)),
            movingDurationS: w.movingDurationS,
            distanceM: w.distanceM,
            ascentM: w.ascentM,
            descentM: w.descentM,
            energyKcal: w.energyKcal,
            averageHeartRate: w.averageHeartRate,
            maximumHeartRate: w.maximumHeartRate,
            averageCadenceRpm: w.averageCadenceRpm,
            averagePowerWatts: w.averagePowerWatts
        )
    }

    // MARK: - FIT messages

    private static func lapFields(_ lap: CanonicalWorkout.Lap, sport: String) -> [FitField] {
        var fields: [FitField] = [
            uint32(253, fitTime(lap.endTimestamp)),
            uint32(2, fitTime(lap.startTimestamp))
        ]
        let elapsed = finiteNonnegative(lap.elapsedDurationS)
            ?? Double(max(0, lap.endTimestamp - lap.startTimestamp))
        fields.append(uint32(7, scaledUInt32(elapsed, scale: 1000)))
        // FIT requires total_timer_time on summary messages. When the canonical source has no distinct
        // pause-excluded timer duration, timer == elapsed is the only honest deterministic fallback.
        let timer = finiteNonnegative(lap.movingDurationS) ?? elapsed
        fields.append(uint32(8, scaledUInt32(min(timer, elapsed), scale: 1000)))
        if let distance = finiteNonnegative(lap.distanceM) {
            fields.append(uint32(9, scaledUInt32(distance, scale: 100)))
        }
        if let energy = finiteNonnegative(lap.energyKcal) {
            fields.append(uint16(11, scaledUInt16(energy, scale: 1)))
        }
        if let hr = lap.averageHeartRate, hr > 0, hr < 255 { fields.append(uint8(15, hr)) }
        if let hr = lap.maximumHeartRate, hr > 0, hr < 255 { fields.append(uint8(16, hr)) }
        if let cadence = lap.averageCadenceRpm, cadence >= 0, cadence < 255 { fields.append(uint8(17, cadence)) }
        if let power = lap.averagePowerWatts, power >= 0, power < 65_535 { fields.append(uint16(19, UInt16(power))) }
        if let ascent = finiteNonnegative(lap.ascentM) { fields.append(uint16(21, scaledUInt16(ascent, scale: 1))) }
        if let descent = finiteNonnegative(lap.descentM) { fields.append(uint16(22, scaledUInt16(descent, scale: 1))) }
        fields.append(enum8(25, fitSport(sport)))
        return fields
    }

    private static func sessionFields(_ w: CanonicalWorkout, lapCount: Int) -> [FitField] {
        var fields: [FitField] = [
            uint32(253, fitTime(w.endTimestamp)),
            uint32(2, fitTime(w.startTimestamp)),
            enum8(5, fitSport(w.sport))
        ]
        let elapsed = finiteNonnegative(w.elapsedDurationS)
            ?? Double(max(0, w.endTimestamp - w.startTimestamp))
        fields.append(uint32(7, scaledUInt32(elapsed, scale: 1000)))
        // Required FIT summary field. No distinct pause data means timer time equals elapsed time;
        // explicit pause-excluded durations supplied by NOOP are preserved exactly.
        let timer = finiteNonnegative(w.movingDurationS) ?? elapsed
        fields.append(uint32(8, scaledUInt32(min(timer, elapsed), scale: 1000)))
        if let distance = finiteNonnegative(w.distanceM) {
            fields.append(uint32(9, scaledUInt32(distance, scale: 100)))
        }
        if let energy = finiteNonnegative(w.energyKcal) {
            fields.append(uint16(11, scaledUInt16(energy, scale: 1)))
        }
        if let hr = w.averageHeartRate, hr > 0, hr < 255 { fields.append(uint8(16, hr)) }
        if let hr = w.maximumHeartRate, hr > 0, hr < 255 { fields.append(uint8(17, hr)) }
        if let cadence = w.averageCadenceRpm, cadence >= 0, cadence < 255 { fields.append(uint8(18, cadence)) }
        if let power = w.averagePowerWatts, power >= 0, power < 65_535 { fields.append(uint16(20, UInt16(power))) }
        if let ascent = finiteNonnegative(w.ascentM) { fields.append(uint16(22, scaledUInt16(ascent, scale: 1))) }
        if let descent = finiteNonnegative(w.descentM) { fields.append(uint16(23, scaledUInt16(descent, scale: 1))) }
        fields.append(uint16(26, UInt16(min(max(0, lapCount), 65_534))))
        return fields
    }

    private static func emit(_ body: inout [UInt8], local: Int, global: Int, fields: [FitField]) {
        appendUInt8(&body, 0x40 | (local & 0x0F))
        appendUInt8(&body, 0)
        appendUInt8(&body, 0) // little-endian architecture
        appendUInt16(&body, UInt16(global))
        appendUInt8(&body, fields.count)
        for field in fields {
            appendUInt8(&body, field.number)
            appendUInt8(&body, field.bytes.count)
            appendUInt8(&body, field.baseType)
        }
        appendUInt8(&body, local & 0x0F)
        for field in fields { body.append(contentsOf: field.bytes) }
    }

    // MARK: - Field encoding

    private static func enum8(_ number: Int, _ value: Int) -> FitField {
        FitField(number: number, baseType: 0x00, bytes: [UInt8(value & 0xFF)])
    }

    private static func uint8(_ number: Int, _ value: Int) -> FitField {
        FitField(number: number, baseType: 0x02, bytes: [UInt8(value & 0xFF)])
    }

    private static func uint16(_ number: Int, _ value: UInt16) -> FitField {
        var bytes: [UInt8] = []
        appendUInt16(&bytes, value)
        return FitField(number: number, baseType: 0x84, bytes: bytes)
    }

    private static func uint32(_ number: Int, _ value: UInt32) -> FitField {
        var bytes: [UInt8] = []
        appendUInt32(&bytes, value)
        return FitField(number: number, baseType: 0x86, bytes: bytes)
    }

    private static func sint32(_ number: Int, _ value: Int32) -> FitField {
        uint32Raw(number, UInt32(bitPattern: value), baseType: 0x85)
    }

    private static func uint32Raw(_ number: Int, _ value: UInt32, baseType: Int) -> FitField {
        var bytes: [UInt8] = []
        appendUInt32(&bytes, value)
        return FitField(number: number, baseType: baseType, bytes: bytes)
    }

    private static func fitTime(_ unix: Int) -> UInt32 {
        let shifted = Int64(unix) - Int64(RouteExporter.fitEpoch)
        if shifted <= 0 { return 0 }
        if shifted >= Int64(UInt32.max) { return UInt32.max - 1 }
        return UInt32(shifted)
    }

    private static func semicircles(_ degrees: Double) -> Int32 {
        let scaled = (degrees * RouteExporter.semiPerDeg).rounded(.toNearestOrAwayFromZero)
        if scaled >= Double(Int32.max) { return Int32.max }
        if scaled <= Double(Int32.min) { return Int32.min }
        return Int32(scaled)
    }

    private static func scaledAltitude(_ metres: Double) -> UInt16 {
        scaledUInt16(metres + 500.0, scale: 5)
    }

    private static func scaledUInt16(_ value: Double, scale: Double) -> UInt16 {
        let raw = (value * scale).rounded(.toNearestOrAwayFromZero)
        return UInt16(min(max(0, raw), 65_534))
    }

    private static func scaledUInt32(_ value: Double, scale: Double) -> UInt32 {
        let raw = (value * scale).rounded(.toNearestOrAwayFromZero)
        return UInt32(min(max(0, raw), Double(UInt32.max - 1)))
    }

    private static func finiteNonnegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func finiteNonnegativeOrSigned(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func validLatitude(_ value: Double) -> Bool { value.isFinite && (-90...90).contains(value) }
    private static func validLongitude(_ value: Double) -> Bool { value.isFinite && (-180...180).contains(value) }

    private static func fitSport(_ sport: String) -> Int {
        switch RouteExporter.canonicalSport(sport) {
        case "run": return 1
        case "cycle": return 2
        case "swim": return 5
        case "walk": return 11
        case "hike": return 17
        case "strength", "strength training", "weight training", "lifting": return 10
        case "climbing", "rock climbing", "bouldering": return 31
        default: return 0
        }
    }

    private static func appendUInt8(_ bytes: inout [UInt8], _ value: Int) {
        bytes.append(UInt8(value & 0xFF))
    }

    private static func appendUInt16(_ bytes: inout [UInt8], _ value: UInt16) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendUInt32(_ bytes: inout [UInt8], _ value: UInt32) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 24) & 0xFF))
    }
}
