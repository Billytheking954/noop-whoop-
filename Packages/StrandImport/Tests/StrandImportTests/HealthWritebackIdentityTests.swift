import XCTest
@testable import StrandImport

final class HealthWritebackIdentityTests: XCTestCase {
    func testReplacementKeysExcludeUnrelatedAppAuthoredHealthSamples() {
        XCTAssertTrue(HealthWriteback.isCurrentHeartRateKey("noop:heart-rate:1800000060"))
        XCTAssertFalse(HealthWriteback.isCurrentHeartRateKey("noop:heart-rate:other"))
        XCTAssertFalse(HealthWriteback.isCurrentHeartRateKey("noop:sleep:1800000060"))
        XCTAssertFalse(HealthWriteback.isCurrentHeartRateKey("noop:device:heart-rate:1800000060"))
        XCTAssertTrue(HealthWriteback.isCurrentWorkoutKey("noop:workout:1800000060"))
        XCTAssertFalse(HealthWriteback.isCurrentWorkoutKey("noop:workout:new-format:1800000060"))
        XCTAssertFalse(HealthWriteback.isCurrentWorkoutKey("foreign:workout:1800000060"))
    }

    func testHeartRateExternalUUIDIsStablePerMinuteBucket() {
        let a = HealthWriteback.appleHealthExternalUUID(kind: "heart-rate", identity: "1800000060")
        let same = HealthWriteback.appleHealthExternalUUID(kind: "heart-rate", identity: "1800000060")
        let next = HealthWriteback.appleHealthExternalUUID(kind: "heart-rate", identity: "1800000120")

        XCTAssertEqual(a, "noop:heart-rate:1800000060")
        XCTAssertEqual(a, same)
        XCTAssertNotEqual(a, next)
    }

    func testFailedSaveNeverRetiresCapturedHealthObjects() async {
        enum Failure: Error { case save }
        var retired: [String] = []

        do {
            try await HealthWriteback.replaceAfterSave(existing: ["old-a", "old-b"],
                save: { throw Failure.save },
                retire: { retired = $0 })
            XCTFail("save failure must propagate")
        } catch Failure.save {
            XCTAssertTrue(retired.isEmpty)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRetirementReceivesOnlyObjectsCapturedBeforeSave() async throws {
        var events: [String] = []
        let captured = ["old-a", "old-b"]

        try await HealthWriteback.replaceAfterSave(existing: captured,
            save: { events.append("saved-new") },
            retire: { old in
                XCTAssertEqual(old, captured)
                events.append("retired-old")
            })

        XCTAssertEqual(events, ["saved-new", "retired-old"])
    }
}
