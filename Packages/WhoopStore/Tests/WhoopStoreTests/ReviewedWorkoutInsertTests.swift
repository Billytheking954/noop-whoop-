import Foundation
import XCTest
@testable import WhoopStore

final class ReviewedWorkoutInsertTests: XCTestCase {
    private func row(start: Int, end: Int, sport: String = "Running") -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: "manual",
                   durationS: Double(end - start), energyKcal: nil, avgHr: 140,
                   maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil,
                   notes: nil, steps: nil)
    }

    func testReviewedSpanCannotOverwriteAnImportedWorkout() async throws {
        let store = try await WhoopStore.inMemory()
        let imported = row(start: 1_000, end: 2_000)
        _ = try await store.upsertWorkouts([imported], deviceId: "apple")
        let saved = try await store.insertReviewedWorkoutIfFree(
            row(start: 1_100, end: 1_900, sport: "Cycling"), deviceId: "strap")
        let importedRows = try await store.workouts(deviceId: "apple", from: 0, to: 3_000, limit: 10)
        let reviewedRows = try await store.workouts(deviceId: "strap", from: 0, to: 3_000, limit: 10)
        XCTAssertFalse(saved)
        XCTAssertEqual(importedRows, [imported])
        XCTAssertTrue(reviewedRows.isEmpty)
    }

    func testConcurrentReviewedWritesSaveAtMostOneRow() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("reviewed-workout-\(UUID().uuidString).sqlite").path
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
        // Exercise the DatabasePool used by production, not only the in-memory queue.
        let store = try await WhoopStore(path: path)
        let first = row(start: 1_000, end: 2_000)
        let second = row(start: 1_200, end: 2_200, sport: "Cycling")
        async let savedFirst = store.insertReviewedWorkoutIfFree(first, deviceId: "strap")
        async let savedSecond = store.insertReviewedWorkoutIfFree(second, deviceId: "strap")
        let results = try await [savedFirst, savedSecond]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let rows = try await store.workouts(deviceId: "strap", from: 0, to: 3_000, limit: 10)
        XCTAssertEqual(rows.count, 1)
    }
}
