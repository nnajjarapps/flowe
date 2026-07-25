import XCTest

/// The student-facing instructor profile: the rich, trust-first screen a student now lands on when
/// they tap an instructor, replacing the old jump straight into the booking sheet.
///
/// Everything asserted here is derived from real data or honest fallbacks — a seeded catalog
/// instructor has no earned reviews (reviews are keyed to the signed-in instructor's workspace, not
/// to the catalog listings), so the profile must read "New" and "No reviews yet", never a fabricated
/// 0.0. These run offline like the rest of the suite; `syncReviews(forInstructor:)` is a no-op in
/// preview/test mode, so the empty state is exactly what the accessors return.
final class InstructorProfileUITests: FloweUITestCase {

    /// Discover → first instructor card → the profile sheet. The featured (boosted) listing is the
    /// first `discover.instructorCard` in the hierarchy, and it is fully populated (bio, cert,
    /// specialties, city, availability), so the section assertions below have something to find.
    @discardableResult
    private func openProfileFromDiscover(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        launch(as: .student, seeded: true)
        guard waitForAnyText(["GOOD MORNING"]) else {
            XCTFail("Discover never loaded", file: file, line: line); return false
        }
        let card = app.buttons["discover.instructorCard"].firstMatch
        guard card.waitForExistence(timeout: timeout) else {
            XCTFail("No instructor card in the feed", file: file, line: line); return false
        }
        _ = waitUntil({ card.isHittable })
        card.tap()
        return true
    }

    // MARK: - Opening the profile

    /// The card must land on the profile, not the booking sheet — the profile owns the Book CTA and
    /// the moderation menu, and the day picker must not be showing yet.
    func testDiscoverCardOpensTheProfileNotTheBookingSheet() {
        guard openProfileFromDiscover() else { return }

        XCTAssertTrue(app.buttons["instructor.book"].waitForExistence(timeout: 15),
                      "Tapping an instructor should open the profile with its Book CTA")
        XCTAssertTrue(app.buttons["instructor.moderation"].exists,
                      "The profile carries the report/block menu")
        XCTAssertFalse(app.otherElements["booking.dayStep"].exists,
                       "The profile must not drop the student straight onto the day picker")
    }

    // MARK: - Sections render with seeded data

    /// A populated listing surfaces the honest sections the app was sitting on: about, specialties,
    /// teaching area, certification (with its unverified disclaimer) and payment.
    func testProfileRendersHonestSectionsForAPopulatedListing() {
        guard openProfileFromDiscover() else { return }
        XCTAssertTrue(app.buttons["instructor.book"].waitForExistence(timeout: 15), "Profile never opened")

        for header in ["ABOUT", "SPECIALTIES", "TEACHING AREA", "CERTIFICATION", "PAYMENT"] {
            XCTAssertTrue(scrollToText([header]), "Section '\(header)' should render for a full listing")
        }
        XCTAssertTrue(scrollToText(["Flowe doesn't verify certifications."]),
                      "A self-declared certification must be labelled unverified")
    }

    /// Booking is arranged offline, so the profile says so plainly rather than implying Flowe holds
    /// the money.
    func testProfileStatesPaymentIsDirectToInstructor() {
        guard openProfileFromDiscover() else { return }
        XCTAssertTrue(app.buttons["instructor.book"].waitForExistence(timeout: 15), "Profile never opened")
        XCTAssertTrue(scrollToTextContaining("pay"),
                      "The action rail should tell the student they pay the instructor directly")
    }

    // MARK: - Reviews & empty states

    /// A catalog instructor has no earned reviews, so the reviews section must show its empty state
    /// and the rating must read "New" — never a fabricated 0.0.
    func testUnreviewedInstructorShowsNewAndTheReviewsEmptyState() {
        guard openProfileFromDiscover() else { return }
        XCTAssertTrue(app.buttons["instructor.book"].waitForExistence(timeout: 15), "Profile never opened")

        XCTAssertNotNil(anyStaticText(["New"]),
                        "An unreviewed instructor's rating should read 'New', not a score")
        XCTAssertTrue(scrollToText(["No reviews yet"]),
                      "The reviews section should show its empty state, not fabricated reviews")
        XCTAssertNil(anyStaticText(["0.0"]),
                     "No 0.0 rating may ever be shown for an instructor with no reviews")
        XCTAssertTrue(app.descendants(matching: .any)["instructor.reviews"].exists
                      || app.staticTexts["No reviews yet"].exists,
                      "The reviews section container should be present")
    }

    // MARK: - Handoff into booking

    /// The Book CTA hands into the existing booking flow at the day picker (startStep: 1), so the
    /// intro step is skipped and the student picks a day next.
    func testBookCTAEntersTheBookingFlowAtTheDayPicker() {
        guard openProfileFromDiscover() else { return }
        let book = app.buttons["instructor.book"]
        XCTAssertTrue(book.waitForExistence(timeout: 15), "Profile never opened")
        _ = waitUntil({ book.isHittable })
        book.tap()

        XCTAssertTrue(waitForAnyText(["Choose a day"], timeout: 15),
                      "Booking should open on the day picker, not the orphaned intro")
        XCTAssertTrue(app.descendants(matching: .any)["booking.dayStep"].waitForExistence(timeout: 10),
                      "The handoff should land on the day step (startStep: 1)")
    }

    // MARK: - A second entry point: Book again

    /// "Book again" on a past booking opens the same profile, not the booking sheet directly.
    func testBookAgainOpensTheProfile() {
        launch(as: .student, seeded: true)
        selectTab("Bookings")
        XCTAssertTrue(waitForAnyText(["Past"], timeout: timeout), "Bookings never loaded")
        let past = app.buttons["Past"].firstMatch
        if past.waitForExistence(timeout: timeout) {
            _ = waitUntil({ past.isHittable }); past.tap()
        }
        guard scrollToText(["Book again"]) else {
            return XCTFail("No completed booking offered 'Book again'")
        }
        // Tap the button by id, not its text: a Button's Text label only forwards a tap by
        // hit-testing luck (see FloweUITestCase), which is why the text tap didn't open the sheet.
        let bookAgain = app.buttons["booking.bookAgain"].firstMatch
        XCTAssertTrue(bookAgain.waitForExistence(timeout: timeout), "'Book again' button missing")
        _ = waitUntil({ bookAgain.isHittable })
        bookAgain.tap()
        XCTAssertTrue(app.buttons["instructor.book"].waitForExistence(timeout: 15),
                      "'Book again' should open the instructor profile, not the booking sheet")
    }

    // MARK: - Helper

    private func scrollToTextContaining(_ needle: String, swipes: Int = 8) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", needle)
        if app.staticTexts.matching(predicate).firstMatch.exists { return true }
        for _ in 0..<swipes {
            app.swipeUp()
            if app.staticTexts.matching(predicate).firstMatch.exists { return true }
        }
        return false
    }
}
