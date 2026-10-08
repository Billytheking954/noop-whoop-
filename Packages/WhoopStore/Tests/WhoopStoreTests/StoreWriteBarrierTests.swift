import XCTest
@testable import WhoopStore

final class StoreWriteBarrierTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StoreWriteBarrier.resumeAfterFailedRestore()
    }

    override func tearDown() {
        StoreWriteBarrier.resumeAfterFailedRestore()
        super.tearDown()
    }

    func testSuspendedBarrierRejectsActorAndRegistryMutations() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)

        StoreWriteBarrier.suspendAndDrainForRestore()
        XCTAssertTrue(StoreWriteBarrier.isSuspended)

        do {
            try await store.recordEvent(deviceId: "test", ts: 1, kind: "WRITE", payloadJSON: "{}")
            XCTFail("WhoopStore mutation should be rejected while restore barrier is suspended")
        } catch {
            XCTAssertTrue(error is StoreWriteBarrier.WritesSuspendedError)
        }

        XCTAssertThrowsError(try registry.rename("my-whoop", nickname: "blocked")) { error in
            XCTAssertTrue(error is StoreWriteBarrier.WritesSuspendedError)
        }
    }

    func testFailedRestoreResumeAllowsMutationsAgain() async throws {
        let store = try await WhoopStore.inMemory()

        StoreWriteBarrier.suspendAndDrainForRestore()
        StoreWriteBarrier.resumeAfterFailedRestore()
        XCTAssertFalse(StoreWriteBarrier.isSuspended)

        try await store.recordEvent(deviceId: "test", ts: 2, kind: "WRITE", payloadJSON: "{}")
    }

    func testSuspendWaitsForInFlightWriterToDrain() {
        let writerEntered = expectation(description: "writer entered")
        let writerFinished = expectation(description: "writer finished")
        let suspendReturned = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            defer { writerFinished.fulfill() }
            try? StoreWriteBarrier.withWritePermit {
                writerEntered.fulfill()
                releaseWriter.wait()
            }
        }

        wait(for: [writerEntered], timeout: 2)

        DispatchQueue.global().async {
            StoreWriteBarrier.suspendAndDrainForRestore()
            suspendReturned.signal()
        }

        // The suspend call must still be waiting while the already-started write owns its permit.
        XCTAssertEqual(suspendReturned.wait(timeout: .now() + 0.1), .timedOut)

        releaseWriter.signal()
        wait(for: [writerFinished], timeout: 2)
        XCTAssertEqual(suspendReturned.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(StoreWriteBarrier.isSuspended)
    }
}
