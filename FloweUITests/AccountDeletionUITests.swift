import XCTest

/// In-app account deletion — App Store Review Guideline 5.1.1(v).
///
/// Both roles must be able to reach it from settings, it must say what it removes, and it must
/// tell the user how to revoke Sign in with Apple (Apple's TN3194 workaround for apps that hold
/// no refresh token). Deleting must actually end the session rather than just closing a sheet.
///
/// These run offline like every other UI test, so `MockDataStore.deleteAccount()` skips the
/// CloudKit sweep and exercises the local wipe plus the sign-out. The remote deletion in
/// `AccountDeletionService` is not covered here — that needs a real iCloud account.
final class AccountDeletionUITests: FloweUITestCase {

    // MARK: - Reaching it

    /// Open the student Settings sheet via the profile gear.
    @discardableResult
    private func openStudentSettings() -> Bool {
        launch(as: .student)
        selectTab("Profile")
        let gear = app.buttons["student.settings"]
        guard gear.waitForExistence(timeout: timeout) else { return false }
        _ = waitUntil({ gear.isHittable })
        gear.tap()
        if app.navigationBars["Settings"].waitForExistence(timeout: 10) { return true }
        gear.tap()   // the profile is still settling right after the tab switch
        return app.navigationBars["Settings"].waitForExistence(timeout: timeout)
    }

    /// Open the instructor Settings sheet via the profile gear.
    @discardableResult
    private func openInstructorSettings() -> Bool {
        launch(as: .instructor)
        selectTab("Profile")
        guard waitForAnyText(["Overview"], timeout: timeout) else { return false }
        let gear = app.buttons["instructor.settings"]
        guard gear.waitForExistence(timeout: timeout) else { return false }
        _ = waitUntil({ gear.isHittable })
        gear.tap()
        if app.navigationBars["Settings"].waitForExistence(timeout: 10) { return true }
        gear.tap()
        return app.navigationBars["Settings"].waitForExistence(timeout: timeout)
    }

    /// Settings → Delete Account sheet.
    private func openDeleteSheet(file: StaticString = #filePath, line: UInt = #line) {
        let row = app.buttons["account.delete"]
        XCTAssertTrue(scrollToText(["Delete Account"]) || row.exists,
                      "Delete Account row missing from Settings", file: file, line: line)
        XCTAssertTrue(row.waitForExistence(timeout: timeout),
                      "Delete Account row missing", file: file, line: line)
        _ = waitUntil({ row.isHittable })
        row.tap()
        XCTAssertTrue(app.buttons["account.delete.confirm"].waitForExistence(timeout: 15),
                      "Delete Account sheet did not open", file: file, line: line)
    }

    func testStudentSettingsOffersAccountDeletion() {
        XCTAssertTrue(openStudentSettings(), "Student Settings did not open")
        XCTAssertTrue(scrollToText(["Delete Account"]),
                      "Guideline 5.1.1(v): students must be able to delete their account in-app")
    }

    func testInstructorSettingsOffersAccountDeletion() {
        XCTAssertTrue(openInstructorSettings(), "Instructor Settings did not open")
        XCTAssertTrue(scrollToText(["Delete Account"]),
                      "Guideline 5.1.1(v): instructors must be able to delete their account in-app")
    }

    // MARK: - What it tells the user

    func testDeleteSheetExplainsWhatIsRemoved() {
        XCTAssertTrue(openStudentSettings())
        openDeleteSheet()
        XCTAssertTrue(waitForAnyText(["What gets deleted"], timeout: 15),
                      "The sheet must say what deletion removes")
        XCTAssertTrue(scrollToText(["This is permanent and cannot be undone."]),
                      "The user must be told deletion is irreversible")
    }

    /// Apple's TN3194 workaround: with no refresh token we cannot revoke server-side, so the app
    /// must tell the user to revoke the credential from Settings themselves.
    func testDeleteSheetExplainsHowToRevokeAppleID() {
        XCTAssertTrue(openStudentSettings())
        openDeleteSheet()
        XCTAssertTrue(scrollToTextContaining("Stop Using Apple ID"),
                      "TN3194 requires telling the user how to revoke Sign in with Apple")
    }

    /// Substring match. `anyStaticText` compares whole labels, but the revocation instruction is
    /// one clause inside a longer footer sentence.
    private func scrollToTextContaining(_ needle: String, swipes: Int = 6) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", needle)
        if app.staticTexts.matching(predicate).firstMatch.exists { return true }
        for _ in 0..<swipes {
            app.swipeUp()
            if app.staticTexts.matching(predicate).firstMatch.exists { return true }
        }
        return false
    }

    // MARK: - Behaviour

    func testCancellingTheSheetKeepsTheAccount() {
        XCTAssertTrue(openStudentSettings())
        openDeleteSheet()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: timeout), "Sheet Cancel missing")
        cancel.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 15),
                      "Cancelling should return to Settings with the account intact")
    }

    /// Confirming is two-step — the destructive button raises a dialog before anything is deleted.
    func testDeletionRequiresASecondConfirmation() {
        XCTAssertTrue(openStudentSettings())
        openDeleteSheet()
        app.buttons["account.delete.confirm"].tap()
        XCTAssertTrue(waitForAnyText(["Delete your Flowe account?"], timeout: 15),
                      "Deletion must ask for confirmation before erasing anything")
        XCTAssertTrue(app.buttons["Delete Permanently"].exists,
                      "Confirmation dialog missing its destructive action")
    }

    func testDismissingTheConfirmationDeletesNothing() {
        XCTAssertTrue(openStudentSettings())
        openDeleteSheet()
        app.buttons["account.delete.confirm"].tap()
        XCTAssertTrue(waitForAnyText(["Delete your Flowe account?"], timeout: 15))
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["account.delete.confirm"].waitForExistence(timeout: 15),
                      "Backing out of the dialog should leave the user on the sheet, still signed in")
    }

    func testStudentDeletionSignsOutToOnboarding() {
        XCTAssertTrue(openStudentSettings())
        openDeleteSheet()
        app.buttons["account.delete.confirm"].tap()
        XCTAssertTrue(waitForAnyText(["Delete your Flowe account?"], timeout: 15))
        app.buttons["Delete Permanently"].tap()

        XCTAssertTrue(waitForAnyText(["I'm here to train", "I'm here to teach"], timeout: 30),
                      "Deleting the account must end the session and return to onboarding")
        XCTAssertFalse(app.tabBars.firstMatch.exists,
                       "The signed-in tab shell should be gone after deletion")
    }

    func testInstructorDeletionSignsOutToOnboarding() {
        XCTAssertTrue(openInstructorSettings())
        openDeleteSheet()
        app.buttons["account.delete.confirm"].tap()
        XCTAssertTrue(waitForAnyText(["Delete your Flowe account?"], timeout: 15))
        app.buttons["Delete Permanently"].tap()

        XCTAssertTrue(waitForAnyText(["I'm here to train", "I'm here to teach"], timeout: 30),
                      "Deleting the account must end the session and return to onboarding")
    }
}
