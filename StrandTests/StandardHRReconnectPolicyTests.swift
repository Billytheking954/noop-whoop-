import XCTest
@testable import Strand

/// Pure backoff checks for the standard Bluetooth HR source; CoreBluetooth callbacks remain a device-level test.
final class StandardHRReconnectPolicyTests: XCTestCase {
    func testRetryDelayDoublesAndCaps() {
        var policy = StandardHRReconnectPolicy(initialDelay: 2, maximumDelay: 30)

        XCTAssertEqual(policy.nextDelay(), 2)
        XCTAssertEqual(policy.nextDelay(), 4)
        XCTAssertEqual(policy.nextDelay(), 8)
        XCTAssertEqual(policy.nextDelay(), 16)
        XCTAssertEqual(policy.nextDelay(), 30)
        XCTAssertEqual(policy.nextDelay(), 30)
        XCTAssertEqual(policy.nextDelay(), 30)
    }

    func testResetAfterSuccessOrExplicitStopRestartsBackoff() {
        var policy = StandardHRReconnectPolicy(initialDelay: 2, maximumDelay: 30)
        _ = policy.nextDelay()
        _ = policy.nextDelay()
        XCTAssertEqual(policy.nextDelay(), 8)

        // StandardHRSource resets this policy after a successful connection and when stop() cancels retries.
        policy.reset()
        XCTAssertEqual(policy.nextDelay(), 2)
    }

    func testMaximumDelayCannotBeShorterThanInitialDelay() {
        var policy = StandardHRReconnectPolicy(initialDelay: 10, maximumDelay: 3)
        XCTAssertEqual(policy.nextDelay(), 10)
        XCTAssertEqual(policy.nextDelay(), 10)
    }
}
