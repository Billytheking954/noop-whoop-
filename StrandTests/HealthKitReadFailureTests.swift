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
}
#endif
