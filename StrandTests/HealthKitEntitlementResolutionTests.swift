import XCTest
@testable import Strand

final class HealthKitEntitlementResolutionTests: XCTestCase {
    func testRuntimeSignedEntitlementWins() {
        XCTAssertTrue(HealthKitBridge.resolveHealthKitEntitlement(
            runtimeEntitlement: true,
            runtimeLookupFailed: false,
            profileEntitlement: false
        ))
        XCTAssertFalse(HealthKitBridge.resolveHealthKitEntitlement(
            runtimeEntitlement: false,
            runtimeLookupFailed: false,
            profileEntitlement: true
        ))
    }

    func testMissingRuntimeEntitlementWithoutLookupErrorIsAbsent() {
        XCTAssertFalse(HealthKitBridge.resolveHealthKitEntitlement(
            runtimeEntitlement: nil,
            runtimeLookupFailed: false,
            profileEntitlement: true
        ))
    }

    func testRuntimeLookupFailureFallsBackToProfile() {
        XCTAssertTrue(HealthKitBridge.resolveHealthKitEntitlement(
            runtimeEntitlement: nil,
            runtimeLookupFailed: true,
            profileEntitlement: true
        ))
        XCTAssertFalse(HealthKitBridge.resolveHealthKitEntitlement(
            runtimeEntitlement: nil,
            runtimeLookupFailed: true,
            profileEntitlement: false
        ))
    }

    func testUninspectableRuntimeAndProfileRemainConservative() {
        XCTAssertTrue(HealthKitBridge.resolveHealthKitEntitlement(
            runtimeEntitlement: nil,
            runtimeLookupFailed: true,
            profileEntitlement: nil
        ))
    }
}
