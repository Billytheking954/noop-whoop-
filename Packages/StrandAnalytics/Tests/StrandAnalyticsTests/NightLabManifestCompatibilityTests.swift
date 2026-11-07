import XCTest
@testable import StrandAnalytics

final class NightLabManifestCompatibilityTests: XCTestCase {

    func testV1ManifestWithoutProvenanceFieldsStillDecodes() throws {
        // Exact old schema shape: none of the v2 source-provenance keys exist. A research archive must
        // remain readable after the app evolves; missing provenance is represented as nil, never invented.
        let json = Data(#"{"nightID":"legacy-night","rawAssets":[],"schemaVersion":1,"state":"sealed","timezoneOffsetSeconds":0,"windowEndUnix":2000,"windowStartUnix":1000}"#.utf8)

        let manifest = try NightLabJSON.decode(NightRecordManifest.self, from: json)
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.nightID, "legacy-night")
        XCTAssertEqual(manifest.state, .sealed)
        XCTAssertNil(manifest.sourceDeviceID)
        XCTAssertNil(manifest.sourceDeviceModel)
        XCTAssertNil(manifest.sourceFirmware)
        XCTAssertNil(manifest.sourceStoreSchemaVersion)
        XCTAssertNil(manifest.sourceStreamFingerprint)
        XCTAssertNil(manifest.noopVersion)
    }

    func testCurrentManifestRoundTripsSourceProvenance() throws {
        let original = NightRecordManifest(
            nightID: "current-night",
            state: .sealed,
            windowStartUnix: 1_000,
            windowEndUnix: 2_000,
            timezoneOffsetSeconds: 3_600,
            sourceDeviceID: "whoop-5",
            sourceDeviceModel: "WHOOP 5.0",
            sourceFirmware: "50.0",
            sourceStoreSchemaVersion: 18,
            sourceStreamFingerprint: "source-witness",
            noopVersion: "11.6",
            rawAssets: []
        )

        let decoded = try NightLabJSON.decode(NightRecordManifest.self,
                                              from: NightLabJSON.encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.schemaVersion, NightRecordManifest.currentSchemaVersion)
    }
}
