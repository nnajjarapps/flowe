import XCTest

/// Blocking, reporting and content filtering — App Store Review Guideline 1.2, which requires an
/// app hosting user-generated content to filter it, let users report it, and let users block
/// abusive accounts.
///
/// Flowe's user-generated content is chat messages and the instructor listing's text (name, city,
/// bio, certification), the latter being publicly visible to every student.
final class ModerationUITests: FloweUITestCase {

    // MARK: - Blocked users list

    private func openStudentSettings() -> Bool {
        launch(as: .student)
        selectTab("Profile")
        let gear = app.buttons["student.settings"]
        guard gear.waitForExistence(timeout: timeout) else { return false }
        _ = waitUntil({ gear.isHittable })
        gear.tap()
        if app.navigationBars["Settings"].waitForExistence(timeout: 10) { return true }
        gear.tap()
        return app.navigationBars["Settings"].waitForExistence(timeout: timeout)
    }

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

    func testStudentSettingsExposesBlockedUsers() {
        XCTAssertTrue(openStudentSettings(), "Student Settings did not open")
        XCTAssertTrue(scrollToText(["Blocked users"]),
                      "Guideline 1.2: blocking must be reversible, so the list has to be reachable")
    }

    func testInstructorSettingsExposesBlockedUsers() {
        XCTAssertTrue(openInstructorSettings(), "Instructor Settings did not open")
        XCTAssertTrue(scrollToText(["Blocked users"]), "Blocked users row missing for instructors")
    }

    func testBlockedUsersListOpensWithAnEmptyState() {
        XCTAssertTrue(openStudentSettings())
        let row = app.buttons["settings.blockedUsers"]
        XCTAssertTrue(row.waitForExistence(timeout: timeout), "Blocked users row missing")
        _ = waitUntil({ row.isHittable })
        row.tap()
        XCTAssertTrue(waitForAnyText(["No blocked users"], timeout: 15),
                      "An empty block list should say so rather than show a blank screen")
    }

    // MARK: - Reporting a conversation

    /// Compose → open a thread, which is where the moderation menu lives.
    private func openConversation() -> Bool {
        launch(as: .student, seeded: true)
        selectTab("Messages")
        guard waitForAnyText(["Messages"], timeout: timeout) else { return false }
        let compose = app.buttons["messages.compose"]
        guard compose.waitForExistence(timeout: timeout) else { return false }
        compose.tap()
        guard waitForAnyText(["New Message"], timeout: 15) else { return false }

        for index in 0..<app.buttons.count {
            let candidate = app.buttons.element(boundBy: index)
            guard candidate.exists, candidate.isHittable,
                  candidate.label != "Cancel", !candidate.label.isEmpty else { continue }
            candidate.tap()
            if app.textFields["conversation.field"].waitForExistence(timeout: 5) { return true }
        }
        return false
    }

    func testConversationOffersReportAndBlock() {
        XCTAssertTrue(openConversation(), "Could not open a conversation")
        let menu = app.buttons["conversation.moderation"]
        XCTAssertTrue(menu.waitForExistence(timeout: timeout),
                      "A chat thread must offer report and block")
        menu.tap()
        XCTAssertTrue(waitForAnyText(["Report"], timeout: 10) ||
                      app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Report'")).firstMatch.exists,
                      "Report action missing from the conversation menu")
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Block'")).firstMatch.exists,
                      "Block action missing from the conversation menu")
    }

    func testReportSheetOffersReasonsAndBlockToggle() {
        XCTAssertTrue(openConversation())
        let menu = app.buttons["conversation.moderation"]
        XCTAssertTrue(menu.waitForExistence(timeout: timeout))
        menu.tap()
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Report'")).firstMatch.tap()

        XCTAssertTrue(waitForAnyText(["Why are you reporting this?"], timeout: 15),
                      "Report sheet did not open")
        XCTAssertTrue(scrollToText(["Harassment or bullying"]), "Report reasons missing")
        XCTAssertTrue(app.switches["report.alsoBlock"].waitForExistence(timeout: timeout),
                      "Report should offer to block in the same pass")
        XCTAssertTrue(app.buttons["report.submit"].exists, "Submit button missing")
    }

    /// Blocking from the thread should take the user out of it and clear it from the inbox.
    func testBlockingFromAConversationRemovesItFromTheInbox() {
        XCTAssertTrue(openConversation())

        let field = app.textFields["conversation.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText("Message before blocking")
        app.buttons["conversation.send"].tap()
        XCTAssertTrue(waitForAnyText(["Message before blocking"], timeout: 15))

        let menu = app.buttons["conversation.moderation"]
        XCTAssertTrue(menu.waitForExistence(timeout: timeout))
        menu.tap()
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH 'Block'")).firstMatch.tap()

        let confirm = app.buttons["Block"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Block confirmation missing")
        confirm.tap()

        // Back out of the compose sheet to the inbox.
        if app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 10) {
            app.buttons["Cancel"].firstMatch.tap()
        }
        XCTAssertTrue(waitForAnyText(["No messages yet"], timeout: 15),
                      "A blocked person's conversation must disappear from the inbox")
    }

    // MARK: - Reporting an instructor listing

    func testInstructorListingCanBeReported() {
        launch(as: .student, seeded: true)
        selectTab("Discover")
        // The card opens the booking sheet, which doubles as the student-facing profile detail.
        let card = app.buttons["discover.instructorCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: timeout), "No instructor cards in Discover")
        _ = waitUntil({ card.isHittable })
        card.tap()

        XCTAssertTrue(app.buttons["booking.moderation"].waitForExistence(timeout: 15),
                      "A public instructor listing must be reportable")
    }

    func testInstructorListingReportOpensTheReportSheet() {
        launch(as: .student, seeded: true)
        selectTab("Discover")
        let card = app.buttons["discover.instructorCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: timeout))
        _ = waitUntil({ card.isHittable })
        card.tap()

        let menu = app.buttons["booking.moderation"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        app.buttons["Report this profile"].tap()
        XCTAssertTrue(waitForAnyText(["Why are you reporting this?"], timeout: 15),
                      "Reporting a listing should open the report sheet")
    }

    // MARK: - Content filtering

    /// Listing text is broadcast to every student, so it is screened before publishing.
    func testObjectionableBioIsRejected() {
        launch(as: .instructor)
        selectTab("Profile")
        XCTAssertTrue(waitForAnyText(["Overview"], timeout: timeout))
        let edit = app.buttons["instructor.editProfile"]
        XCTAssertTrue(edit.waitForExistence(timeout: timeout))
        _ = waitUntil({ edit.isHittable })
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit Profile"].waitForExistence(timeout: 15))

        let bio = app.textViews["editProfile.bio"]
        XCTAssertTrue(bio.waitForExistence(timeout: timeout), "Bio field missing")
        bio.tap()
        bio.typeText("I will not tolerate this shit from students")

        app.buttons["editProfile.save"].tap()
        XCTAssertTrue(waitForAnyText(["Check your profile"], timeout: 15),
                      "Objectionable wording must be refused before it reaches the public catalog")
    }

    /// Contact details in a public bio route students off-platform and are the usual scam shape.
    func testContactDetailsInBioAreRejected() {
        launch(as: .instructor)
        selectTab("Profile")
        XCTAssertTrue(waitForAnyText(["Overview"], timeout: timeout))
        let edit = app.buttons["instructor.editProfile"]
        XCTAssertTrue(edit.waitForExistence(timeout: timeout))
        _ = waitUntil({ edit.isHittable })
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit Profile"].waitForExistence(timeout: 15))

        let bio = app.textViews["editProfile.bio"]
        XCTAssertTrue(bio.waitForExistence(timeout: timeout))
        bio.tap()
        bio.typeText("Book me directly at coach@example.com")

        app.buttons["editProfile.save"].tap()
        XCTAssertTrue(waitForAnyText(["Check your profile"], timeout: 15),
                      "Contact details should be kept out of a public listing")
    }

    /// The filter must not get in the way of an ordinary bio.
    func testOrdinaryBioSavesFine() {
        launch(as: .instructor)
        selectTab("Profile")
        XCTAssertTrue(waitForAnyText(["Overview"], timeout: timeout))
        let edit = app.buttons["instructor.editProfile"]
        XCTAssertTrue(edit.waitForExistence(timeout: timeout))
        _ = waitUntil({ edit.isHittable })
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit Profile"].waitForExistence(timeout: 15))

        let bio = app.textViews["editProfile.bio"]
        XCTAssertTrue(bio.waitForExistence(timeout: timeout))
        bio.tap()
        bio.typeText("Reformer and mat classes for all levels, with a focus on rehab.")

        app.buttons["editProfile.save"].tap()
        XCTAssertTrue(waitForAnyText(["Overview"], timeout: 15),
                      "A normal bio should save without tripping the filter")
    }
}
