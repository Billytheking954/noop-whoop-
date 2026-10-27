import Foundation
import XCTest
@testable import Strand

/// Architecture guards for the NOOP 12 cold-start trial. Device performance
/// cannot be inferred from these tests; only the expected loading order.
final class ColdStartHistoryLoadingTests: XCTestCase {
    func testRecentSavedDaysLoadBeforeTheFullHistoryPass() throws {
        let source = try text("Strand/App/AppModel.swift")
        let wire = try XCTUnwrap(source.range(of: "await self.wireSourceCoordinator()"))
        let recent = try XCTUnwrap(source.range(of: "await self.repo.refresh(days: 120)"))
        let full = try XCTUnwrap(source.range(
            of: "await self.repo.refresh()", range: recent.upperBound..<source.endIndex))
        let importWait = try XCTUnwrap(source.range(
            of: "while self.hasActiveImport", range: recent.upperBound..<full.lowerBound))
        XCTAssertLessThan(wire.lowerBound, recent.lowerBound)
        XCTAssertLessThan(recent.lowerBound, importWait.lowerBound)
        XCTAssertLessThan(importWait.lowerBound, full.lowerBound)
        XCTAssertTrue(source.contains("_ = repo.adoptActiveDeviceId(registry.activeDeviceId)"))
        XCTAssertTrue(source.contains("await self.intelligence.runTimestampHealIfNeeded()"))
        XCTAssertTrue(source.contains("await self.intelligence.runEffortRescoreIfNeeded()"))
    }

    func testRootViewDoesNotLaunchACompetingRefreshOrRefreshOnRetap() throws {
        let source = try text("StrandiOS/App/RootTabView.swift")
        let task = try XCTUnwrap(source.range(of: ".task {\n            // AppModel alone"))
        let tail = try XCTUnwrap(source.range(
            of: ".task(id: repo.refreshSeq)", range: task.upperBound..<source.endIndex))
        XCTAssertFalse(source[task.lowerBound..<tail.lowerBound].contains("repo.refresh()"))
        let reselect = try XCTUnwrap(source.range(of: "private func reselectTab(_ tag: Int)"))
        let next = try XCTUnwrap(source.range(
            of: "private var tabSwipeGesture:", range: reselect.upperBound..<source.endIndex))
        XCTAssertFalse(source[reselect.lowerBound..<next.lowerBound].contains("repo.refresh()"))
        XCTAssertTrue(source.contains("onRefresh: { await repo.refresh() }"))
        XCTAssertTrue(source.contains("FolderBackup.catchUpIfDue"))
    }

    func testReadOnlyDiagnosticNeverOpensAStoreOrResetsData() throws {
        let source = try text("Strand/System/LocalSelfTest.swift")
        XCTAssertTrue(source.contains("existingStoreForDiagnostics()"))
        XCTAssertFalse(source.contains("repo.storeHandle()"))
        XCTAssertFalse(source.contains("checkpointWAL("))
        XCTAssertFalse(source.contains("deleteAll("))
        XCTAssertFalse(source.contains("requestSync("))
        XCTAssertTrue(source.contains("ColdLaunchTrace.latest()"))
    }

    func testColdLaunchDiagnosticsDoNotCountAnEmptyPreHydrationTodayPass() throws {
        let source = try text("Strand/Screens/TodayView.swift")
        let diagnostics = try text("Strand/System/LocalSelfTest.swift")
        XCTAssertTrue(source.contains("if repo.loaded && !Task.isCancelled { ColdLaunchTrace.finishTodayDataLoad() }"))
        XCTAssertTrue(diagnostics.contains("Time to first completed Today data calculation"))
        XCTAssertTrue(diagnostics.contains("first frame paint"))
        XCTAssertTrue(diagnostics.contains("UserDefaults.standard.removeObject(forKey: prefix + suffix)"))
    }

    private func text(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
    }
}
