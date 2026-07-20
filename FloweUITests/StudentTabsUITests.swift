import XCTest

/// Student experience: all four tabs, their key controls, and both empty + populated states.
final class StudentTabsUITests: FloweUITestCase {

    // MARK: - Shell

    func testAllFourTabsExist() {
        launch(as: .student)
        for tab in ["Discover", "Community", "Bookings", "Profile"] {
            XCTAssertTrue(app.tabBars.buttons[tab].waitForExistence(timeout: timeout),
                          "Student tab '\(tab)' missing")
        }
    }

    func testTabsAreNavigable() {
        launch(as: .student)
        for tab in ["Community", "Bookings", "Profile", "Discover"] {
            selectTab(tab)
            XCTAssertTrue(app.tabBars.buttons[tab].isSelected, "Tab '\(tab)' did not become selected")
        }
    }

    // MARK: - Discover

    func testDiscoverHeaderAndSearchExist() {
        launch(as: .student)
        XCTAssertTrue(waitForAnyText(["GOOD MORNING"]), "Discover greeting missing")
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: timeout),
                      "Discover search field missing")
    }

    func testDiscoverCategoryChipsExist() {
        launch(as: .student)
        XCTAssertTrue(waitForAnyText(["GOOD MORNING"]))
        for chip in ["All", "Mat", "Reformer"] {
            XCTAssertTrue(app.buttons[chip].exists, "Category chip '\(chip)' missing")
        }
    }

    func testDiscoverEmptyStateWhenNoInstructors() {
        launch(as: .student, seeded: false)
        XCTAssertTrue(waitForAnyText(["No instructors yet"]),
                      "Discover should show its empty state with no visible instructors")
    }

    func testDiscoverListsVisibleInstructorsWhenSeeded() {
        launch(as: .student, seeded: true)
        XCTAssertTrue(waitForAnyText(["FEATURED", "NEAR YOU · 5 INSTRUCTORS"]),
                      "Seeded visible instructors should populate Discover")
    }

    func testDiscoverSearchFiltersResults() {
        launch(as: .student, seeded: true)
        XCTAssertTrue(waitForAnyText(["GOOD MORNING"]))
        let search = app.textFields.firstMatch
        search.tap()
        search.typeText("zzzznomatch")
        XCTAssertTrue(waitForAnyText(["No instructors yet"], timeout: 10),
                      "A non-matching search should fall through to the empty state")
    }

    func testDiscoverCategoryFilterChangesListHeader() {
        launch(as: .student, seeded: true)
        XCTAssertTrue(waitForAnyText(["GOOD MORNING"]))
        app.buttons["Reformer"].tap()
        XCTAssertTrue(waitForAnyText(["REFORMER · 1 INSTRUCTORS", "REFORMER · 2 INSTRUCTORS",
                                      "REFORMER · 3 INSTRUCTORS", "No instructors yet"], timeout: 10),
                      "Selecting a category should re-scope the list header")
    }

    // MARK: - Community

    func testCommunityEmptyState() {
        launch(as: .student, seeded: false)
        selectTab("Community")
        XCTAssertTrue(waitForAnyText(["Nothing here yet"]),
                      "Community should show its empty state with no posts")
    }

    func testCommunityShowsFeedWhenSeeded() {
        launch(as: .student, seeded: true)
        selectTab("Community")
        XCTAssertTrue(waitForAnyText(["Community"]), "Community header missing")
        XCTAssertTrue(app.staticTexts["Nothing here yet"].exists == false,
                      "Seeded posts should render instead of the empty state")
    }

    // MARK: - Bookings

    func testBookingsStatsAndSegmentedControl() {
        launch(as: .student, seeded: true)
        selectTab("Bookings")
        XCTAssertTrue(waitForAnyText(["Upcoming"]), "Bookings stats/segment missing")
        XCTAssertTrue(app.staticTexts["Completed"].exists, "Completed stat tile missing")
        XCTAssertTrue(app.staticTexts["Hours"].exists, "Hours stat tile missing")
    }

    func testBookingsPastSegmentSwitches() {
        launch(as: .student, seeded: true)
        selectTab("Bookings")
        XCTAssertTrue(waitForAnyText(["Upcoming"]))
        let past = app.buttons["Past"]
        if past.waitForExistence(timeout: timeout) {
            past.tap()
            XCTAssertTrue(waitForAnyText(["Done", "Cancelled", "No past sessions"], timeout: 10),
                          "Past segment should show past bookings or its empty state")
        }
    }

    func testBookingsEmptyState() {
        launch(as: .student, seeded: false)
        selectTab("Bookings")
        XCTAssertTrue(waitForAnyText(["No sessions yet"]),
                      "Bookings should show its empty state for a new user")
    }

    // MARK: - Profile

    func testProfileShowsAccountRows() {
        launch(as: .student)
        selectTab("Profile")
        for row in ["Notifications", "Payment methods", "Privacy", "Help & Support", "Log out"] {
            XCTAssertTrue(waitForAnyText([row], timeout: 10), "Account row '\(row)' missing")
        }
    }

    func testProfileEmptyProgressState() {
        launch(as: .student, seeded: false)
        selectTab("Profile")
        XCTAssertTrue(waitForAnyText(["No sessions yet"]),
                      "Profile progress should show its empty state for a new user")
    }

    func testProfileSettingsGearOpensSettings() {
        launch(as: .student)
        selectTab("Profile")
        XCTAssertTrue(waitForAnyText(["YOUR PROGRESS", "ACCOUNT"]))
        let gear = app.buttons["student.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: timeout), "Profile settings gear missing")
        gear.tap()
        XCTAssertTrue(waitForAnyText(["Settings", "Preferences"], timeout: 10),
                      "Gear should open the Settings sheet")
    }
}
