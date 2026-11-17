import XCTest
import WhoopStore
#if os(iOS)
@testable import NOOPiOS
#else
@testable import Strand
#endif

final class PendingWorkoutCompletionTests: XCTestCase {
    private func entry() -> PendingWorkoutCompletion.Entry {
        .init(deviceID: "originating-strap", row: WorkoutRow(
            startTs: 1_800_000_000, endTs: 1_800_000_600, sport: "Running", source: "manual",
            durationS: 540, energyKcal: nil, avgHr: 140, maxHr: 165, strain: 12,
            distanceM: nil, zonesJSON: nil, notes: nil, steps: nil), route: nil)
    }

    @MainActor func testFailureSurvivesReloadAndRetryUsesOriginalIdentityAndStopTime() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("pending.json")
        let pending = entry()
        try PendingWorkoutCompletion.enqueue(pending, at: url)
        do {
            try await PendingWorkoutCompletion.drain(at: url) { _ in throw CocoaError(.fileWriteOutOfSpace) }
            XCTFail("Expected save error")
        } catch {}
        XCTAssertEqual(try PendingWorkoutCompletion.load(at: url), [pending])
        var saved: [PendingWorkoutCompletion.Entry] = []
        try await PendingWorkoutCompletion.drain(at: url) { saved.append($0) }
        XCTAssertEqual(saved, [pending])
        XCTAssertTrue(try PendingWorkoutCompletion.load(at: url).isEmpty)
    }

    func testDuplicateEnqueueDoesNotCreateAnotherWorkout() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("pending.json")
        try PendingWorkoutCompletion.enqueue(entry(), at: url)
        try PendingWorkoutCompletion.enqueue(entry(), at: url)
        XCTAssertEqual(try PendingWorkoutCompletion.load(at: url).count, 1)
    }

    func testCorruptQueueIsPreservedInsteadOfOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("pending.json")
        let bad = Data("damaged".utf8)
        try bad.write(to: url)
        XCTAssertThrowsError(try PendingWorkoutCompletion.enqueue(entry(), at: url))
        XCTAssertEqual(try Data(contentsOf: url), bad)
    }
}
