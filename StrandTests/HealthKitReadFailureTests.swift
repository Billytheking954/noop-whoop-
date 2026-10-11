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
