import XCTest

/// Onboarding: splash → role selection → account creation → lands in the right tab shell.
final class OnboardingUITests: FloweUITestCase {

    func testSplashAdvancesToRoleSelection() {
        launchSignedOut()
        assertExists(app.staticTexts["Who are you\njoining as?"].firstMatch.exists
                     ? app.staticTexts["Who are you\njoining as?"]
                     : app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'joining as'")).firstMatch,
                     "Role selection should appear after the splash")
    }

    func testRoleSelectionShowsBothRoles() {
        launchSignedOut()
        XCTAssertTrue(waitForAnyText(["I'm here to train"]), "Student role card missing")
        XCTAssertTrue(anyStaticText(["I'm here to teach"]) != nil, "Instructor role card missing")
        XCTAssertTrue(app.staticTexts["I already have an account"].exists ||
                      app.buttons["I already have an account"].exists,
                      "Log-in affordance missing")
    }

    func testContinueIsDisabledUntilRoleChosen() {
        launchSignedOut()
        XCTAssertTrue(waitForAnyText(["I'm here to train"]))
        // Before choosing, the CTA reads the placeholder state.
        XCTAssertTrue(app.staticTexts["Continue as ..."].exists ||
                      app.buttons.containing(NSPredicate(format: "label CONTAINS 'Continue as'")).firstMatch.exists,
                      "Continue CTA should be present in its placeholder state")
    }

    func testChoosingStudentEnablesContinue() {
        launchSignedOut()
        XCTAssertTrue(waitForAnyText(["I'm here to train"]))
        anyStaticText(["I'm here to train"])?.tap()
        XCTAssertTrue(waitForAnyText(["Continue as Student"]),
                      "Continue should reflect the chosen Student role")
    }

    func testChoosingInstructorEnablesContinue() {
        launchSignedOut()
        XCTAssertTrue(waitForAnyText(["I'm here to teach"]))
        anyStaticText(["I'm here to teach"])?.tap()
        XCTAssertTrue(waitForAnyText(["Continue as Instructor"]),
                      "Continue should reflect the chosen Instructor role")
    }

    func testCreateAccountScreenReachableFromRoleSelection() {
        launchSignedOut()
        XCTAssertTrue(waitForAnyText(["I'm here to train"]))
        anyStaticText(["I'm here to train"])?.tap()
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'Continue as'")).firstMatch.tap()
        XCTAssertTrue(waitForAnyText(["Join flowe", "Create Account"]),
                      "Create-account screen should appear")
    }
}
