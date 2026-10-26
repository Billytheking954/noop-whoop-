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
