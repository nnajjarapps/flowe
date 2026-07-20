import XCTest

/// Shared harness for Flowe UI tests.
///
/// App state is driven purely by launch arguments — passing `-key value` populates the
/// `NSArgumentDomain`, so `UserDefaults.standard` reads them without any test-only app code.
class FloweUITestCase: XCTestCase {

    var app: XCUIApplication!

    /// Generous timeout — the app initialises SwiftData + CloudKit on launch.
    let timeout: TimeInterval = 30

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Launch helpers

    enum Role: String { case student, instructor }

    /// Weekday prefixes as they appear on the booking sheet's day pills.
    static let weekdayPrefixes = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// Launch signed-out (onboarding).
    func launchSignedOut() {
        app.launchArguments = defaults(loggedIn: false, role: nil, seeded: false)
        app.launch()
    }

    /// Launch straight into a role's tab shell.
    /// - Parameter seeded: when true, the store is populated with sample data (visible/boosted
    ///   instructors, posts, bookings) so populated states can be asserted.
    func launch(as role: Role, seeded: Bool = false) {
        app.launchArguments = defaults(loggedIn: true, role: role, seeded: seeded)
        app.launch()
        // The first launch of a run pays for app install plus SwiftData/CloudKit setup, which can
        // take far longer than a warm one. Absorb that here so each test's own waits start from a
        // loaded shell rather than racing the cold start.
        _ = app.tabBars.firstMatch.waitForExistence(timeout: 90)
    }

    private func defaults(loggedIn: Bool, role: Role?, seeded: Bool) -> [String] {
        var args: [String] = []
        args += ["-flowe.isLoggedIn", loggedIn ? "YES" : "NO"]
        if let role { args += ["-flowe.userRole", role.rawValue] }
        // Always wipe the persistent store first so tests are isolated from each other,
        // then optionally seed. Reset also puts the store offline (no public-catalog calls).
        args += ["-flowe.uiTestReset", "YES"]
        args += ["-flowe.uiTestSeed", seeded ? "YES" : "NO"]
        // Deterministic locale/currency regardless of the host machine.
        args += ["-flowe.language", "en", "-flowe.currency", "usd"]
        return args
    }

    // MARK: - Assertions

    @discardableResult
    func assertExists(_ element: XCUIElement, _ message: String,
                      file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let found = element.waitForExistence(timeout: timeout)
        XCTAssertTrue(found, message, file: file, line: line)
        return found
    }

    /// Tap a tab bar button by its visible label.
    func selectTab(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: timeout),
                      "Tab '\(name)' not found", file: file, line: line)
        tab.tap()
    }

    /// First element carrying any of the given labels (handy for either/or states).
    ///
    /// Deliberately looks beyond static texts: SwiftUI folds a `Button`'s `Text` label into the
    /// button element (segmented tabs, role cards, list rows), renders `Link` as a button/link,
    /// and surfaces an inline `navigationTitle` on the navigation bar.
    func anyStaticText(_ candidates: [String]) -> XCUIElement? {
        for text in candidates {
            for query in [app.staticTexts, app.buttons, app.links, app.navigationBars] {
                let element = query[text]
                if element.exists { return element }
            }
        }
        return nil
    }

    /// Find a label, scrolling down if needed. `Form`/`List` rows are rendered lazily, so a row
    /// below the fold genuinely does not exist in the hierarchy until it is scrolled into view.
    @discardableResult
    func scrollToText(_ candidates: [String], swipes: Int = 6) -> Bool {
        if anyStaticText(candidates) != nil { return true }
        for _ in 0..<swipes {
            app.swipeUp()
            if anyStaticText(candidates) != nil { return true }
        }
        return false
    }

    /// Tap the first element carrying one of these labels, failing the test if none is present.
    /// Prefer an accessibility identifier where one exists — a label inside a `Button` only
    /// forwards its tap by hit-testing luck.
    func tapText(_ candidates: [String], file: StaticString = #filePath, line: UInt = #line) {
        guard let element = anyStaticText(candidates) else {
            return XCTFail("None of \(candidates) found to tap", file: file, line: line)
        }
        _ = waitUntil({ element.isHittable })
        element.tap()
    }

    /// Poll a condition until it holds. SwiftUI applies state changes a frame or two after a tap,
    /// so reading `isEnabled` immediately after tapping is a race.
    @discardableResult
    func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    /// Wait until at least one of the texts appears.
    @discardableResult
    func waitForAnyText(_ candidates: [String], timeout: TimeInterval? = nil) -> Bool {
        let deadline = Date().addingTimeInterval(timeout ?? self.timeout)
        while Date() < deadline {
            if anyStaticText(candidates) != nil { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return anyStaticText(candidates) != nil
    }
}
