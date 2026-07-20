import XCTest

/// The categorized instructor Settings screen, notification preferences, and the IAP paywall.
final class SettingsAndPaywallUITests: FloweUITestCase {

    /// Open the instructor Settings sheet via the profile gear.
    /// Returns the step that failed, or nil on success, so a failure names where it died.
    private func openInstructorSettings() -> String? {
        launch(as: .instructor)
        selectTab("Profile")
        guard waitForAnyText(["Overview"], timeout: timeout) else { return "Profile never loaded" }

        let gear = app.buttons["instructor.settings"]
        guard gear.waitForExistence(timeout: timeout) else { return "Settings gear never appeared" }
        // The profile is still settling right after the tab switch, so a tap can land before the
        // button is hittable and be swallowed. Wait, then retry once if the sheet doesn't appear.
        _ = waitUntil({ gear.isHittable })
        gear.tap()
        if app.navigationBars["Settings"].waitForExistence(timeout: 10) { return nil }
        gear.tap()
        guard app.navigationBars["Settings"].waitForExistence(timeout: timeout) else {
            return "Settings sheet did not open"
        }
        return nil
    }

    /// Open Settings, failing the test with the offending step if it doesn't get there.
    private func requireInstructorSettings(file: StaticString = #filePath, line: UInt = #line) {
        if let failure = openInstructorSettings() {
            XCTFail("Could not open instructor Settings: \(failure)", file: file, line: line)
        }
    }

    // MARK: - Settings screen (categories)

    func testSettingsOpensAsScreenNotPopup() {
        requireInstructorSettings()
        XCTAssertTrue(app.navigationBars["Settings"].exists,
                      "Settings should be a navigation screen, not an action sheet")
    }

    func testSettingsShowsAllCategories() {
        requireInstructorSettings()
        for section in ["Profile", "Visibility & Plan", "Preferences", "Support"] {
            XCTAssertTrue(scrollToText([section]), "Settings category '\(section)' missing")
        }
    }

    func testSettingsProfileRowsExist() {
        requireInstructorSettings()
        XCTAssertTrue(waitForAnyText(["Edit Profile"], timeout: 10), "Edit Profile row missing")
        XCTAssertTrue(app.staticTexts["Availability"].exists || app.buttons["Availability"].exists,
                      "Availability row missing")
    }

    func testSettingsShowsSubscriptionStatus() {
        requireInstructorSettings()
        XCTAssertTrue(waitForAnyText(["Get Discovered"], timeout: 10), "Get Discovered row missing")
        XCTAssertTrue(waitForAnyText(["Not subscribed", "Visible", "Boost"], timeout: 10),
                      "Settings should surface the current subscription tier")
    }

    func testSettingsPreferencesRowsExist() {
        requireInstructorSettings()
        for row in ["Language", "Currency", "Notifications"] {
            XCTAssertTrue(scrollToText([row]), "Preference row '\(row)' missing")
        }
    }

    func testSettingsSupportLinksExist() {
        requireInstructorSettings()
        for link in ["Help & Support", "Privacy Policy", "Terms of Use"] {
            XCTAssertTrue(scrollToText([link]), "Support link '\(link)' missing")
        }
    }

    func testSettingsEditProfileRowOpensEditor() {
        requireInstructorSettings()
        XCTAssertTrue(waitForAnyText(["Edit Profile"], timeout: 10))
        tapText(["Edit Profile"])
        XCTAssertTrue(waitForAnyText(["BIO", "RATE PER SESSION"], timeout: 15),
                      "Edit Profile row should open the editor")
    }

    func testSettingsNotificationsRowOpensToggles() {
        requireInstructorSettings()
        XCTAssertTrue(waitForAnyText(["Notifications"], timeout: 10))
        tapText(["Notifications"])
        XCTAssertTrue(waitForAnyText(["Booking requests", "Session reminders", "Activity"], timeout: 15),
                      "Notifications row should open the preference toggles")
    }

    func testNotificationTogglesAreInteractive() {
        requireInstructorSettings()
        XCTAssertTrue(waitForAnyText(["Notifications"], timeout: 10))
        tapText(["Notifications"])
        XCTAssertTrue(waitForAnyText(["Booking requests"], timeout: 15))
        let toggle = app.switches.firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: timeout), "No notification toggles found")
        let before = toggle.value as? String
        // Tap the switch itself — the element spans the whole row, whose centre is the label.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertNotEqual(before, toggle.value as? String, "Toggle should flip state")
    }

    func testSettingsDoneDismisses() {
        requireInstructorSettings()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: timeout), "Done button missing")
        done.tap()
        XCTAssertTrue(waitForAnyText(["Overview"], timeout: 15), "Done should return to the profile")
    }

    // MARK: - Paywall

    func testPaywallOpensFromDashboardBanner() {
        launch(as: .instructor)
        let banner = app.buttons["dashboard.getDiscovered"]
        XCTAssertTrue(banner.waitForExistence(timeout: timeout), "Get discovered banner missing")
        _ = waitUntil({ banner.isHittable })
        banner.tap()
        XCTAssertTrue(waitForAnyText(["Get Discovered", "Subscribe so students can find and book you."],
                                     timeout: 15),
                      "Banner should open the paywall")
    }

    func testPaywallShowsBothTiers() {
        launch(as: .instructor)
        let banner = app.buttons["dashboard.getDiscovered"]
        XCTAssertTrue(banner.waitForExistence(timeout: timeout), "Get discovered banner missing")
        _ = waitUntil({ banner.isHittable })
        banner.tap()
        XCTAssertTrue(waitForAnyText(["Flowe Visible"], timeout: 15), "Visible tier missing")
        XCTAssertTrue(app.staticTexts["Flowe Boost"].exists, "Boost tier missing")
    }

    func testPaywallShowsComplianceFooter() {
        launch(as: .instructor)
        let banner = app.buttons["dashboard.getDiscovered"]
        XCTAssertTrue(banner.waitForExistence(timeout: timeout), "Get discovered banner missing")
        _ = waitUntil({ banner.isHittable })
        banner.tap()
        XCTAssertTrue(waitForAnyText(["Restore Purchases"], timeout: 15),
                      "Restore Purchases is required by App Review")
        XCTAssertNotNil(anyStaticText(["Terms of Use"]), "Terms of Use link required")
        XCTAssertNotNil(anyStaticText(["Privacy Policy"]), "Privacy Policy link required")
    }
}
