import XCTest
import GRDB
@testable import WhoopStore

final class ImportedSleepMetricSeriesTests: XCTestCase {
    private let day = "2026-11-04"
    private let otherDay = "2026-11-03"

    private func daily(_ day: String, total: Double, core: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: total, efficiency: nil, deepMin: nil,
                    remMin: nil, lightMin: core, disturbances: nil, restingHr: nil,
                    avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil)
    }

    private func points(_ store: WhoopStore, deviceId: String = "apple-health") async throws -> [MetricPoint] {
        var result: [MetricPoint] = []
        for key in try await store.metricKeys(deviceId: deviceId) {
            result += try await store.metricSeries(deviceId: deviceId, key: key,
                                                   from: "2026-01-01", to: "2026-12-31")
        }
        return result
    }

    func testCorrectionRemovesOmittedStagesAndPreservesUnrelatedData() async throws {
        let store = try await WhoopStore.inMemory()
        let oldCore = MetricPoint(day: day, key: "core_min", value: 480)
        let oldTotal = MetricPoint(day: day, key: "asleep_min", value: 960)
        let hrv = MetricPoint(day: day, key: "hrv", value: 52)
        let olderCore = MetricPoint(day: otherDay, key: "core_min", value: 230)
        try await store.upsertMetricSeries([oldCore, oldTotal, hrv, olderCore], deviceId: "apple-health")
        try await store.upsertMetricSeries([oldCore], deviceId: "my-whoop")

        let correctedTotal = MetricPoint(day: day, key: "asleep_min", value: 480)
        let correctedDaily = daily(day, total: 480, core: nil)
        let count = try await store.replaceImportedSleepMetricSeries(
            deviceId: "apple-health", days: [day], replacement: [correctedTotal],
            dailyMetrics: [correctedDaily])
        XCTAssertEqual(count, 1)
        let actual = try await points(store)
        XCTAssertEqual(actual, [correctedTotal, olderCore, hrv])
        let otherDevice = try await points(store, deviceId: "my-whoop")
        XCTAssertEqual(otherDevice, [oldCore])
        let dailyRows = try await store.dailyMetrics(deviceId: "apple-health", from: day, to: day)
        XCTAssertEqual(dailyRows, [correctedDaily])
    }

    func testSuccessfulEmptyReplacementClearsOnlySelectedSleepDays() async throws {
        let store = try await WhoopStore.inMemory()
        let sleep = WhoopStore.importedSleepMetricKeys.sorted().map {
            MetricPoint(day: day, key: $0, value: 10)
        }
        let unrelated = MetricPoint(day: day, key: "steps", value: 900)
        let awake = MetricPoint(day: day, key: "awake_min", value: 20)
        let inBed = MetricPoint(day: day, key: "in_bed_min", value: 500)
        try await store.upsertMetricSeries(sleep + [unrelated, awake, inBed], deviceId: "apple-health")
        let count = try await store.replaceImportedSleepMetricSeries(
            deviceId: "apple-health", days: [day, day], replacement: [])
        XCTAssertEqual(count, 0)
        let actual = try await points(store)
        XCTAssertEqual(actual, [awake, inBed, unrelated])
    }

    func testInvalidReplacementNeverDeletesPreviousValues() async throws {
        let store = try await WhoopStore.inMemory()
        let existing = MetricPoint(day: day, key: "core_min", value: 300)
        try await store.upsertMetricSeries([existing], deviceId: "apple-health")
        let valid = MetricPoint(day: day, key: "asleep_min", value: 450)
        let invalidCases: [([MetricPoint], ImportedSleepMetricSeriesError)] = [
            ([valid, MetricPoint(day: day, key: "hrv", value: 60)], .unexpectedKey("hrv")),
            ([valid, MetricPoint(day: day, key: "awake_min", value: 20)], .unexpectedKey("awake_min")),
            ([valid, MetricPoint(day: otherDay, key: "core_min", value: 20)], .unexpectedDay(otherDay)),
            ([valid, MetricPoint(day: day, key: "core_min", value: .nan)], .invalidValue),
            ([valid, MetricPoint(day: day, key: "core_min", value: -1)], .invalidValue),
            ([valid, valid], .duplicatePoint),
        ]
        for (replacement, expectedError) in invalidCases {
            do {
                try await store.replaceImportedSleepMetricSeries(
                    deviceId: "apple-health", days: [day], replacement: replacement)
                XCTFail("Invalid replacement must be rejected")
            } catch {
                XCTAssertEqual(error as? ImportedSleepMetricSeriesError, expectedError)
            }
            let actual = try await points(store)
            XCTAssertEqual(actual, [existing])
        }
    }

    func testEmptyDayScopeDoesNotWriteOrDelete() async throws {
        let store = try await WhoopStore.inMemory()
        let existing = MetricPoint(day: day, key: "core_min", value: 300)
        try await store.upsertMetricSeries([existing], deviceId: "apple-health")
        let count = try await store.replaceImportedSleepMetricSeries(
            deviceId: "apple-health", days: [], replacement: [])
        XCTAssertEqual(count, 0)
        do {
            try await store.replaceImportedSleepMetricSeries(
                deviceId: "apple-health", days: [], replacement: [existing])
            XCTFail("An empty scope cannot accept replacement points")
        } catch {
            XCTAssertEqual(error as? ImportedSleepMetricSeriesError, .unexpectedDay(day))
        }
        let actual = try await points(store)
        XCTAssertEqual(actual, [existing])
    }

    func testInsertionFailureRollsBackDeletionAndEarlierInserts() async throws {
        let store = try await WhoopStore.inMemory()
        let existing = MetricPoint(day: day, key: "core_min", value: 300)
        let oldDaily = daily(day, total: 400, core: 300)
        try await store.upsertMetricSeries([existing], deviceId: "apple-health")
        try await store.upsertDailyMetrics([oldDaily], deviceId: "apple-health")
        try await store.dbWriter.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_sleep_total BEFORE INSERT ON metricSeries
                WHEN NEW.key = 'asleep_min'
                BEGIN SELECT RAISE(ABORT, 'injected write failure'); END;
                """)
        }
        do {
            try await store.replaceImportedSleepMetricSeries(deviceId: "apple-health", days: [day], replacement: [
                MetricPoint(day: day, key: "deep_min", value: 40),
                MetricPoint(day: day, key: "asleep_min", value: 400),
            ], dailyMetrics: [daily(day, total: 500, core: nil)])
            XCTFail("Injected insertion failure must escape")
        } catch {
            XCTAssertTrue(error is DatabaseError)
        }
        let actual = try await points(store)
        XCTAssertEqual(actual, [existing], "Delete and every insert must roll back together")
        let dailyRows = try await store.dailyMetrics(deviceId: "apple-health", from: day, to: day)
        XCTAssertEqual(dailyRows, [oldDaily], "Daily values must roll back with their metric-series projection")
    }

    func testOutOfScopeDailyRowRejectsBeforeAnyWrite() async throws {
        let store = try await WhoopStore.inMemory()
        let existing = MetricPoint(day: day, key: "core_min", value: 300)
        let oldDaily = daily(day, total: 400, core: 300)
        try await store.upsertMetricSeries([existing], deviceId: "apple-health")
        try await store.upsertDailyMetrics([oldDaily], deviceId: "apple-health")
        do {
            try await store.replaceImportedSleepMetricSeries(deviceId: "apple-health", days: [day],
                replacement: [], dailyMetrics: [daily(otherDay, total: 200, core: nil)])
            XCTFail("Daily rows must be within the replacement scope")
        } catch {
            XCTAssertEqual(error as? ImportedSleepMetricSeriesError, .unexpectedDay(otherDay))
        }
        let actual = try await points(store)
        XCTAssertEqual(actual, [existing])
        let dailyRows = try await store.dailyMetrics(deviceId: "apple-health", from: otherDay, to: day)
        XCTAssertEqual(dailyRows, [oldDaily])
    }
}
