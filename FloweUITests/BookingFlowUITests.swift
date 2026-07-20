import XCTest

/// The booking loop: a student requests a session, and the instructor side surfaces requests
/// for an accept/decline. Payment is arranged offline, so no purchase step is involved.
final class BookingFlowUITests: FloweUITestCase {

    // MARK: - Student books

    /// Walk the whole BookingSheet: instructor card → day → time → request.
    /// Returns the step that failed, or nil on success — so a failure names the step it died on.
    @discardableResult
    private func completeBookingFlow(file: StaticString = #filePath, line: UInt = #line) -> String? {
        launch(as: .student, seeded: true)
        guard waitForAnyText(["GOOD MORNING"]) else { return "Discover never loaded" }

        // Open the first instructor in the feed. Tapping the card by identifier rather than by a
        // section header, which only opened the sheet by hit-testing luck.
        let card = app.buttons["discover.instructorCard"].firstMatch
        guard card.waitForExistence(timeout: timeout) else { return "No instructor card in the feed" }
        _ = waitUntil({ card.isHittable })
        card.tap()

        let bookCTA = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Book a Session'")
        ).firstMatch
        guard bookCTA.waitForExistence(timeout: timeout) else { return "'Book a Session' CTA never appeared" }
        _ = waitUntil({ bookCTA.isHittable })
        bookCTA.tap()

        // Step 1 — pick the first bookable day, then continue. Unavailable days are disabled,
        // and which days are free varies per seeded instructor, so try each in turn.
        guard waitForAnyText(["Choose a day"], timeout: 15) else { return "Day step never appeared" }
        let continueButton = app.buttons["Continue"]
        for day in FloweUITestCase.weekdayPrefixes {
            let pill = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", day)).firstMatch
            guard pill.exists, pill.isEnabled, pill.isHittable else { continue }
            pill.tap()
            if waitUntil({ continueButton.isEnabled }, timeout: 2) { break }
        }
        guard waitUntil({ continueButton.isEnabled }) else { return "No bookable day could be selected" }
        continueButton.tap()

        // Step 2 — pick a time, then send the request.
        guard waitForAnyText(["Time & type"], timeout: 15) else { return "Time step never appeared" }
        let request = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Request'")
        ).firstMatch
        guard request.waitForExistence(timeout: timeout) else { return "Request CTA never appeared" }
        // Time slots render as buttons; tap each until the CTA enables.
        let slots = app.buttons.matching(NSPredicate(format: "label CONTAINS ':'"))
        for index in 0..<slots.count {
            let slot = slots.element(boundBy: index)
            guard slot.exists, slot.isHittable else { continue }
            slot.tap()
            if waitUntil({ request.isEnabled }, timeout: 2) { break }
        }
        guard waitUntil({ request.isEnabled }) else { return "No time slot could be selected" }
        request.tap()
        return nil
    }

    /// Run the flow and fail the test with the offending step if it doesn't complete.
    private func requireBookingFlow(file: StaticString = #filePath, line: UInt = #line) {
        if let failure = completeBookingFlow() {
            XCTFail("Booking flow stalled: \(failure)", file: file, line: line)
        }
    }

    func testStudentCanCompleteBookingFlow() {
        requireBookingFlow()
        XCTAssertTrue(waitForAnyText(["Request sent!"], timeout: 15),
                      "Confirmation should say the request was sent, not that it is confirmed")
    }

    /// A booking is a *request* until the instructor accepts — it must not read as Confirmed.
    func testNewBookingIsPendingNotConfirmed() {
        requireBookingFlow()
        XCTAssertTrue(waitForAnyText(["Request sent!"], timeout: 15))
        app.buttons["Done"].tap()

        selectTab("Bookings")
        XCTAssertTrue(waitForAnyText(["Pending", "Not sent yet"], timeout: 15),
                      "A new booking should show as Pending (or as not yet delivered) — never Confirmed")
    }

    /// Flowe takes no payment for sessions in this release, so no service fee may be shown.
    func testConfirmationShowsNoServiceFee() {
        requireBookingFlow()
        XCTAssertTrue(waitForAnyText(["Request sent!"], timeout: 15))
        XCTAssertNil(anyStaticText(["Service fee"]),
                     "No service fee may be shown — payment is arranged with the instructor")
        XCTAssertNotNil(anyStaticText(["Paid directly to your instructor"]),
                        "The receipt should say the session is paid to the instructor directly")
    }

    // MARK: - Student cancels

    func testStudentCanCancelABooking() {
        requireBookingFlow()
        XCTAssertTrue(waitForAnyText(["Request sent!"], timeout: 15))
        app.buttons["Done"].tap()

        selectTab("Bookings")
        let cancel = app.buttons["booking.cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: timeout), "Cancel action missing on a booking")
        cancel.tap()
        XCTAssertTrue(waitForAnyText(["Cancel session"], timeout: 10),
                      "Cancelling should ask for confirmation rather than acting immediately")
    }

    // MARK: - Instructor side

    func testInstructorSeesRequestsEmptyStateWithNoBookings() {
        launch(as: .instructor, seeded: false)
        selectTab("Calendar")
        XCTAssertTrue(waitForAnyText(["SCHEDULE"], timeout: 15), "Calendar did not load")
        XCTAssertTrue(scrollToText(["No booking requests"]),
                      "An instructor with no requests should see the requests empty state")
    }

    /// The dashboard only shows a REQUESTS section when something is actually pending.
    func testInstructorDashboardHidesRequestsWhenEmpty() {
        launch(as: .instructor, seeded: false)
        XCTAssertTrue(waitForAnyText(["TODAY'S SCHEDULE"], timeout: timeout))
        XCTAssertNil(anyStaticText(["REQUESTS"]),
                     "REQUESTS should stay hidden until a student actually books")
    }
}
