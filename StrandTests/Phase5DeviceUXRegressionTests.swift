import XCTest
@testable import Strand

/// Device UX regressions from the physical iPhone Phase 4 bug report.
/// Visual/performance effects also require simulator and physical device tests.
@MainActor
final class Phase5DeviceUXRegressionTests: XCTestCase {
    func testBatteryPercentIsCleanAndIntegral() {
        XCTAssertEqual(DeviceBatteryDisplay.percent(75.000000), "75%")
        XCTAssertEqual(DeviceBatteryDisplay.percent(75.4), "75%")
        XCTAssertEqual(DeviceBatteryDisplay.percent(75.6), "76%")
        XCTAssertEqual(DeviceBatteryDisplay.percent(0), "0%")
        XCTAssertEqual(DeviceBatteryDisplay.percent(100), "100%")
    }

    func testUnknownAndCorruptBatteryValuesStayUnknown() {
        let invalid: [Double?] = [nil, .nan, .infinity, -.infinity, -1, 100.1]
        for pct in invalid {
            XCTAssertEqual(DeviceBatteryDisplay.percent(pct), "—")
        }
    }

    func testBatteryVoiceOverLabelsRespectConnectionAndReportedCharging() {
        let charging = DeviceBatteryDisplay.voiceOverLabel(
            connected: true, charging: true, battery: 75)
        let notCharging = DeviceBatteryDisplay.voiceOverLabel(
            connected: true, charging: false, battery: 75)
        let unknown = DeviceBatteryDisplay.voiceOverLabel(
            connected: true, charging: nil, battery: nil)
        let disconnected = DeviceBatteryDisplay.voiceOverLabel(
            connected: false, charging: nil, battery: 75)

        XCTAssertTrue(charging.contains("75%"))
        XCTAssertTrue(notCharging.contains("75%"))
        XCTAssertTrue(unknown.contains("—"))
        XCTAssertTrue(notCharging.contains(DeviceBatteryDisplay.notCharging))
        XCTAssertTrue(unknown.contains(DeviceBatteryDisplay.chargingUnavailable))
        XCTAssertNotEqual(notCharging, unknown)
        XCTAssertFalse(disconnected.contains("75%"))
        XCTAssertFalse(charging.isEmpty)
        XCTAssertFalse(disconnected.isEmpty)
    }

    func testDeviceBatteryCopyIsTranslatedInShippingStringTable() throws {
        let file = try sourceText("Strand/Resources/Phase3.xcstrings")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(file.utf8)) as? [String: Any])
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        for key in [
            "Not charging", "Charging status unavailable", "Device not connected",
            "Open device settings", "WHOOP charging, %@", "WHOOP device, %@",
            "WHOOP disconnected"
        ] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "Missing \(key)")
            let translations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for language in ["de", "es", "fr", "pt-PT"] {
                let value = try XCTUnwrap(translations[language] as? [String: Any],
                                          "\(key) lacks \(language)")
                let unit = try XCTUnwrap(value["stringUnit"] as? [String: String])
                XCTAssertEqual(unit["state"], "translated")
                if key.contains("%@") {
                    XCTAssertTrue(unit["value", default: ""].contains("%@"),
                                  "VoiceOver argument missing in \(language)")
                }
            }
        }
    }

    func testDeviceArtworkHasDepthAndWovenDetailRatherThanTubePlaceholder() throws {
        let source = try sourceText(
            "Packages/StrandDesign/Sources/StrandDesign/ReferenceComponents.swift")
        let deviceSource = try sourceText("Strand/Screens/DevicesView.swift")
        guard let start = source.range(of: "public struct ReferenceBandIllustration: View") else {
            return XCTFail("Device illustration missing")
        }
        let illustration = source[start.lowerBound...]
        XCTAssertTrue(illustration.contains("FillStyle(eoFill: true)"))
        XCTAssertTrue(illustration.contains("Canvas { context"))
        XCTAssertTrue(illustration.contains("sensor surface"))
        XCTAssertTrue(source.contains("ReferenceBandIllustration: View, Equatable"))
        XCTAssertTrue(deviceSource.contains("ReferenceBandIllustration()"))
        XCTAssertTrue(deviceSource.contains(".equatable()"))
        XCTAssertFalse(illustration.contains("Ellipse().stroke"))
        XCTAssertFalse(illustration.contains("Color(white:"))
    }

    /// Prevent reintroducing an unconditional full-repository refresh on a tab re-tap.
    /// Pull-to-refresh and on-launch refresh still exist separately.
    func testTabReselectionNeverRequeriesFullDashboard() throws {
        let source = try sourceText("StrandiOS/App/RootTabView.swift")
        guard let begin = source.range(of: "private func reselectTab(_ tag: Int) {"),
              let end = source.range(of: "\n    var body: some View", range: begin.upperBound..<source.endIndex)
        else { return XCTFail("Could not find the native tab reselect handler") }
        let block = String(source[begin.lowerBound..<end.lowerBound])
        XCTAssertFalse(block.contains("repo.refresh()"))
        XCTAssertTrue(block.contains("scrollTop[tag] += 1"))
        XCTAssertFalse(source.contains(".animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24), value: selectedTab)"))
    }

    func testDeviceShortcutUsesExistingDeviceNavigation() throws {
        let source = try sourceText("Strand/Screens/TodayView.swift")
        XCTAssertTrue(source.contains("TodayDeviceBatteryShortcut()"))
        XCTAssertTrue(source.contains("Button { router.openDevices() } label: {"))
        XCTAssertTrue(source.contains("noop.today.device-battery"))
    }

    private func sourceText(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
