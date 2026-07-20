import XCTest

/// Session reviews, end to end on one device.
///
/// Reviews used to be seeded `FeedPost`s rendered on the instructor profile — decorative mock data
/// that no student could ever have written. They are now anchored to a completed booking: a student
/// reviews a session they actually took, and the instructor's rating is derived from those reviews
/// rather than from a seeded number.
///
/// These run offline like every other UI test, so `ReviewService` is never called. What is covered
/// is the earned-review rule, the write flow, persistence, and the fact that the instructor's
/// Reviews tab no longer invents content. Cross-user delivery needs two real devices.
final class ReviewsUITests: FloweUITestCase {

    // MARK: - Who can review

    /// The seed has completed sessions, which are the only reviewable ones.
    func testCompletedBookingOffersAReview() {
        launch(as: .student, seeded: true)
        selectTab("Bookings")
        XCTAssertTrue(scrollToText(["Past"]), "Bookings never loaded")
        XCTAssertTrue(scrollToReviewButton(),
                      "A completed session should be reviewable")
    }

    /// A session that hasn't happened yet can't be reviewed — that's the whole point of anchoring
    /// a review to a booking.
    func testUpcomingBookingOffersNoReview() {
        launch(as: .student, seeded: true)
        selectTab("Bookings")
        XCTAssertTrue(waitForAnyText(["Upcoming"], timeout: timeout))
        // The upcoming section offers cancellation, never a review.
        XCTAssertTrue(app.buttons["booking.cancel"].firstMatch.waitForExistence(timeout: timeout),
                      "Upcoming bookings should offer cancel")
        XCTAssertFalse(app.buttons["booking.review"].firstMatch.exists,
                       "A session that hasn't happened yet must not be reviewable")
    }

    // MARK: - Writing one

    /// Bookings → first completed session → review sheet.
    private func openReviewSheet(file: StaticString = #filePath, line: UInt = #line) {
        launch(as: .student, seeded: true)
        selectTab("Bookings")
        XCTAssertTrue(scrollToReviewButton(),
                      "No reviewable booking found", file: file, line: line)
        let review = app.buttons["booking.review"].firstMatch
        _ = waitUntil({ review.isHittable })
        review.tap()
        XCTAssertTrue(waitForAnyText(["Your review"], timeout: 15),
                      "Review sheet did not open", file: file, line: line)
    }

    func testReviewSheetOpensWithStars() {
        openReviewSheet()
        for star in 1...5 {
            XCTAssertTrue(app.buttons["review.star.\(star)"].exists, "Star \(star) missing")
        }
    }

    func testSubmitIsBlockedUntilAStarIsChosen() {
        openReviewSheet()
        XCTAssertFalse(app.buttons["review.submit"].isEnabled,
                       "A review with no rating shouldn't be postable")
        app.buttons["review.star.4"].tap()
        XCTAssertTrue(waitUntil({ app.buttons["review.submit"].isEnabled }),
                      "Choosing a rating should enable posting")
    }

    func testPostingAReviewFlipsTheBookingToEdit() {
        openReviewSheet()
        app.buttons["review.star.5"].tap()

        let field = app.textFields["review.text"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "Review text field missing")
        field.tap()
        field.typeText("Wonderful session, really clear cueing.")
        app.buttons["review.submit"].tap()

        XCTAssertTrue(app.buttons["booking.review"].firstMatch.waitForExistence(timeout: 15),
                      "Should return to Bookings after posting")
        XCTAssertTrue(waitForAnyText(["Edit review"], timeout: 15),
                      "Once reviewed, the action should offer editing rather than a fresh review")
    }

    /// Reopening must show what was written, not an empty form.
    func testReviewPersistsAndReopensPopulated() {
        openReviewSheet()
        app.buttons["review.star.4"].tap()
        let field = app.textFields["review.text"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "Review text field missing")
        field.tap()
        field.typeText("Great mat class.")
        app.buttons["review.submit"].tap()

        let edit = app.buttons["booking.review"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 15))
        _ = waitUntil({ edit.isHittable })
        edit.tap()

        XCTAssertTrue(waitForAnyText(["Edit Review"], timeout: 15),
                      "Reopening a reviewed booking should be an edit, not a new review")

        // A text field's content is its `value`, not a static label, so it can't be found by text.
        let reopened = app.textFields["review.text"]
        XCTAssertTrue(reopened.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitUntil({ (reopened.value as? String) == "Great mat class." }),
                      "The saved review text should come back, got: "
                      + String(describing: reopened.value))
    }

    /// Reviews are public content, so they get the same screening as a public listing.
    func testObjectionableReviewIsRejected() {
        openReviewSheet()
        app.buttons["review.star.1"].tap()
        let field = app.textFields["review.text"]
        XCTAssertTrue(field.waitForExistence(timeout: timeout), "Review text field missing")
        field.tap()
        field.typeText("This was shit")

        app.buttons["review.submit"].tap()
        XCTAssertTrue(waitForAnyText(["Check your review"], timeout: 15),
                      "Objectionable wording must be refused before it is published")
    }

    // MARK: - The instructor's side

    /// The regression this whole change is about: the Reviews tab used to render seeded community
    /// posts, so a brand-new instructor appeared to already have reviews.
    func testInstructorWithNoReviewsSeesAnEmptyStateNotMockData() {
        launch(as: .instructor, seeded: true)
        selectTab("Profile")
        XCTAssertTrue(waitForAnyText(["Overview"], timeout: timeout))
        tapText(["Reviews"])

        XCTAssertTrue(waitForAnyText(["No reviews yet"], timeout: 15),
                      "An instructor with no earned reviews must not show seeded ones")
        XCTAssertFalse(app.otherElements["instructor.reviewsList"].exists,
                       "No review list should render without real reviews")
    }

    /// The empty state should point the instructor at how reviews actually arrive.
    func testEmptyReviewsExplainsHowReviewsArrive() {
        launch(as: .instructor, seeded: true)
        selectTab("Profile")
        XCTAssertTrue(waitForAnyText(["Overview"], timeout: timeout))
        tapText(["Reviews"])
        XCTAssertTrue(scrollToTextContaining("students can review it from their Bookings tab"),
                      "The empty state should say where reviews come from")
    }

    /// With no reviews there is no rating, and a fabricated 0.0 would be worse than none.
    func testInstructorWithNoReviewsShowsNoRating() {
        launch(as: .instructor, seeded: true)
        selectTab("Profile")
        XCTAssertTrue(waitForAnyText(["Overview"], timeout: timeout))
        XCTAssertNil(anyStaticText(["0.0"]),
                     "An unreviewed instructor should show no rating rather than a zero")
    }

    // MARK: - Helper

    /// Completed sessions live behind the Past segment, so the list has to be switched over before
    /// any review affordance exists at all.
    @discardableResult
    private func selectPastBookings() -> Bool {
        let past = app.buttons["Past"].firstMatch
        guard past.waitForExistence(timeout: timeout) else { return false }
        _ = waitUntil({ past.isHittable })
        past.tap()
        return true
    }

    private func scrollToReviewButton(swipes: Int = 8) -> Bool {
        selectPastBookings()
        let button = app.buttons["booking.review"].firstMatch
        if button.waitForExistence(timeout: 10) { return true }
        for _ in 0..<swipes {
            app.swipeUp()
            if button.exists { return true }
        }
        return button.exists
    }

    private func scrollToTextContaining(_ needle: String, swipes: Int = 6) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", needle)
        if app.staticTexts.matching(predicate).firstMatch.exists { return true }
        for _ in 0..<swipes {
            app.swipeUp()
            if app.staticTexts.matching(predicate).firstMatch.exists { return true }
        }
        return false
    }
}
