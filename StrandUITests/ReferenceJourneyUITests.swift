import XCTest

/// Exercises the shipping views and navigation with the app's DEBUG-only stored fixtures.
final class ReferenceJourneyUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(screen: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-seed", "--simulator-validation", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
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
            capture(app, name: "detail-" + key)
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
            capture(app, name: "tab-" + name.lowercased())
        }
    }

    func testCalendarOpensDateSelection() {
        let app = launch()
        let calendar = app.buttons["noop.today.calendar"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 30))
        calendar.tap()
        XCTAssertTrue(app.datePickers.firstMatch.waitForExistence(timeout: 10))
    }

    /// No paired strap or import: meaningful cached scores must survive process termination.
    func testRepeatedCachedLaunchesAndRapidDateSwitches() {
        var samples: [Double] = []
        let app = launch()
        waitForPopulatedDay(app, offset: 0)
        capture(app, name: "today-cached-top")
        for _ in 0..<3 {
            app.terminate()
            let start = ProcessInfo.processInfo.systemUptime
            app.launch()
            waitForPopulatedDay(app, offset: 0)
            samples.append(ProcessInfo.processInfo.systemUptime - start)
        }
        let attachment = XCTAttachment(string: "Simulator UI launch-to-observed populated scores (includes XCTest launch/idle overhead; not first paint or physical-device speed): \(samples)")
        attachment.lifetime = .keepAlways
        add(attachment)
        let calendar = app.buttons["noop.today.calendar"]
        let original = stateFields(calendar)
        for _ in 0..<4 {
            swipeDay(app, older: true)
            swipeDay(app, older: false)
        }
        waitForPopulatedDay(app, offset: 0)
        let returned = stateFields(calendar)
        for key in ["day", "loaded", "offset", "rest", "charge"] {
            XCTAssertEqual(returned[key], original[key], "Returning to the same day must restore \(key)")
        }
        swipeDay(app, older: true)
        waitForPopulatedDay(app, offset: 1)
        capture(app, name: "yesterday-after-rapid-switch")
        for _ in 0..<4 { app.swipeUp() }
        capture(app, name: "today-scrolled-graphs")
        for _ in 0..<4 { app.swipeDown() }
        waitForPopulatedDay(app, offset: 1)
        for name in ["Health", "Activity", "More", "Today"] {
            let tab = app.tabBars.buttons[name]
            XCTAssertTrue(tab.exists)
            tab.tap()
            XCTAssertTrue(tab.isSelected)
        }
        XCTAssertFalse(app.otherElements["noop.today.saved-cache-unavailable"].exists)
        capture(app, name: "today-after-navigation")
    }

    func testYearOldSavedDatePopulatesWithoutFreshImport() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-seed", "--simulator-validation", "--validation-day-offset", "365",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        waitForPopulatedDay(app, offset: 365)
        let value = app.buttons["noop.today.calendar"].value as? String ?? ""
        XCTAssertTrue(value.contains("days=400"), value)
        let expectedDay = stateFields(app.buttons["noop.today.calendar"])["day"]
        XCTAssertFalse(app.staticTexts["Last night's sleep"].exists)
        XCTAssertTrue(app.staticTexts[expectedDay ?? "missing day"].exists)
        capture(app, name: "year-old-date")
        app.buttons["noop.today.ring.sleep_performance"].tap()
        XCTAssertTrue(app.staticTexts["Sleep"].firstMatch.waitForExistence(timeout: 20))
        let sleepDay = app.staticTexts["noop.sleep.day"]
        XCTAssertTrue(sleepDay.waitForExistence(timeout: 20))
        XCTAssertEqual(sleepDay.value as? String, expectedDay, "Sleep detail must retain the selected wake-day")
        assertNoCurrentSleepNotice(app)
        capture(app, name: "year-old-sleep-navigation")
        // Exercise the actual carousel, including quick reversals while per-night reads are pending.
        let previous = app.buttons["Previous night"]
        scrollTo(previous, in: app)
        let next = app.buttons["Next night"]
        for _ in 0..<3 {
            previous.tap()
            next.tap()
        }
        for _ in 0..<5 { app.swipeDown() }
        XCTAssertEqual(sleepDay.value as? String, expectedDay)
        assertNoCurrentSleepNotice(app)
        capture(app, name: "year-old-sleep-after-rapid-switch")
    }

    private func assertNoCurrentSleepNotice(_ app: XCUIApplication) {
        for title in ["Last night's sleep hasn't synced", "Waiting for last night's sleep",
                      "Last night's sleep wasn't detected", "Calculating last night's sleep…",
                      "Syncing strap history…"] {
            XCTAssertFalse(app.staticTexts[title].exists, "Historical sleep must not show: \(title)")
        }
    }

    private func waitForPopulatedDay(_ app: XCUIApplication, offset: Int) {
        let calendar = app.buttons["noop.today.calendar"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 60))
        let populated = NSPredicate { _, _ in
            let fields = self.stateFields(calendar)
            let historicalContentMatches = offset == 0 || (
                fields["sleepDay"] == fields["day"] && (fields["activityDays"] ?? "").split(separator: ",").allSatisfy { String($0) == fields["day"] })
            return historicalContentMatches && fields["offset"] == String(offset) && fields["day"] == fields["loaded"]
                && Double(fields["rest"] ?? "") != nil && Double(fields["charge"] ?? "") != nil
        }
        expectation(for: populated, evaluatedWith: calendar)
        waitForExpectations(timeout: 90)
        for key in ["sleep_performance", "recovery", "strain"] {
            let ring = app.buttons["noop.today.ring." + key]
            XCTAssertTrue(ring.exists && ring.isHittable, key)
            XCTAssertLessThanOrEqual(ring.frame.maxX, app.frame.maxX)
            XCTAssertGreaterThanOrEqual(ring.frame.minX, app.frame.minX)
        }
    }

    private func stateFields(_ element: XCUIElement) -> [String: String] {
        let value = element.value as? String ?? ""
        return Dictionary(uniqueKeysWithValues: value.split(separator: ";").compactMap { field -> (String, String)? in
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        })
    }

    private func swipeDay(_ app: XCUIApplication, older: Bool) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: older ? 0.25 : 0.8, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: older ? 0.8 : 0.25, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testInsightAlertPreferenceSurvivesRelaunch() {
        let app = launch(screen: "insightalerts")
        let control = app.switches["Recorded changes"]
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
        XCTAssertTrue(app.switches["Recorded changes"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.switches["Recorded changes"].value as? String, saved)
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

    /// CI runs without a physical strap. Verify the self-test is reachable from the actual
    /// iPhone navigation shell and produces a copyable, locally generated report.
    func testLocalSelfTestReportsWithoutConnectedStrap() {
        let app = launch()
        let more = app.tabBars.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 30))
        more.tap()

        let appSection = app.buttons["App"]
        scrollTo(appSection, in: app)
        if appSection.value as? String == "Collapsed" { appSection.tap() }

        let testCentre = app.buttons["Test Centre"]
        scrollTo(testCentre, in: app)
        XCTAssertTrue(testCentre.waitForExistence(timeout: 15))
        testCentre.tap()

        let run = app.buttons["noop.testcentre.run-local-selftest"]
        scrollTo(run, in: app)
        XCTAssertTrue(run.waitForExistence(timeout: 15))
        run.tap()

        XCTAssertTrue(app.staticTexts["noop.testcentre.local-selftest-status"]
            .waitForExistence(timeout: 90), "local diagnostics must finish without a strap")
        XCTAssertTrue(app.buttons["noop.testcentre.copy-local-selftest"].exists)
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, "Could not scroll to \(element)")
    }

}
