import XCTest
import StrandHealth
@testable import StrandHealthKit

final class HealthKitObservationStreamTests: XCTestCase {
    func testEverySupportedStreamHasStableUniqueProviderIdentity() {
        let providers = HealthKitQuantityKind.allCases.map(\.providerIdentifier)
        XCTAssertEqual(Set(providers).count, providers.count)
        XCTAssertTrue(providers.allSatisfy { $0.hasPrefix("healthkit.") && !$0.isEmpty })
    }

    func testHealthKitSDNNDoesNotCollapseIntoRMSSD() {
        let stream = HealthKitQuantityKind.heartRateVariabilitySDNN
        XCTAssertEqual(stream.metric, .heartRateVariabilitySDNN)
        XCTAssertNotEqual(stream.metric, .heartRateVariabilityRMSSD)
        XCTAssertEqual(stream.canonicalUnit, .milliseconds)
    }

    func testOxygenSaturationPreservesHealthKitFractionUnit() {
        let stream = HealthKitQuantityKind.oxygenSaturation
        XCTAssertEqual(stream.metric, .oxygenSaturation)
        XCTAssertEqual(stream.canonicalUnit, .fraction)
    }

    func testDistanceKindsStaySemanticallyDistinct() {
        XCTAssertEqual(HealthKitQuantityKind.walkingRunningDistance.metric, .walkingRunningDistance)
        XCTAssertEqual(HealthKitQuantityKind.cyclingDistance.metric, .cyclingDistance)
        XCTAssertEqual(HealthKitQuantityKind.swimmingDistance.metric, .swimmingDistance)
        XCTAssertEqual(HealthKitQuantityKind.walkingRunningDistance.canonicalUnit, .meters)
        XCTAssertEqual(HealthKitQuantityKind.cyclingDistance.canonicalUnit, .meters)
        XCTAssertEqual(HealthKitQuantityKind.swimmingDistance.canonicalUnit, .meters)
    }
}
