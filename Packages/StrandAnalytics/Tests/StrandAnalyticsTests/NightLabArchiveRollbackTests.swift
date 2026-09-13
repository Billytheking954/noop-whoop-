import XCTest
@testable import StrandAnalytics

final class NightLabArchiveRollbackTests: XCTestCase {

    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NightLabRollbackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func manifest(_ id: String) -> NightRecordManifest {
        NightRecordManifest(nightID: id,
                            state: .recording,
                            windowStartUnix: 1_000,
                            windowEndUnix: 2_000,
                            timezoneOffsetSeconds: 0,
                            rawAssets: [])
    }

    func testRecordingCanBeDiscardedForRetry() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = NightLabFileStore(rootDirectory: root)

        try await archive.createNight(manifest("retry-night"))
        try await archive.discardRecordingNight(nightID: "retry-night")

        do {
            _ = try await archive.loadManifest(nightID: "retry-night")
            XCTFail("discarded recording should be gone")
        } catch let error as NightLabFileStoreError {
            XCTAssertEqual(error, .nightNotFound("retry-night"))
        }

        // The same logical night can now be captured again instead of being permanently blocked by a
        // half-written directory left from a transient filesystem failure.
        try await archive.createNight(manifest("retry-night"))
        XCTAssertEqual(try await archive.loadManifest(nightID: "retry-night").state, .recording)
    }

    func testSealedNightCannotBeDiscardedByRollbackPath() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = NightLabFileStore(rootDirectory: root)

        try await archive.createNight(manifest("sealed-night"))
        _ = try await archive.sealNight(nightID: "sealed-night")

        do {
            try await archive.discardRecordingNight(nightID: "sealed-night")
            XCTFail("rollback must never delete sealed evidence")
        } catch let error as NightLabFileStoreError {
            XCTAssertEqual(error, .nightNotRecording("sealed-night"))
        }

        XCTAssertEqual(try await archive.loadManifest(nightID: "sealed-night").state, .sealed)
    }
}
