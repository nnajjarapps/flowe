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

    // MARK: - Apple-only sign-in

    /// The email/password form verified nothing — it checked the fields were non-empty and signed
    /// the user in, and every login minted a new identity that orphaned their data. Sign in with
    /// Apple is the only credential this app can honestly issue, so the form must stay gone.
    func testCreateAccountOffersOnlyAppleSignIn() {
        launchSignedOut()
        XCTAssertTrue(waitForAnyText(["I'm here to train"]))
        anyStaticText(["I'm here to train"])?.tap()
        app.buttons.containing(NSPredicate(format: "label CONTAINS 'Continue as'")).firstMatch.tap()
        XCTAssertTrue(waitForAnyText(["Join flowe"]), "Create-account screen should appear")

        XCTAssertTrue(app.buttons["createAccount.apple"].waitForExistence(timeout: timeout),
                      "Sign in with Apple must be offered")
        XCTAssertEqual(app.secureTextFields.count, 0,
                       "No password field should remain — nothing could verify it")
        XCTAssertEqual(app.textFields.count, 0,
                       "No name/email fields should remain — Apple supplies both")
    }

    func testLoginOffersOnlyAppleSignIn() {
        launchSignedOut()
        XCTAssertTrue(waitForAnyText(["I already have an account"]))
        tapText(["I already have an account"])
        XCTAssertTrue(waitForAnyText(["Welcome back"], timeout: 15), "Login screen should appear")

        XCTAssertTrue(app.buttons["login.apple"].waitForExistence(timeout: timeout),
                      "Sign in with Apple must be offered")
        XCTAssertEqual(app.secureTextFields.count, 0,
                       "No password field should remain — nothing could verify it")
        XCTAssertNil(anyStaticText(["Forgot Password?"]),
                     "Password recovery makes no sense without password auth")
    }

    /// Users should be told why Apple is the only option rather than left wondering.
    func testLoginExplainsWhyAppleIsTheOnlyOption() {
        launchSignedOut()
        XCTAssertTrue(waitForAnyText(["I already have an account"]))
        tapText(["I already have an account"])
        XCTAssertTrue(waitForAnyText(["Welcome back"], timeout: 15))

        let predicate = NSPredicate(format: "label CONTAINS[c] %@", "never see your password")
        XCTAssertTrue(app.staticTexts.matching(predicate).firstMatch.waitForExistence(timeout: timeout),
                      "The screen should explain what Apple sign-in means for the user")
    }
}
