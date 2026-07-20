import XCTest

/// Messaging, which is shared by both roles. A conversation's counterpart is an instructor for a
/// student and a student for an instructor, so the inbox is driven by messages, not by listings.
final class MessagingUITests: FloweUITestCase {

    // MARK: - Access

    func testStudentHasAMessagesTab() {
        launch(as: .student)
        XCTAssertTrue(app.tabBars.buttons["Messages"].waitForExistence(timeout: timeout),
                      "Students need a Messages tab — messaging has two sides")
    }

    func testInstructorHasAMessagesTab() {
        launch(as: .instructor)
        XCTAssertTrue(app.tabBars.buttons["Messages"].waitForExistence(timeout: timeout),
                      "Instructor Messages tab missing")
    }

    // MARK: - Inbox

    func testStudentInboxEmptyState() {
        launch(as: .student, seeded: false)
        selectTab("Messages")
        XCTAssertTrue(waitForAnyText(["No messages yet"], timeout: 15),
                      "A new student should see the inbox empty state")
    }

    func testInstructorInboxEmptyState() {
        launch(as: .instructor, seeded: false)
        selectTab("Messages")
        XCTAssertTrue(waitForAnyText(["No messages yet"], timeout: 15),
                      "A new instructor should see the inbox empty state")
    }

    func testInboxSearchFieldExists() {
        launch(as: .student, seeded: true)
        selectTab("Messages")
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: timeout),
                      "Inbox search field missing")
    }

    // MARK: - Compose

    /// A student's address book is the instructors they can reach.
    func testStudentComposeListsInstructors() {
        launch(as: .student, seeded: true)
        selectTab("Messages")
        openCompose()
        XCTAssertTrue(waitForAnyText(["New Message"], timeout: 15), "Compose sheet did not open")
        XCTAssertNil(anyStaticText(["No one to message yet"]),
                     "A student with visible instructors should have someone to message")
    }

    /// An instructor with no bookings has nobody to write to, and should be told why.
    func testInstructorComposeEmptyStateExplainsWhy() {
        launch(as: .instructor, seeded: false)
        selectTab("Messages")
        openCompose()
        XCTAssertTrue(waitForAnyText(["New Message"], timeout: 15), "Compose sheet did not open")
        XCTAssertTrue(scrollToText(["Students who book a session with you will appear here."]),
                      "The compose empty state should explain who can be messaged")
    }

    // MARK: - Sending

    /// The whole point: a sent message persists into the thread rather than vanishing.
    func testStudentCanSendAMessageAndItPersists() {
        launch(as: .student, seeded: true)
        selectTab("Messages")
        openCompose()
        XCTAssertTrue(waitForAnyText(["New Message"], timeout: 15))

        // Open the first person in the address book.
        let firstPerson = app.buttons.element(boundBy: 0)
        guard openFirstConversation() else {
            return XCTFail("No one available to start a conversation with")
        }

        let field = app.textFields["conversation.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "Composer field missing")
        field.tap()
        field.typeText("Hello from the test suite")

        let send = app.buttons["conversation.send"]
        XCTAssertTrue(send.isEnabled, "Send should enable once there is text")
        send.tap()

        XCTAssertTrue(waitForAnyText(["Hello from the test suite"], timeout: 15),
                      "A sent message must appear in the thread")
        _ = firstPerson
    }

    /// Leaving the thread and coming back must not lose the message (it was `@State` before).
    func testSentMessageSurvivesLeavingTheThread() {
        launch(as: .student, seeded: true)
        selectTab("Messages")
        openCompose()
        XCTAssertTrue(waitForAnyText(["New Message"], timeout: 15))
        guard openFirstConversation() else {
            return XCTFail("No one available to start a conversation with")
        }

        let field = app.textFields["conversation.field"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout))
        field.tap()
        field.typeText("Persisted message")
        app.buttons["conversation.send"].tap()
        XCTAssertTrue(waitForAnyText(["Persisted message"], timeout: 15))

        // Pop back to the recipient list (the sheet's Cancel is replaced by a back button while a
        // conversation is pushed), then dismiss the sheet and check the inbox.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: timeout), "Compose sheet Cancel missing")
        cancel.tap()

        XCTAssertTrue(waitForAnyText(["Persisted message"], timeout: 15),
                      "The conversation should now appear in the inbox with its last message")
    }

    func testSendButtonDisabledWithEmptyDraft() {
        launch(as: .student, seeded: true)
        selectTab("Messages")
        openCompose()
        XCTAssertTrue(waitForAnyText(["New Message"], timeout: 15))
        guard openFirstConversation() else {
            return XCTFail("No one available to start a conversation with")
        }
        XCTAssertTrue(app.buttons["conversation.send"].waitForExistence(timeout: timeout))
        XCTAssertFalse(app.buttons["conversation.send"].isEnabled,
                       "Send must stay disabled until something is typed")
    }

    // MARK: - Helpers

    private func openCompose() {
        // Wait for the inbox itself first — the tab switch and the header render separately.
        XCTAssertTrue(waitForAnyText(["Messages"], timeout: timeout), "Messages screen did not load")
        let compose = app.buttons["messages.compose"]
        XCTAssertTrue(compose.waitForExistence(timeout: timeout), "Compose button missing")
        compose.tap()
    }

    /// Tap the first person row in the compose sheet. Rows are the only chevron'd buttons there.
    private func openFirstConversation() -> Bool {
        // "Say hello to …" is the thread's empty hint — the marker that we're in a conversation.
        for index in 0..<app.buttons.count {
            let candidate = app.buttons.element(boundBy: index)
            guard candidate.exists, candidate.isHittable,
                  candidate.label != "Cancel", !candidate.label.isEmpty else { continue }
            candidate.tap()
            if app.textFields["conversation.field"].waitForExistence(timeout: 5) { return true }
        }
        return false
    }
}
