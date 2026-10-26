import XCTest

/// Exercises the shipping views and navigation with the app's DEBUG-only stored fixtures.
final class ReferenceJourneyUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(screen: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-seed", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if let screen { app.launchArguments += ["--demo-screen", screen] }
        app.launch()
        return app
    }

    func testHeroRingsOpenTheirDetails() {
        for (key, title) in [("sleep_performance", "Sleep"), ("recovery", "Charge"), ("strain", "Effort")] {
            let app = launch()
            let ring = app.buttons["noop.today.ring." + key]
            XCTAssertTrue(ring.waitForExistence(timeout: 30), key)
            ring.tap()
            XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 20), title)
            app.terminate()
        }
    }

    func testFourTabsReachTheirScreens() {
        let app = launch()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 30))
        for name in ["Today", "Health", "Activity", "More"] {
            let button = tabs.buttons[name]
            XCTAssertTrue(button.exists, name)
            button.tap()
            XCTAssertTrue(button.isSelected, name)
        }
    }

    /// Seeded iPhone Simulator regression for freezes on rapid native tab switching and
    /// reselecting Today's tab. No real BLE or iPhone energy claims are made here.
    func testRepeatedTabSwitchesAndDeviceShortcutRemainResponsive() {
        let app = launch()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 30))
        for _ in 0..<3 {
            for name in ["Health", "Activity", "More", "Today"] {
                let button = tabs.buttons[name]
                XCTAssertTrue(button.waitForExistence(timeout: 10), name)
                button.tap()
                XCTAssertTrue(button.isSelected, "Switch to " + name + " failed")
            }
        }
        let today = tabs.buttons["Today"]
        today.tap() // reselect must not force a heavy dashboard refresh or freeze
        XCTAssertTrue(today.isSelected)
        let shortcut = app.buttons["noop.today.device-battery"]
        XCTAssertTrue(shortcut.waitForExistence(timeout: 15),
                      "the WHOOP device shortcut should be accessible on Today")
        shortcut.tap()
        XCTAssertTrue(app.buttons["Manage paired devices"].waitForExistence(timeout: 15),
                      "the shortcut should open the existing device screen")
    }

    /// Root screens must scroll vertically without a second gesture attempting to move tabs.
    /// This covers the original diagonal-drag regression on the primary iPhone screens.
    func testVerticalScrollingKeepsTheSelectedTab() {
        let app = launch()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 30))

        for name in ["Health", "Activity", "More"] {
            let button = tabs.buttons[name]
            button.tap()
            XCTAssertTrue(button.isSelected, name)
            app.swipeUp()
            XCTAssertTrue(button.isSelected, "\(name) changed during upward scrolling")
            app.swipeDown()
            XCTAssertTrue(button.isSelected, "\(name) changed during downward scrolling")
        }
    }

    /// Swipe-to-switch tabs was removed intentionally: charts, scrolling and native
    /// navigation should handle their own horizontal gestures without a root recognizer.
    func testHorizontalDragDoesNotSwitchPrimaryTab() {
        let app = launch()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 30))

        let health = tabs.buttons["Health"]
        health.tap()
        XCTAssertTrue(health.isSelected)
        app.swipeLeft()
        XCTAssertTrue(health.isSelected, "Left drag unexpectedly changed tabs")
        app.swipeRight()
        XCTAssertTrue(health.isSelected, "Right drag unexpectedly changed tabs")
    }

    /// Phase 2: navigate to the real Deep Timeline via Trends, not the
    /// stand-alone DEBUG preview, so the correct NavigationStack is exercised.
    func testTrendsOpenDayDetailWithoutChangingTabs() {
        let app = launch()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 30))

        let more = tabs.buttons["More"]
        more.tap()
        let trends = app.buttons["Trends"].firstMatch
        XCTAssertTrue(trends.waitForExistence(timeout: 20))
        trends.tap()

        let detail = app.buttons["noop.trends.dayDetail"].firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 20))
        detail.tap()

        let signal = app.buttons["noop.timeline.signal"].firstMatch
        XCTAssertTrue(signal.waitForExistence(timeout: 20))
        app.swipeUp()
        XCTAssertTrue(more.isSelected, "Timeline vertical scrolling changed the selected tab")
        XCTAssertTrue(signal.exists, "Signal picker disappeared after scrolling")
    }

    func testCalendarOpensDateSelection() {
        let app = launch()
        let calendar = app.buttons["noop.today.calendar"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 30))
        calendar.tap()
        XCTAssertTrue(app.datePickers.firstMatch.waitForExistence(timeout: 10))
    }

    func testInsightAlertPreferenceSurvivesRelaunch() {
        let app = launch(screen: "insightalerts")
        let control = app.switches["Measured changes"]
        XCTAssertTrue(control.waitForExistence(timeout: 30))
        let original = control.value as? String
        control.tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        let changed = NSPredicate(format: "value != %@", original ?? "")
        expectation(for: changed, evaluatedWith: control)
        waitForExpectations(timeout: 10)
        let saved = control.value as? String
        app.terminate()
        app.launch()
        XCTAssertTrue(app.switches["Measured changes"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.switches["Measured changes"].value as? String, saved)
    }

    /// CI runs without a physical strap. Verify the self-test is reachable from the actual
    /// iPhone navigation shell and produces a copyable, locally generated report.
    func testLocalSelfTestReportsWithoutConnectedStrap() {
        let app = launch()
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 30))
        more.tap()

        let testCentre = app.buttons["Test Centre"]
        XCTAssertTrue(testCentre.waitForExistence(timeout: 15))
        testCentre.tap()

        let run = app.buttons["noop.testcentre.run-local-selftest"]
        XCTAssertTrue(run.waitForExistence(timeout: 15))
        run.tap()

        XCTAssertTrue(app.staticTexts["noop.testcentre.local-selftest-status"]
            .waitForExistence(timeout: 90), "local diagnostics must finish without a strap")
        XCTAssertTrue(app.buttons["Copy local self-test report"].exists)
    }

    func testSetUpLaterRetainsRequirementsAndSkipsPairing() {
        let app = launch(screen: "addwizard")
        let later = app.buttons["Set up later"]
        XCTAssertTrue(later.waitForExistence(timeout: 30))
        later.tap()
        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["What to expect"].waitForExistence(timeout: 10))
        app.buttons["I understand"].tap()
        XCTAssertTrue(app.staticTexts["About you"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Find a nearby strap"].exists)
    }
}
