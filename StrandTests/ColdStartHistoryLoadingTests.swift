import Foundation
import XCTest
@testable import Strand

/// Architectural regression checks for iPhone cold launch. These protect the
/// asynchronous load order; real iPhone timings still require device evidence.
final class ColdStartHistoryLoadingTests: XCTestCase {
    func testRecentSavedHistoryIsPublishedBeforeFullHistoryCatchUp() throws {
        let source = try sourceText("Strand/App/AppModel.swift")
        let activeDevice = try XCTUnwrap(source.range(of: "await self.wireSourceCoordinator()"))
        let recent = try XCTUnwrap(source.range(of: "await self.repo.refresh(days: 120)"))
        XCTAssertLessThan(activeDevice.lowerBound, recent.lowerBound)
        XCTAssertTrue(source.contains("_ = repo.adoptActiveDeviceId(registry.activeDeviceId)"))
        let full = try XCTUnwrap(source.range(
            of: "await self.repo.refresh()", range: recent.upperBound..<source.endIndex))
        let importGate = try XCTUnwrap(source.range(
            of: "while self.hasActiveImport", range: recent.upperBound..<full.lowerBound))

        XCTAssertLessThan(recent.lowerBound, importGate.lowerBound)
        XCTAssertLessThan(importGate.lowerBound, full.lowerBound)
        XCTAssertTrue(source.contains("await self.wireSourceCoordinator()"))
        XCTAssertTrue(source.contains("await self.intelligence.runTimestampHealIfNeeded()"))
    }

    func testRootTabDoesNotLaunchCompetingFullRefresh() throws {
        let source = try sourceText("StrandiOS/App/RootTabView.swift")
        let start = try XCTUnwrap(source.range(of: ".task {\n            // AppModel owns"))
        let end = try XCTUnwrap(source.range(
            of: ".task(id: repo.refreshSeq)", range: start.upperBound..<source.endIndex))
        let launchTask = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(launchTask.contains("repo.refresh("))
        XCTAssertTrue(launchTask.contains("FolderBackup.catchUpIfDue"))
        // Manual pull-to-refresh remains available without resetting local storage.
        XCTAssertTrue(source.contains("onRefresh: { await repo.refresh() }"))
    }

    private func sourceText(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
