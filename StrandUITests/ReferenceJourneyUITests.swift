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
        XCTAssertNotNil(original)

        let startedEnabled = original == "1"
        control.tap()

        // Enabling this preference requests a system notification permission. A denied permission is a
        // supported production outcome: the view resets the toggle and shows its Settings guidance. The
        // test therefore waits for that decision instead of assuming every simulator accepts the prompt.
        if !startedEnabled {
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 15) {
                allow.tap()
            }
            let deniedMessage = app.staticTexts[
                "Notifications are disabled in iPhone Settings. Allow NOOP notifications there to use these alerts."
            ]
            let denied = deniedMessage.waitForExistence(timeout: 10)
            let settled = control.value as? String
            if denied {
                XCTAssertEqual(settled, "0")
            } else {
                XCTAssertEqual(settled, "1")
            }
        } else {
            // Turning alerts off does not request system authorization.
            XCTAssertEqual(control.value as? String, "0")
        }

        let saved = control.value as? String
        app.terminate()
        app.launch()
        XCTAssertTrue(app.switches["Measured changes"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.switches["Measured changes"].value as? String, saved)
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
