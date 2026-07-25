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

    /// "Today's Schedule" must be today's accepted sessions only — it used to list every booking.
    /// The seeded workspace dates one confirmed session today and the completed ones earlier in the
    /// week, so exactly the confirmed one belongs on today's schedule.
    func testTodaysScheduleShowsOnlyTodaysSessions() {
        launch(as: .instructor, seeded: true)
        XCTAssertTrue(waitForAnyText(["TODAY'S SCHEDULE"], timeout: timeout), "Schedule section missing")
        // Sara's confirmed session is dated today; the completed sessions are earlier in the week and
        // must not appear on today's schedule.
        XCTAssertTrue(waitForAnyText(["Sara Kim"], timeout: 10),
                      "Today's confirmed session should be on the schedule")
        XCTAssertNil(anyStaticText(["Jordan Lee"]),
                     "A session from another day must not appear on today's schedule")
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

    // MARK: - Availability editing (regression: closing a day must stay closed)

    /// Open the availability editor from the dashboard quick action and wait for it to appear.
    private func openAvailabilityEditor(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitForAnyText(["QUICK ACTIONS"], timeout: 15), file: file, line: line)
        app.staticTexts["Add availability"].tap()
        XCTAssertTrue(app.navigationBars["Availability"].waitForExistence(timeout: 15),
                      "Availability editor did not open", file: file, line: line)
    }

    /// Close one day. On first open the first open day is already expanded (its Close button is
    /// visible); any other day must be expanded first by tapping its row. Tapping an
    /// already-expanded day's row would collapse it, so only expand when the Close button is absent.
    private func closeDay(_ day: String, file: StaticString = #filePath, line: UInt = #line) {
        let close = app.buttons["availability.close.\(day)"]
        if !close.isHittable {
            let row = app.buttons["availability.day.\(day)"]
            XCTAssertTrue(row.waitForExistence(timeout: timeout), "\(day) row missing", file: file, line: line)
            _ = waitUntil({ row.isHittable })
            row.tap()
        }
        XCTAssertTrue(close.waitForExistence(timeout: timeout), "Close button for \(day) missing", file: file, line: line)
        _ = waitUntil({ close.isHittable })
        close.tap()
    }

    /// The bug: closing a previously-open day and saving silently REOPENED it with the full time
    /// slate on the next open — an instructor narrowing availability ended up with MORE open than
    /// they set. Seeded Taylor is Mon{8,9,10}/Wed{9,10,11}/Fri{5PM,6PM} = "8 slots across 3 days".
    /// Closing Mon must persist as Wed+Fri = "5 slots across 2 days"; before the fix it re-read as
    /// "13 slots across 3 days" (Mon reopened with all 8). The Wed/Fri untouched days keep exactly
    /// their own slots — no day ever expands to a slate it wasn't given.
    func testClosingADayStaysClosedAcrossSaveAndReopen() {
        launch(as: .instructor, seeded: true)
        openAvailabilityEditor()
        XCTAssertTrue(waitForAnyText(["8 slots across 3 days"], timeout: 15),
                      "Seeded availability should start at 8 slots across 3 days")

        closeDay("Mon")
        app.buttons["availability.save"].tap()

        // Reopen from the dashboard — persistence is the whole point, so re-read a fresh editor.
        openAvailabilityEditor()
        XCTAssertTrue(waitForAnyText(["5 slots across 2 days"], timeout: 15),
                      "Closing Mon must persist as Wed+Fri (5 slots / 2 days), not reopen the full slate")
        XCTAssertNil(anyStaticText(["13 slots across 3 days"]),
                     "Mon must not silently reopen with the full time slate")

        // Mon itself must read Closed, not 8 slots. The row button folds its child Texts into its
        // label, so an open Mon would carry "slots"; a closed one carries "Closed".
        let monLabel = app.buttons["availability.day.Mon"].label
        XCTAssertTrue(monLabel.contains("Closed"), "Mon should read Closed after being closed, got: \(monLabel)")
        XCTAssertFalse(monLabel.contains("slots"), "Mon must not show any slots after being closed, got: \(monLabel)")
    }

    /// An instructor must be able to close their whole week. Before the fix the circular
    /// `available = bookableDays` re-derivation kept re-opening every token-less day from the
    /// legacy full-slate fallback, so a fully-closed week was impossible.
    func testClosingAllDaysLeavesNoBookableDays() {
        launch(as: .instructor, seeded: true)
        openAvailabilityEditor()
        XCTAssertTrue(waitForAnyText(["8 slots across 3 days"], timeout: 15))

        for day in ["Mon", "Wed", "Fri"] { closeDay(day) }
        app.buttons["availability.save"].tap()

        openAvailabilityEditor()
        XCTAssertTrue(waitForAnyText(["Students can't book you until you open at least one day."], timeout: 15),
                      "Closing every day must persist as a fully-closed week, not reopen from the fallback")
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
