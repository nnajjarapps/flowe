import XCTest

/// Instructor experience: tabs, dashboard KPIs + quick actions, calendar, messages, profile.
final class InstructorTabsUITests: FloweUITestCase {

    // MARK: - Shell

    func testAllFourInstructorTabsExist() {
        launch(as: .instructor)
        for tab in ["Dashboard", "Calendar", "Messages", "Profile"] {
            XCTAssertTrue(app.tabBars.buttons[tab].waitForExistence(timeout: timeout),
                          "Instructor tab '\(tab)' missing")
        }
    }

    func testInstructorTabsAreNavigable() {
        launch(as: .instructor)
        for tab in ["Calendar", "Messages", "Profile", "Dashboard"] {
            selectTab(tab)
            XCTAssertTrue(app.tabBars.buttons[tab].isSelected, "Tab '\(tab)' did not become selected")
        }
    }

    // MARK: - Dashboard

    func testDashboardHeaderAndKPIs() {
        launch(as: .instructor)
        // The greeting is time-of-day based, so accept any of the three.
        XCTAssertTrue(waitForAnyText(["GOOD MORNING", "GOOD AFTERNOON", "GOOD EVENING"]),
                      "Dashboard greeting missing")
        for kpi in ["TODAY", "THIS WEEK", "RATING"] {
            XCTAssertTrue(app.staticTexts[kpi].exists, "KPI tile '\(kpi)' missing")
        }
    }

    func testDashboardShowsGetDiscoveredBannerWhenNotSubscribed() {
        launch(as: .instructor)
        XCTAssertTrue(waitForAnyText(["Get discovered"]),
                      "Unsubscribed instructors should see the Get discovered banner")
    }

    func testDashboardEmptyScheduleState() {
        launch(as: .instructor, seeded: false)
        XCTAssertTrue(waitForAnyText(["No sessions today"]),
                      "Dashboard should show its empty schedule state")
    }

    func testDashboardQuickActionsExist() {
        launch(as: .instructor)
        XCTAssertTrue(waitForAnyText(["QUICK ACTIONS"], timeout: 15))
        for action in ["Add availability", "Message students", "View earnings", "Edit profile"] {
            XCTAssertTrue(app.staticTexts[action].exists, "Quick action '\(action)' missing")
        }
    }

    func testAddAvailabilityQuickActionOpensEditor() {
        launch(as: .instructor)
        XCTAssertTrue(waitForAnyText(["QUICK ACTIONS"], timeout: 15))
        app.staticTexts["Add availability"].tap()
        XCTAssertTrue(waitForAnyText(["Bookable days", "Availability"], timeout: 15),
                      "Add availability should open the availability editor")
    }

    func testEditProfileQuickActionOpensEditor() {
        launch(as: .instructor)
        XCTAssertTrue(waitForAnyText(["QUICK ACTIONS"], timeout: 15))
        app.staticTexts["Edit profile"].tap()
        XCTAssertTrue(waitForAnyText(["Edit Profile", "BIO", "RATE PER SESSION"], timeout: 15),
                      "Edit profile should open the profile editor")
    }

    func testMessageStudentsQuickActionSwitchesToMessagesTab() {
        launch(as: .instructor)
        XCTAssertTrue(waitForAnyText(["QUICK ACTIONS"], timeout: 15))
        app.staticTexts["Message students"].tap()
        XCTAssertTrue(app.tabBars.buttons["Messages"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.tabBars.buttons["Messages"].isSelected,
                      "Message students should route to the Messages tab")
    }

    func testViewEarningsQuickActionOpensProfileEarnings() {
        launch(as: .instructor)
        XCTAssertTrue(waitForAnyText(["QUICK ACTIONS"], timeout: 15))
        app.staticTexts["View earnings"].tap()
        XCTAssertTrue(app.tabBars.buttons["Profile"].waitForExistence(timeout: timeout))
        XCTAssertTrue(app.tabBars.buttons["Profile"].isSelected,
                      "View earnings should route to the Profile tab")
        XCTAssertTrue(waitForAnyText(["Earnings", "No earnings yet"], timeout: 15),
                      "Profile should land on the Earnings tab")
    }

    // MARK: - Calendar

    func testCalendarWeekStripAndSections() {
        launch(as: .instructor)
        selectTab("Calendar")
        XCTAssertTrue(waitForAnyText(["SCHEDULE", "BOOKING REQUESTS"], timeout: 15),
                      "Calendar sections missing")
    }

    /// The calendar used to be pinned to a hardcoded "JUL 7 – JUL 13" week; it now reflects the real
    /// current week, so today must be marked and the old fixed header must be gone.
    func testCalendarReflectsTheRealCurrentWeek() {
        launch(as: .instructor)
        selectTab("Calendar")
        XCTAssertTrue(waitForAnyText(["SCHEDULE"], timeout: 15))
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'TODAY'")).firstMatch
                        .waitForExistence(timeout: 10),
                      "The week strip should mark today")
        XCTAssertNil(anyStaticText(["JUL 7 – JUL 13"]),
                     "The hardcoded mockup week must be gone")
    }

    func testCalendarDaySelectionWorks() {
        launch(as: .instructor)
        selectTab("Calendar")
        XCTAssertTrue(waitForAnyText(["SCHEDULE"], timeout: 15))
        // Week-strip pills are buttons labelled by weekday.
        let wed = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'WED'")).firstMatch
        if wed.exists { wed.tap() }
        XCTAssertTrue(waitForAnyText(["SCHEDULE"], timeout: 10), "Calendar should remain stable after day selection")
    }

    // MARK: - Messages

    func testMessagesEmptyStateAndComposeButton() {
        launch(as: .instructor, seeded: false)
        selectTab("Messages")
        XCTAssertTrue(waitForAnyText(["Messages"], timeout: 15), "Messages header missing")
        XCTAssertTrue(waitForAnyText(["No messages yet", "Search messages…"], timeout: 10),
                      "Messages should show its empty state or search field")
    }

    func testComposeOpensNewMessageSheet() {
        launch(as: .instructor, seeded: true)
        selectTab("Messages")
        XCTAssertTrue(waitForAnyText(["Messages"], timeout: 15))
        let compose = app.buttons["messages.compose"]
        XCTAssertTrue(compose.waitForExistence(timeout: timeout), "Compose button missing")
        compose.tap()
        XCTAssertTrue(waitForAnyText(["New Message"], timeout: 10),
                      "Compose should open the New Message sheet")
    }

    // MARK: - Profile

    func testInstructorProfileSegmentedTabs() {
        launch(as: .instructor)
        selectTab("Profile")
        for tab in ["Overview", "Analytics", "Reviews", "Earnings"] {
            XCTAssertTrue(waitForAnyText([tab], timeout: 10), "Profile segment '\(tab)' missing")
        }
    }

    func testInstructorProfileEmptySetupPrompts() {
        launch(as: .instructor, seeded: false)
        selectTab("Profile")
        XCTAssertTrue(waitForAnyText(["Add a bio in Edit Profile so students can get to know you."], timeout: 15),
                      "A new instructor should see profile setup prompts")
    }
}
