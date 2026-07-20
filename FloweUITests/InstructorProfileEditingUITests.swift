import XCTest

/// The instructor's public listing editor — photo, name, city, bio, rate, experience,
/// certification, specialties and session types — and how the profile surfaces what's still blank.
///
/// A listing is what a student judges before booking, and instructors pay for Boost to promote it,
/// so "can an instructor actually fill this in" is a revenue-path test, not a cosmetic one.
final class InstructorProfileEditingUITests: FloweUITestCase {

    /// Instructor profile → Edit Profile sheet.
    private func openEditor(file: StaticString = #filePath, line: UInt = #line) {
        launch(as: .instructor)
        selectTab("Profile")
        XCTAssertTrue(waitForAnyText(["Overview"], timeout: timeout),
                      "Profile never loaded", file: file, line: line)

        let edit = app.buttons["instructor.editProfile"]
        XCTAssertTrue(edit.waitForExistence(timeout: timeout),
                      "Edit Profile button missing from the profile header", file: file, line: line)
        _ = waitUntil({ edit.isHittable })
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit Profile"].waitForExistence(timeout: 15),
                      "Edit Profile sheet did not open", file: file, line: line)
    }

    // MARK: - Reachability

    func testEditProfileReachableFromProfileHeader() {
        openEditor()
        XCTAssertTrue(app.navigationBars["Edit Profile"].exists)
    }

    /// The old editor had three fields; a listing needs the full set to be worth promoting.
    func testEditorOffersEveryListingField() {
        openEditor()
        for label in ["NAME", "CITY", "BIO", "RATE PER SESSION",
                      "YEARS OF EXPERIENCE", "CERTIFICATION", "SPECIALTIES", "SESSION TYPES"] {
            XCTAssertTrue(scrollToText([label]), "Editor is missing the \(label) field")
        }
    }

    // MARK: - Photo

    func testEditorOffersAPhotoPicker() {
        openEditor()
        XCTAssertTrue(app.buttons["editProfile.photoPicker"].waitForExistence(timeout: timeout),
                      "Instructors must be able to set a profile photo")
    }

    /// With no photo set there is nothing to remove, so the control shouldn't be offered.
    func testRemovePhotoHiddenWhenThereIsNoPhoto() {
        openEditor()
        XCTAssertTrue(app.buttons["editProfile.photoPicker"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.buttons["editProfile.photoRemove"].exists,
                       "Remove should only appear once a photo exists")
    }

    // MARK: - Certification

    /// An unverified credential must not read as vetted — the disclaimer is the honest framing.
    func testCertificationSaysItIsNotVerified() {
        openEditor()
        XCTAssertTrue(scrollToText(["Shown on your public profile. Flowe doesn't verify certifications."]),
                      "The cert field must say Flowe doesn't verify it")
    }

    func testCertificationSavesAndAppearsOnProfile() {
        openEditor()
        let field = app.textFields["editProfile.cert"]
        XCTAssertTrue(scrollToText(["CERTIFICATION"]), "Certification field missing")
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText("BASI Comprehensive")

        app.buttons["editProfile.save"].tap()
        XCTAssertTrue(waitForAnyText(["Overview"], timeout: 15), "Save should return to the profile")
        // The header renders the certification uppercased.
        XCTAssertTrue(waitForAnyText(["BASI COMPREHENSIVE"], timeout: 15),
                      "A saved certification should show on the profile header")
    }

    func testCitySavesAndAppearsOnProfile() {
        openEditor()
        let field = app.textFields["editProfile.city"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "City field missing")
        field.tap()
        field.typeText("Beirut")

        app.buttons["editProfile.save"].tap()
        XCTAssertTrue(waitForAnyText(["Overview"], timeout: 15))
        XCTAssertTrue(waitForAnyText(["Beirut"], timeout: 15),
                      "A saved city should show on the profile header")
    }

    // MARK: - Saving rules

    /// A fresh instructor has no rate yet. Requiring one before *anything* can be saved would stop
    /// them setting a photo or bio first.
    func testSaveIsEnabledForAFreshProfileWithNoRate() {
        openEditor()
        XCTAssertTrue(app.buttons["editProfile.save"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.buttons["editProfile.save"].isEnabled,
                      "An unset rate should not block saving the rest of the profile")
    }

    func testSaveIsBlockedWithoutAName() {
        openEditor()
        let field = app.textFields["editProfile.name"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "Name field missing")
        field.tap()
        // Clear whatever the account seeded the name with.
        field.press(forDuration: 1.1)
        if app.menuItems["Select All"].waitForExistence(timeout: 3) {
            app.menuItems["Select All"].tap()
        }
        field.typeText(XCUIKeyboardKey.delete.rawValue)

        XCTAssertTrue(waitUntil({ !app.buttons["editProfile.save"].isEnabled }),
                      "A listing with no name should not be saveable")
    }

    // MARK: - Completeness

    /// A brand-new instructor's listing is empty; the profile should say what's missing rather than
    /// leave them to guess why no one books them.
    func testEmptyProfileShowsCompletenessNudge() {
        launch(as: .instructor)
        selectTab("Profile")
        XCTAssertTrue(waitForAnyText(["Overview"], timeout: timeout))
        XCTAssertTrue(app.buttons["instructor.completeness"].waitForExistence(timeout: timeout),
                      "An incomplete profile should surface what's still missing")
        XCTAssertTrue(waitForAnyText(["Finish your profile"], timeout: 10))
    }

    func testCompletenessNudgeOpensTheEditor() {
        launch(as: .instructor)
        selectTab("Profile")
        let nudge = app.buttons["instructor.completeness"]
        XCTAssertTrue(nudge.waitForExistence(timeout: timeout))
        _ = waitUntil({ nudge.isHittable })
        nudge.tap()
        XCTAssertTrue(app.navigationBars["Edit Profile"].waitForExistence(timeout: 15),
                      "The nudge should take the instructor straight to the editor")
    }

    // MARK: - Overview richness

    func testOverviewShowsRateAndCertificationSections() {
        launch(as: .instructor)
        selectTab("Profile")
        XCTAssertTrue(waitForAnyText(["Overview"], timeout: timeout))
        for section in ["ABOUT", "SPECIALTIES", "OFFERS", "RATE PER SESSION",
                        "CERTIFICATION", "AVAILABILITY"] {
            XCTAssertTrue(scrollToText([section]), "Overview is missing the \(section) section")
        }
    }
}
