#if os(iOS)
import XCTest
@testable import Strand

/// A failed HealthKit sleep query must never be treated as a valid empty result.
/// This classification is what prevents a transient read error from clobbering prior sleep data.
final class HealthKitReadFailureTests: XCTestCase {
    func testSleepQueryFailureIsNotAnEmptyRead() {
        XCTAssertEqual(HealthKitBridge.sampleQueryReadOutcome(hadError: true), .failed)
        XCTAssertEqual(HealthKitBridge.sampleQueryReadOutcome(hadError: false), .read)
    }

    func testWorkoutRouteErrorFinishesEvenWhenDoneIsFalse() {
        XCTAssertEqual(HealthKitBridge.workoutRouteBatchOutcome(done: false, hadError: true), .failed)
        XCTAssertEqual(HealthKitBridge.workoutRouteBatchOutcome(done: false, hadError: false), .more)
        XCTAssertEqual(HealthKitBridge.workoutRouteBatchOutcome(done: true, hadError: false), .finished)
    }

    func testFailedWorkoutDetailReadCannotReachWholeRowUpsert() {
        XCTAssertFalse(HealthKitBridge.shouldPersistWorkoutRead(heartRateFailed: true,
                                                                 stepsFailed: false))
        XCTAssertFalse(HealthKitBridge.shouldPersistWorkoutRead(heartRateFailed: false,
                                                                 stepsFailed: true))
        XCTAssertTrue(HealthKitBridge.shouldPersistWorkoutRead(heartRateFailed: false,
                                                                stepsFailed: false),
                      "Successful empty reads remain distinct from query failures")
    }

    func testReadOnlyPriorGrantResumesWithoutWriteAuthorization() {
        XCTAssertTrue(HealthKitBridge.shouldResumeAuthorization(priorRequestRecorded: true,
                                                                 anyWriteAuthorized: false))
    }

    func testFreshInstallDoesNotAssumeAuthorization() {
        XCTAssertFalse(HealthKitBridge.shouldResumeAuthorization(priorRequestRecorded: false,
                                                                  anyWriteAuthorized: false))
    }

    func testLegacyWriteAuthorizationStillResumesWithoutRecordedSignature() {
        XCTAssertTrue(HealthKitBridge.shouldResumeAuthorization(priorRequestRecorded: false,
                                                                 anyWriteAuthorized: true))
    }
}
#endif
