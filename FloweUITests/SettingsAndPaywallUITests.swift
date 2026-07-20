import XCTest

/// The categorized instructor Settings screen, notification preferences, and the IAP paywall.
final class SettingsAndPaywallUITests: FloweUITestCase {

    /// Open the instructor Settings sheet via the profile gear.
    private func openInstructorSettings() -> Bool {
        launch(as: .instructor)
        selectTab("Profile")
        guard waitForAnyText(["Overview"], timeout: timeout) else { return false }
        let gear = app.buttons["instructor.settings"]
        guard gear.waitForExistence(timeout: timeout) else { return false }
        gear.tap()
        return waitForAnyText(["Settings"], timeout: timeout)
    }

    // MARK: - Settings screen (categories)

    func testSettingsOpensAsScreenNotPopup() {
        XCTAssertTrue(openInstructorSettings(), "Gear should open the Settings screen")
        XCTAssertTrue(app.navigationBars["Settings"].exists,
                      "Settings should be a navigation screen, not an action sheet")
    }

    func testSettingsShowsAllCategories() {
        XCTAssertTrue(openInstructorSettings())
        for section in ["Profile", "Visibility & Plan", "Preferences", "Support"] {
            XCTAssertTrue(scrollToText([section]), "Settings category '\(section)' missing")
        }
    }

    func testSettingsProfileRowsExist() {
        XCTAssertTrue(openInstructorSettings())
        XCTAssertTrue(waitForAnyText(["Edit Profile"], timeout: 10), "Edit Profile row missing")
        XCTAssertTrue(app.staticTexts["Availability"].exists || app.buttons["Availability"].exists,
                      "Availability row missing")
    }

    func testSettingsShowsSubscriptionStatus() {
        XCTAssertTrue(openInstructorSettings())
        XCTAssertTrue(waitForAnyText(["Get Discovered"], timeout: 10), "Get Discovered row missing")
        XCTAssertTrue(waitForAnyText(["Not subscribed", "Visible", "Boost"], timeout: 10),
                      "Settings should surface the current subscription tier")
    }

    func testSettingsPreferencesRowsExist() {
        XCTAssertTrue(openInstructorSettings())
        for row in ["Language", "Currency", "Notifications"] {
            XCTAssertTrue(scrollToText([row]), "Preference row '\(row)' missing")
        }
    }

    func testSettingsSupportLinksExist() {
        XCTAssertTrue(openInstructorSettings())
        for link in ["Help & Support", "Privacy Policy", "Terms of Use"] {
            XCTAssertTrue(scrollToText([link]), "Support link '\(link)' missing")
        }
    }

    func testSettingsEditProfileRowOpensEditor() {
        XCTAssertTrue(openInstructorSettings())
        XCTAssertTrue(waitForAnyText(["Edit Profile"], timeout: 10))
        app.staticTexts["Edit Profile"].firstMatch.tap()
        XCTAssertTrue(waitForAnyText(["BIO", "RATE PER SESSION"], timeout: 15),
                      "Edit Profile row should open the editor")
    }

    func testSettingsNotificationsRowOpensToggles() {
        XCTAssertTrue(openInstructorSettings())
        XCTAssertTrue(waitForAnyText(["Notifications"], timeout: 10))
        app.staticTexts["Notifications"].firstMatch.tap()
        XCTAssertTrue(waitForAnyText(["Booking requests", "Session reminders", "Activity"], timeout: 15),
                      "Notifications row should open the preference toggles")
    }

    func testNotificationTogglesAreInteractive() {
        XCTAssertTrue(openInstructorSettings())
        XCTAssertTrue(waitForAnyText(["Notifications"], timeout: 10))
        app.staticTexts["Notifications"].firstMatch.tap()
        XCTAssertTrue(waitForAnyText(["Booking requests"], timeout: 15))
        let toggle = app.switches.firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: timeout), "No notification toggles found")
        let before = toggle.value as? String
        // Tap the switch itself — the element spans the whole row, whose centre is the label.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertNotEqual(before, toggle.value as? String, "Toggle should flip state")
    }

    func testSettingsDoneDismisses() {
        XCTAssertTrue(openInstructorSettings())
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: timeout), "Done button missing")
        done.tap()
        XCTAssertTrue(waitForAnyText(["Overview"], timeout: 15), "Done should return to the profile")
    }

    // MARK: - Paywall

    func testPaywallOpensFromDashboardBanner() {
        launch(as: .instructor)
        XCTAssertTrue(waitForAnyText(["Get discovered"], timeout: timeout))
        app.staticTexts["Get discovered"].firstMatch.tap()
        XCTAssertTrue(waitForAnyText(["Get Discovered", "Subscribe so students can find and book you."],
                                     timeout: 15),
                      "Banner should open the paywall")
    }

    func testPaywallShowsBothTiers() {
        launch(as: .instructor)
        XCTAssertTrue(waitForAnyText(["Get discovered"], timeout: timeout))
        app.staticTexts["Get discovered"].firstMatch.tap()
        XCTAssertTrue(waitForAnyText(["Flowe Visible"], timeout: 15), "Visible tier missing")
        XCTAssertTrue(app.staticTexts["Flowe Boost"].exists, "Boost tier missing")
    }

    func testPaywallShowsComplianceFooter() {
        launch(as: .instructor)
        XCTAssertTrue(waitForAnyText(["Get discovered"], timeout: timeout))
        app.staticTexts["Get discovered"].firstMatch.tap()
        XCTAssertTrue(waitForAnyText(["Restore Purchases"], timeout: 15),
                      "Restore Purchases is required by App Review")
        XCTAssertNotNil(anyStaticText(["Terms of Use"]), "Terms of Use link required")
        XCTAssertNotNil(anyStaticText(["Privacy Policy"]), "Privacy Policy link required")
    }
}
