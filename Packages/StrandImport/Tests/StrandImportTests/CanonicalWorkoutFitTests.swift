import XCTest
@testable import StrandImport

final class CanonicalWorkoutFitTests: XCTestCase {
    private let measured = CanonicalWorkout.Provenance(source: .whoopBLE, status: .measured)
    private let location = CanonicalWorkout.Provenance(source: .coreLocation, status: .measured)

    func testStableIdentityUsesWholePersistedNaturalKey() {
        let a = CanonicalWorkout.persistedStableID(deviceID: "strap-a", startTimestamp: 1_800_000_000, sport: "Run")
        let same = CanonicalWorkout.persistedStableID(deviceID: "strap-a", startTimestamp: 1_800_000_000, sport: " run ")
        let otherDevice = CanonicalWorkout.persistedStableID(deviceID: "strap-b", startTimestamp: 1_800_000_000, sport: "run")
        let otherSport = CanonicalWorkout.persistedStableID(deviceID: "strap-a", startTimestamp: 1_800_000_000, sport: "cycle")

        XCTAssertEqual(a, same)
        XCTAssertNotEqual(a, otherDevice)
        XCTAssertNotEqual(a, otherSport)
        XCTAssertTrue(a.hasPrefix("w1-"))
    }

    func testFullOutdoorRunRoundTripsWithoutLosingCoreWorkoutData() throws {
        let start = 1_800_000_000
        let workout = CanonicalWorkout(
            stableID: CanonicalWorkout.persistedStableID(deviceID: "strap-a", startTimestamp: start, sport: "run"),
            source: .whoopBLE,
            sport: "run",
            startTimestamp: start,
            endTimestamp: start + 120,
            elapsedDurationS: 120,
            movingDurationS: 116,
            heartRateSamples: [
                .init(timestamp: start, bpm: 120, provenance: measured),
                .init(timestamp: start + 60, bpm: 145, provenance: measured),
                .init(timestamp: start + 120, bpm: 160, provenance: measured)
            ],
            averageHeartRate: 142,
            maximumHeartRate: 160,
            distanceM: 500,
            energyKcal: 42,
            route: [
                .init(timestamp: start, latitude: 51.7500, longitude: -0.3400, altitudeM: 100,
                      distanceM: 0, speedMps: 4.0, cadenceRpm: 78, powerWatts: 210, provenance: location),
                .init(timestamp: start + 60, latitude: 51.7510, longitude: -0.3390, altitudeM: 104,
                      distanceM: 250, speedMps: 4.2, cadenceRpm: 80, powerWatts: 225, provenance: location),
                .init(timestamp: start + 120, latitude: 51.7520, longitude: -0.3380, altitudeM: 102,
                      distanceM: 500, speedMps: 4.1, cadenceRpm: 79, powerWatts: 215, provenance: location)
            ],
            ascentM: 6,
            descentM: 4,
            averageCadenceRpm: 79,
            averagePowerWatts: 217,
            laps: [
                .init(startTimestamp: start, endTimestamp: start + 60, elapsedDurationS: 60,
                      movingDurationS: 58, distanceM: 250, ascentM: 4, descentM: 0, energyKcal: 21,
                      averageHeartRate: 133, maximumHeartRate: 145, averageCadenceRpm: 79, averagePowerWatts: 218),
                .init(startTimestamp: start + 60, endTimestamp: start + 120, elapsedDurationS: 60,
                      movingDurationS: 58, distanceM: 250, ascentM: 2, descentM: 4, energyKcal: 21,
                      averageHeartRate: 151, maximumHeartRate: 160, averageCadenceRpm: 79, averagePowerWatts: 216)
            ]
        )

        let export = CanonicalFitExporter.render(workout)
        XCTAssertEqual(export.recordCount, 3)
        XCTAssertEqual(export.omittedUntimedRoutePointCount, 0)
        XCTAssertTrue(export.stravaUploadReady)
        XCTAssertEqual(export.externalID, "noop-\(workout.stableID)")
        try assertValidTrailingCRC(export.data)

        let imported = ActivityFileImporter.parse(data: export.data, filename: "run.fit")
        let activity = try XCTUnwrap(imported.activity)
        XCTAssertEqual(activity.kind, .fit)
        XCTAssertEqual(activity.sport, "Running")
        XCTAssertEqual(activity.gpsPointCount, 3)
        XCTAssertEqual(activity.hrSampleCount, 3)
        XCTAssertEqual(activity.hrSamples.map(\.ts), [start, start + 60, start + 120])
        XCTAssertEqual(activity.hrSamples.map(\.bpm), [120, 145, 160])
        XCTAssertEqual(activity.avgHr, 142)
        XCTAssertEqual(activity.maxHr, 160)
        XCTAssertEqual(activity.distanceM ?? -1, 500, accuracy: 0.01)
        XCTAssertEqual(activity.energyKcal ?? -1, 42, accuracy: 0.01)
        XCTAssertEqual(activity.ascentM ?? -1, 6, accuracy: 0.01)

        let messages = try FitInspector(export.data).messages()
        XCTAssertEqual(messages.filter { $0.global == 20 }.count, 3)
        XCTAssertEqual(messages.filter { $0.global == 19 }.count, 2)
        let firstRecord = try XCTUnwrap(messages.first { $0.global == 20 })
        XCTAssertEqual(firstRecord.u16(2).map { (Double($0) / 5.0) - 500.0 } ?? -999, 100, accuracy: 0.2)
        XCTAssertEqual(firstRecord.u8(4), 78)
        XCTAssertEqual(firstRecord.u16(7), 210)
        let session = try XCTUnwrap(messages.first { $0.global == 18 })
        XCTAssertEqual(session.u8(18), 79)
        XCTAssertEqual(session.u16(20), 217)
        XCTAssertEqual(session.u16(22), 6)
        XCTAssertEqual(session.u16(23), 4)
        XCTAssertEqual(session.u16(26), 2)
    }

    func testHROnlyWorkoutProducesTimedRecordsWithoutInventingRoute() throws {
        let start = 1_800_010_000
        let workout = CanonicalWorkout(
            stableID: "hr-only", source: .whoopBLE, sport: "strength",
            startTimestamp: start, endTimestamp: start + 10,
            heartRateSamples: [
                .init(timestamp: start, bpm: 110, provenance: measured),
                .init(timestamp: start + 10, bpm: 130, provenance: measured)
            ],
            averageHeartRate: 120, maximumHeartRate: 130
        )

        let export = CanonicalFitExporter.render(workout)
        XCTAssertEqual(export.recordCount, 2)
        XCTAssertTrue(export.stravaUploadReady)
        let activity = try XCTUnwrap(ActivityFileImporter.parse(data: export.data, filename: "hr.fit").activity)
        XCTAssertEqual(activity.gpsPointCount, 0)
        XCTAssertEqual(activity.hrSamples.map(\.ts), [start, start + 10])
        XCTAssertEqual(activity.hrSamples.map(\.bpm), [110, 130])
        let records = try FitInspector(export.data).messages().filter { $0.global == 20 }
        XCTAssertTrue(records.allSatisfy { $0.fields[0] == nil && $0.fields[1] == nil })
    }

    func testSummaryOnlyWorkoutDoesNotFabricateTimeSeries() throws {
        let start = 1_800_020_000
        let workout = CanonicalWorkout(
            stableID: "summary-only", source: .whoopImport, sport: "run",
            startTimestamp: start, endTimestamp: start + 900,
            averageHeartRate: 150, maximumHeartRate: 170, distanceM: 3_000, energyKcal: 250,
            route: [
                .init(latitude: 51.0, longitude: -0.1, provenance: location),
                .init(latitude: 51.1, longitude: -0.2, provenance: location)
            ]
        )

        let export = CanonicalFitExporter.render(workout)
        XCTAssertEqual(export.recordCount, 0)
        XCTAssertEqual(export.omittedUntimedRoutePointCount, 2)
        XCTAssertFalse(export.stravaUploadReady)
        let messages = try FitInspector(export.data).messages()
        XCTAssertTrue(messages.filter { $0.global == 20 }.isEmpty)
        XCTAssertNotNil(messages.first { $0.global == 18 })
    }

    func testPartialRecordingPreservesGapAndOmitsOnlyUntimedPoint() throws {
        let start = 1_800_030_000
        let workout = CanonicalWorkout(
            stableID: "partial", source: .whoopBLE, sport: "run",
            startTimestamp: start, endTimestamp: start + 30,
            heartRateSamples: [
                .init(timestamp: start, bpm: 125, provenance: measured),
                .init(timestamp: start + 30, bpm: 155, provenance: measured)
            ],
            route: [
                .init(timestamp: start, latitude: 51.0, longitude: -0.1, provenance: location),
                .init(latitude: 51.05, longitude: -0.15, provenance: location),
                .init(timestamp: start + 30, latitude: 51.1, longitude: -0.2, provenance: location)
            ]
        )

        let export = CanonicalFitExporter.render(workout)
        XCTAssertEqual(export.omittedUntimedRoutePointCount, 1)
        XCTAssertEqual(export.recordCount, 2)
        let activity = try XCTUnwrap(ActivityFileImporter.parse(data: export.data, filename: "partial.fit").activity)
        XCTAssertEqual(activity.hrSamples.map(\.ts), [start, start + 30])
        XCTAssertEqual(activity.gpsPointCount, 2)
    }

    func testNoGPSStillValidWhenTimedHRExists() throws {
        let start = 1_800_040_000
        let workout = CanonicalWorkout(
            stableID: "no-gps", source: .activityFile, sport: "cycle",
            startTimestamp: start, endTimestamp: start + 60,
            heartRateSamples: [.init(timestamp: start + 30, bpm: 140,
                                     provenance: .init(source: .activityFile, status: .imported))]
        )
        let export = CanonicalFitExporter.render(workout)
        XCTAssertTrue(export.stravaUploadReady)
        let activity = try XCTUnwrap(ActivityFileImporter.parse(data: export.data, filename: "nogps.fit").activity)
        XCTAssertEqual(activity.gpsPointCount, 0)
        XCTAssertEqual(activity.hrSampleCount, 1)
    }

    func testNoHRDoesNotCreateHeartRateFields() throws {
        let start = 1_800_050_000
        let workout = CanonicalWorkout(
            stableID: "no-hr", source: .whoopBLE, sport: "hike",
            startTimestamp: start, endTimestamp: start + 60,
            route: [
                .init(timestamp: start, latitude: 52, longitude: -1, provenance: location),
                .init(timestamp: start + 60, latitude: 52.001, longitude: -1.001, provenance: location)
            ]
        )
        let export = CanonicalFitExporter.render(workout)
        let messages = try FitInspector(export.data).messages()
        XCTAssertTrue(messages.filter { $0.global == 20 }.allSatisfy { $0.fields[3] == nil })
        let session = try XCTUnwrap(messages.first { $0.global == 18 })
        XCTAssertNil(session.fields[16])
        XCTAssertNil(session.fields[17])
    }

    func testDuplicateExportIsByteDeterministicAndKeepsIdentity() {
        let start = 1_800_060_000
        let workout = CanonicalWorkout(
            stableID: CanonicalWorkout.persistedStableID(deviceID: "d", startTimestamp: start, sport: "run"),
            source: .manual, sport: "run", startTimestamp: start, endTimestamp: start + 20,
            heartRateSamples: [.init(timestamp: start + 10, bpm: 135, provenance: measured)]
        )
        let first = CanonicalFitExporter.render(workout)
        let second = CanonicalFitExporter.render(workout)
        XCTAssertEqual(first.externalID, second.externalID)
        XCTAssertEqual(first.data, second.data)
    }

    func testFieldSpecificPrecedenceKeepsLocationAndHROwnershipExplicit() {
        XCTAssertEqual(CanonicalWorkout.sourcePrecedence(for: .route).first, .coreLocation)
        XCTAssertEqual(CanonicalWorkout.sourcePrecedence(for: .heartRateSamples).first, .whoopBLE)
        XCTAssertEqual(CanonicalWorkout.sourcePrecedence(for: .power).first, .activityFile)
    }

    private func assertValidTrailingCRC(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let bytes = [UInt8](data)
        XCTAssertGreaterThan(bytes.count, 14, file: file, line: line)
        let expected = UInt16(bytes[bytes.count - 2]) | (UInt16(bytes[bytes.count - 1]) << 8)
        XCTAssertEqual(UInt16(RouteExporter.fitCrc(Array(bytes.dropLast(2)))), expected, file: file, line: line)
    }
}

private struct FitInspector {
    struct Message {
        let global: Int
        let fields: [Int: [UInt8]]

        func u8(_ number: Int) -> Int? {
            guard let b = fields[number], b.count == 1 else { return nil }
            return Int(b[0])
        }
        func u16(_ number: Int) -> UInt16? {
            guard let b = fields[number], b.count == 2 else { return nil }
            return UInt16(b[0]) | (UInt16(b[1]) << 8)
        }
    }

    struct Definition {
        let global: Int
        let fields: [(number: Int, size: Int)]
        var byteCount: Int { fields.reduce(0) { $0 + $1.size } }
    }

    let bytes: [UInt8]

    init(_ data: Data) { bytes = [UInt8](data) }

    func messages() throws -> [Message] {
        guard bytes.count >= 14 else { throw InspectError.malformed }
        let headerSize = Int(bytes[0])
        guard headerSize >= 12, headerSize <= bytes.count,
              bytes[8...11].elementsEqual(Array(".FIT".utf8)) else { throw InspectError.malformed }
        let dataSize = Int(u32(at: 4))
        let end = headerSize + dataSize
        guard end <= bytes.count else { throw InspectError.malformed }

        var index = headerSize
        var defs: [Int: Definition] = [:]
        var output: [Message] = []
        while index < end {
            let header = bytes[index]
            index += 1
            guard header & 0x80 == 0 else { throw InspectError.malformed }
            let local = Int(header & 0x0F)
            if header & 0x40 != 0 {
                guard index + 5 <= end else { throw InspectError.malformed }
                index += 1 // reserved
                let architecture = bytes[index]; index += 1
                guard architecture == 0 else { throw InspectError.malformed }
                let global = Int(bytes[index]) | (Int(bytes[index + 1]) << 8); index += 2
                let count = Int(bytes[index]); index += 1
                guard index + count * 3 <= end else { throw InspectError.malformed }
                var fields: [(Int, Int)] = []
                for _ in 0..<count {
                    let number = Int(bytes[index])
                    let size = Int(bytes[index + 1])
                    index += 3 // base type is not needed by the inspector
                    fields.append((number, size))
                }
                defs[local] = Definition(global: global, fields: fields)
            } else {
                guard let def = defs[local], index + def.byteCount <= end else { throw InspectError.malformed }
                var cursor = index
                var fields: [Int: [UInt8]] = [:]
                for field in def.fields {
                    fields[field.number] = Array(bytes[cursor..<(cursor + field.size)])
                    cursor += field.size
                }
                output.append(Message(global: def.global, fields: fields))
                index = cursor
            }
        }
        return output
    }

    private func u32(at index: Int) -> UInt32 {
        UInt32(bytes[index]) | (UInt32(bytes[index + 1]) << 8) |
        (UInt32(bytes[index + 2]) << 16) | (UInt32(bytes[index + 3]) << 24)
    }

    enum InspectError: Error { case malformed }
}
