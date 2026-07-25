import XCTest

/// Rich, instructor-authored lesson types — the replacement for the old fixed
/// `["Private","Duet","Group","Online"]` chip menu. Each type is now a free-form object with a name
/// the instructor types, an optional photo, details, a duration, a price and a max group size.
///
/// The UI-test harness resets and re-seeds the store on every launch and runs offline (no CloudKit),
/// so there is no shared backend to carry a type an *instructor* authored across to a separate
/// *student* launch. The two halves are therefore exercised against seeded data: the authoring and
/// rich-detail side as the signed-in instructor (whose seeded workspace already contains rich types),
/// and the student-facing OFFERS card and booking picker as a student viewing a seeded listing. The
/// migration path — a plain legacy string type still rendering — is covered because the seeded discover
/// instructors keep name-only `sessionTypes`, which the resolver renders as name-only cards.
@MainActor
final class LessonTypesUITests: FloweUITestCase {

    /// The three rich lesson types `SeedLoader` authors for the signed-in instructor. Varied on
    /// purpose: a photo-bearing 1-on-1, a duet, and a larger group.
    private let seededTypeNames = ["Private Reformer", "Duet", "Group Mat"]

    // MARK: - Helpers

    /// Instructor profile → Edit Profile sheet, matching InstructorProfileEditingUITests.
    private func openEditor(seeded: Bool, file: StaticString = #filePath, line: UInt = #line) {
        launch(as: .instructor, seeded: seeded)
        selectTab("Profile")
        XCTAssertTrue(waitForAnyText(["Overview"], timeout: timeout),
                      "Profile never loaded", file: file, line: line)

        let edit = app.buttons["instructor.editProfile"]
        XCTAssertTrue(edit.waitForExistence(timeout: timeout),
                      "Edit Profile button missing", file: file, line: line)
        _ = waitUntil({ edit.isHittable })
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit Profile"].waitForExistence(timeout: 15),
                      "Edit Profile sheet did not open", file: file, line: line)
    }

    /// Open the first seeded instructor's rich profile from the discover feed.
    private func openFirstInstructorProfile(file: StaticString = #filePath, line: UInt = #line) {
        launch(as: .student, seeded: true)
        XCTAssertTrue(waitForAnyText(["GOOD MORNING"], timeout: timeout),
                      "Discover never loaded", file: file, line: line)
        let card = app.buttons["discover.instructorCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: timeout),
                      "No instructor card in the feed", file: file, line: line)
        _ = waitUntil({ card.isHittable })
        card.tap()
        XCTAssertTrue(app.buttons["instructor.book"].waitForExistence(timeout: 15),
                      "Instructor profile never opened", file: file, line: line)
    }

    // MARK: - Instructor authoring & rich detail

    /// The editor lists the instructor's authored lesson types (not a fixed menu), each with its rich
    /// meta — this is where "capacity/details render" is proven, since the seeded types carry them.
    func testEditorListsSeededRichLessonTypes() {
        openEditor(seeded: true)
        XCTAssertTrue(scrollToText(["LESSON TYPES"]),
                      "The editor must offer a LESSON TYPES section")
        for name in seededTypeNames {
            XCTAssertTrue(scrollToText([name]),
                          "The instructor's authored type '\(name)' should be listed")
        }
        // The rich meta line: the capacity-1 private reads "1-on-1". The meta is one combined Text
        // ("1-on-1 · 55 min · $70") — deliberately joined into a single run so it lays out under RTL —
        // so match its label by substring, not the exact-equality `scrollToText` uses.
        let oneOnOne = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "1-on-1")).firstMatch
        XCTAssertTrue(oneOnOne.waitForExistence(timeout: timeout),
                      "A capacity-1 lesson type should render as 1-on-1 in its meta line")
    }

    /// A fresh instructor has authored nothing — an honest empty state that prompts the first one,
    /// never a backfilled default like the old "Private".
    func testFreshInstructorSeesEmptyLessonTypeState() {
        openEditor(seeded: false)
        XCTAssertTrue(scrollToText(["LESSON TYPES"]), "LESSON TYPES section missing")
        XCTAssertTrue(app.buttons["editProfile.addLessonType"].waitForExistence(timeout: timeout),
                      "A fresh instructor must be able to add their first lesson type")
        XCTAssertTrue(waitForAnyText(["Add your first lesson type — a class you offer, in your own words."]),
                      "Zero lesson types should show the empty-state prompt, not a default")
        // No fabricated default type appears.
        XCTAssertNil(anyStaticText(["Private", "Duet", "Group", "Online"]),
                     "A new instructor must not be given any pre-authored lesson type")
    }

    /// An instructor creates a rich lesson type from scratch — types its name, states a group size —
    /// and it lands in their list. The core "instructor authors a rich type" flow.
    func testInstructorCanCreateARichLessonType() {
        openEditor(seeded: false)
        let add = app.buttons["editProfile.addLessonType"]
        XCTAssertTrue(add.waitForExistence(timeout: timeout), "Add lesson type button missing")
        _ = waitUntil({ add.isHittable })
        add.tap()

        XCTAssertTrue(app.navigationBars["Add lesson type"].waitForExistence(timeout: 15),
                      "The compose sheet did not open")

        let name = app.textFields["lessonType.name"]
        XCTAssertTrue(name.waitForExistence(timeout: timeout), "Name field missing")
        name.tap()
        name.typeText("Sunrise Reformer")

        // State a group size via the stepper's increment, so the type carries a real capacity.
        let stepper = app.steppers["lessonType.capacity"]
        if stepper.waitForExistence(timeout: 5) {
            stepper.buttons.element(boundBy: 1).tap()   // the increment (+) side
        }

        let create = app.buttons["lessonType.create"]
        XCTAssertTrue(waitUntil({ create.isEnabled }),
                      "Add should enable once the type has a name")
        create.tap()

        // Back on the editor, the new type is now one of the instructor's authored rows.
        XCTAssertTrue(scrollToText(["Sunrise Reformer"], swipes: 8),
                      "A created lesson type should appear in the instructor's list")
    }

    /// The compose sheet is a full rich-detail form, not a name-only field.
    func testComposeSheetOffersRichFields() {
        openEditor(seeded: false)
        let add = app.buttons["editProfile.addLessonType"]
        XCTAssertTrue(add.waitForExistence(timeout: timeout))
        _ = waitUntil({ add.isHittable })
        add.tap()
        XCTAssertTrue(app.navigationBars["Add lesson type"].waitForExistence(timeout: 15))

        XCTAssertTrue(app.textFields["lessonType.name"].waitForExistence(timeout: timeout),
                      "A lesson type needs a free-form name field")
        XCTAssertTrue(app.textFields["lessonType.details"].exists,
                      "A lesson type needs a details field")
        XCTAssertTrue(app.steppers["lessonType.capacity"].exists,
                      "A lesson type needs a group-size control")
        // The group-size footer states, honestly, that capacity is not a live availability gauge.
        XCTAssertTrue(scrollToText(["The maximum group size for this lesson. Flowe doesn't track live availability — students send you a 1:1 request."]),
                      "The group-size field must say capacity is descriptive, not a spots-left count")
        // The highlight photo is the last section: swipe until its button enters the hierarchy, then
        // assert by id. (A Form row below the fold isn't queryable, and its section header renders
        // uppercased so matching on header text is unreliable.)
        let photoPicker = app.buttons["lessonType.photoPicker"]
        var swipes = 0
        while !photoPicker.exists && swipes < 8 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(photoPicker.exists, "A lesson type needs an optional highlight photo")
    }

    // MARK: - Student-facing OFFERS

    /// A student viewing a seeded instructor sees the OFFERS section rendered as lesson-type cards.
    /// The seeded discover instructors keep name-only `sessionTypes`, so this also proves the
    /// migration path: a plain legacy string type still renders (as a name-only card).
    func testStudentProfileShowsLessonTypeOfferCards() {
        openFirstInstructorProfile()
        XCTAssertTrue(scrollToText(["OFFERS"]),
                      "A student profile with offers should show an OFFERS section")
        XCTAssertTrue(app.otherElements["lessonType.card.0"].waitForExistence(timeout: timeout)
                        || app.staticTexts["lessonType.card.0"].exists,
                      "The first offer should render as a lesson-type card")
    }

    /// The migration path, explicitly: the first seeded instructor's legacy string types
    /// (e.g. "Private") still render by name on the student profile — nothing is orphaned.
    func testLegacyStringTypeStillRenders() {
        openFirstInstructorProfile()
        XCTAssertTrue(scrollToText(["OFFERS"]), "OFFERS section missing")
        // The boosted seed instructor offers "Private" among its legacy session types.
        XCTAssertTrue(scrollToText(["Private"]),
                      "A migrated legacy string type should still render by name")
    }

    // MARK: - Booking picker

    /// The booking type picker is driven by the lesson-type resolver: reaching the Time & type step
    /// surfaces the instructor's types as selectable cells with stable ids.
    func testBookingPickerShowsLessonTypes() {
        openFirstInstructorProfile()
        let book = app.buttons["instructor.book"]
        XCTAssertTrue(book.waitForExistence(timeout: 15))
        _ = waitUntil({ book.isHittable })
        book.tap()

        // Step 1 — pick the first bookable day, then continue.
        XCTAssertTrue(waitForAnyText(["Choose a day"], timeout: 15), "Day step never appeared")
        let continueButton = app.buttons["Continue"]
        for day in FloweUITestCase.weekdayPrefixes {
            let pill = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", day)).firstMatch
            guard pill.exists, pill.isEnabled, pill.isHittable else { continue }
            pill.tap()
            if waitUntil({ continueButton.isEnabled }, timeout: 2) { break }
        }
        XCTAssertTrue(waitUntil({ continueButton.isEnabled }), "No bookable day could be selected")
        continueButton.tap()

        // Step 2 — the SESSION TYPE row now offers the resolver's lesson types as tappable cells.
        XCTAssertTrue(waitForAnyText(["Time & type"], timeout: 15), "Time step never appeared")
        XCTAssertTrue(app.buttons["booking.type.0"].waitForExistence(timeout: timeout),
                      "The booking picker should offer at least one lesson type to choose")
    }
}
