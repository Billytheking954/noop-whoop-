import XCTest
import GRDB
@testable import WhoopStore

final class AppleHealthSampleIdentityStoreTests: XCTestCase {
    func testTombstoneResolvesOnlyTheMatchingSourceAndSampleType() async throws {
        let store = try await WhoopStore.inMemory()
        let waterType = "HKQuantityTypeIdentifierDietaryWater"
        let caffeineType = "HKQuantityTypeIdentifierDietaryCaffeine"

        _ = try await store.reconcileAppleHealthSampleIdentityDelta(
            added: [
                AppleHealthSampleIdentity(typeIdentifier: waterType, uuid: "water-1",
                                          day: "2026-10-01", startTs: 1_791_000_000),
                AppleHealthSampleIdentity(typeIdentifier: waterType, uuid: "water-2",
                                          day: "2026-10-02", startTs: 1_791_100_000)
            ],
            deletedUUIDs: [], deviceId: "apple-health", typeIdentifier: waterType)
        _ = try await store.reconcileAppleHealthSampleIdentityDelta(
            added: [AppleHealthSampleIdentity(typeIdentifier: caffeineType, uuid: "water-1",
                                              day: "2026-10-03", startTs: 1_791_200_000)],
            deletedUUIDs: [], deviceId: "apple-health", typeIdentifier: caffeineType)

        let days = try await store.appleHealthSampleIdentityDays(
            deviceId: "apple-health", typeIdentifier: waterType, uuids: ["water-1", "missing"])
        XCTAssertEqual(days, ["2026-10-01"])

        let removed = try await store.reconcileAppleHealthSampleIdentityDelta(
            added: [], deletedUUIDs: ["water-1"],
            deviceId: "apple-health", typeIdentifier: waterType)
        XCTAssertEqual(removed, ["2026-10-01"])

        let waterRemaining = try await store.appleHealthSampleIdentityDays(
            deviceId: "apple-health", typeIdentifier: waterType, uuids: ["water-1", "water-2"])
        XCTAssertEqual(waterRemaining, ["2026-10-02"])
        let caffeineSurvives = try await store.appleHealthSampleIdentityDays(
            deviceId: "apple-health", typeIdentifier: caffeineType, uuids: ["water-1"])
        XCTAssertEqual(caffeineSurvives, ["2026-10-03"])
    }

    func testReplayedAndUnknownTombstonesAreIdempotent() async throws {
        let store = try await WhoopStore.inMemory()
        let type = "HKQuantityTypeIdentifierDietaryWater"
        _ = try await store.reconcileAppleHealthSampleIdentityDelta(
            added: [AppleHealthSampleIdentity(typeIdentifier: type, uuid: "sample-1",
                                              day: "2026-10-04", startTs: 1_791_300_000)],
            deletedUUIDs: [], deviceId: "apple-health", typeIdentifier: type)

        let first = try await store.reconcileAppleHealthSampleIdentityDelta(
            added: [], deletedUUIDs: ["sample-1", "missing"],
            deviceId: "apple-health", typeIdentifier: type)
        let replayed = try await store.reconcileAppleHealthSampleIdentityDelta(
            added: [], deletedUUIDs: ["sample-1", "missing"],
            deviceId: "apple-health", typeIdentifier: type)
        XCTAssertEqual(first, ["2026-10-04"])
        XCTAssertTrue(replayed.isEmpty)
    }

    func testAdditionWinsOverSameUuidTombstoneInOneDelta() async throws {
        let store = try await WhoopStore.inMemory()
        let type = "HKQuantityTypeIdentifierDietaryWater"
        _ = try await store.reconcileAppleHealthSampleIdentityDelta(
            added: [AppleHealthSampleIdentity(typeIdentifier: type, uuid: "sample-1",
                                              day: "2026-10-05", startTs: 1_791_400_000)],
            deletedUUIDs: ["sample-1"], deviceId: "apple-health", typeIdentifier: type)
        let days = try await store.appleHealthSampleIdentityDays(
            deviceId: "apple-health", typeIdentifier: type, uuids: ["sample-1"])
        XCTAssertEqual(days, ["2026-10-05"])
    }
}
