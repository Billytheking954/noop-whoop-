import XCTest

/// Guards the iPhone More navigation regression without referring to the retired macOS sidebar.
final class MoreListParityTests: XCTestCase {
    func testAlarmsRowRoutesToSmartAlarm() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../StrandiOS/App/RootTabView.swift")
            .standardizedFileURL
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("MoreRow(\"Alarms\", \"alarm.fill\", .alarms)"),
                      "The iPhone More screen must expose its Alarms row.")
        XCTAssertTrue(source.contains("case .alarms:          SmartAlarmView()"),
                      "The Alarms destination must display SmartAlarmView.")
    }
}
