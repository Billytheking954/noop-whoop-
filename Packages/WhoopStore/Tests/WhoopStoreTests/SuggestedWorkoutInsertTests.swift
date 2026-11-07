import XCTest
@testable import WhoopStore

final class SuggestedWorkoutInsertTests: XCTestCase {
    private func row(start: Int = 1_000, end: Int = 1_900, sport: String = "Workout",
                     source: String = "manual") -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: source,
                   durationS: Double(end - start), energyKcal: nil, avgHr: 130,
                   maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
    }

    func testConcurrentConfirmationsInsertExactlyOnce() async throws {
        let store = try await WhoopStore.inMemory()
        let workout = row()
        async let a = store.insertSuggestedWorkoutIfAbsent(workout, deviceId: "whoop-a")
        async let b = store.insertSuggestedWorkoutIfAbsent(workout, deviceId: "whoop-b")
        let results = try await [a, b]
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let first = try await store.workouts(deviceId: "whoop-a", from: 0, to: 3_000, limit: 10)
        let second = try await store.workouts(deviceId: "whoop-b", from: 0, to: 3_000, limit: 10)
        XCTAssertEqual(first.count + second.count, 1)
    }

    func testImportedOverlapIsNeverOverwrittenOrDuplicated() async throws {
        let store = try await WhoopStore.inMemory()
        let imported = row(sport: "Cycling", source: "apple-health")
        _ = try await store.upsertWorkouts([imported], deviceId: "apple-health")
        let inserted = try await store.insertSuggestedWorkoutIfAbsent(row(start: 1_010, end: 1_880),
                                                                      deviceId: "my-whoop")
        XCTAssertFalse(inserted)
        let original = try await store.workouts(deviceId: "apple-health", from: 0, to: 3_000, limit: 10)
        XCTAssertEqual(original, [imported])
        let manual = try await store.workouts(deviceId: "my-whoop", from: 0, to: 3_000, limit: 10)
        XCTAssertTrue(manual.isEmpty)
    }

    func testSeparateActivityRemainsInsertable() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertWorkouts([row()], deviceId: "my-whoop")
        let next = row(start: 2_000, end: 2_900)
        let inserted = try await store.insertSuggestedWorkoutIfAbsent(next, deviceId: "my-whoop")
        XCTAssertTrue(inserted)
        let workouts = try await store.workouts(deviceId: "my-whoop", from: 0, to: 3_000, limit: 10)
        XCTAssertEqual(workouts.count, 2)
    }
}
