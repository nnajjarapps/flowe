import XCTest

/// The Events subsystem: the Community sub-tab that surfaces it, who is offered event creation, and
/// the subscription gate in front of the composer.
///
/// Everything here runs against the offline optimistic branch (`seed || reset` forces the store
/// offline), so no test reaches CloudKit. That shapes what is assertable: an event only ever gets a
/// `remoteID` — and a registration count — from the shared store, so a genuine cross-user join or a
/// "fully booked" count cannot be manufactured in this harness. Those flows are covered by the
/// data-layer reasoning in `MockDataStore`/`EventService`; see the note on `testCreatingAnEvent…`
/// for why even the composer is unreachable without an active subscription entitlement.
@MainActor
final class EventsUITests: FloweUITestCase {

    // MARK: - Helpers

    private func openCommunity(seeded: Bool = true) {
        launch(as: .student, seeded: seeded)
        selectTab("Community")
    }

    /// Reveal a lazily-rendered element below the fold by scrolling the scroll view. A dashboard
    /// tile past the visible grid genuinely does not exist in the hierarchy until scrolled in.
    @discardableResult
    private func scrollToElement(_ element: XCUIElement, swipes: Int = 6) -> Bool {
        if element.exists { return true }
        for _ in 0..<swipes {
            app.swipeUp()
            if element.exists { return true }
        }
        return element.exists
    }

    // MARK: - The sub-tab

    /// Community is segmented: the existing feed and the new events list live behind two pills.
    func testCommunityIsSegmentedIntoFeedAndEvents() {
        openCommunity()
        XCTAssertTrue(app.buttons["community.tab.feed"].waitForExistence(timeout: timeout),
                      "Community should keep a Feed sub-tab")
        XCTAssertTrue(app.buttons["community.tab.events"].exists,
                      "Community should gain an Events sub-tab")
    }

    /// With nothing seeded (events are never fabricated into the store, exactly like posts), the
    /// Events tab shows its empty state — and, unlike the feed, offers no way to create anything: a
    /// student has nothing to host.
    func testEventsTabShowsEmptyStateWithNoCreateAffordance() {
        openCommunity()
        app.buttons["community.tab.events"].tap()

        XCTAssertTrue(waitForAnyText(["No events yet"], timeout: timeout),
                      "The Events tab should show its empty state when nothing is hosted")
        // The feed's compose "+" must not bleed into Events — it would read as a filtered feed and
        // dangle an affordance a student can't use.
        XCTAssertFalse(app.buttons["community.compose"].exists,
                       "The compose button belongs to the Feed sub-tab only")
        // EmptyStateView renders its CTA only when both actionTitle and action are non-nil; the
        // events empty state passes neither, so there is no button to find.
        XCTAssertNil(anyStaticText(["Share the first post", "Host an event"]),
                     "A student's empty events state should offer no create call-to-action")
    }

    /// Switching back to Feed brings the compose button back — proving the affordance is scoped to
    /// the sub-tab, not removed outright.
    func testComposeReturnsWhenSwitchingBackToFeed() {
        openCommunity()
        app.buttons["community.tab.events"].tap()
        XCTAssertTrue(waitForAnyText(["No events yet"], timeout: timeout))

        app.buttons["community.tab.feed"].tap()
        XCTAssertTrue(app.buttons["community.compose"].waitForExistence(timeout: timeout),
                      "The Feed sub-tab should still own its compose button")
    }

    // MARK: - Who may create an event

    /// A student is never offered event creation anywhere — they have no dashboard, and the quick
    /// action lives only on the instructor's.
    func testStudentIsNeverOfferedEventCreation() {
        launch(as: .student, seeded: true)
        XCTAssertFalse(app.buttons["dashboard.action.createEvent"].exists,
                       "A student must not see the Host-an-event action")
    }

    /// The instructor dashboard gains the "Host an event" quick action.
    func testInstructorSeesHostAnEventQuickAction() {
        launch(as: .instructor)
        let tile = app.buttons["dashboard.action.createEvent"]
        XCTAssertTrue(scrollToElement(tile),
                      "The instructor dashboard should offer a Host-an-event quick action")
    }

    // MARK: - The subscription gate

    /// Hosting an event broadcasts to students, so it is gated on the same subscription that makes an
    /// instructor discoverable: an instructor students can't even find shouldn't broadcast. An
    /// unsubscribed instructor — the only kind this harness can produce, since a StoreKit entitlement
    /// can't be injected via launch arguments — meets the paywall instead of the composer.
    func testHostAnEventIsGatedBehindTheSubscriptionPaywall() {
        launch(as: .instructor)
        let tile = app.buttons["dashboard.action.createEvent"]
        XCTAssertTrue(scrollToElement(tile), "Host-an-event action missing")
        _ = waitUntil({ tile.isHittable })
        tile.tap()

        XCTAssertTrue(waitForAnyText(["Get Discovered",
                                      "Subscribe so students can find and book you."],
                                     timeout: 15),
                      "An unsubscribed instructor should be sent to the paywall, not the composer")
        XCTAssertFalse(app.textFields["event.title"].exists,
                       "The composer must not open for an instructor who can't be discovered")
    }

    /// Creating and publishing an event, then seeing it land in the dashboard's "YOUR EVENTS".
    ///
    /// This can only run once the instructor is subscribed — the composer sits behind the paywall
    /// above, and a StoreKit entitlement cannot be granted through launch arguments, so in the
    /// standard CI harness this skips rather than reports a false pass. It is written to light up
    /// automatically if a subscribed-instructor launch state is ever added. When it does run it
    /// proves the composer's title gate (publish disabled until a title exists) and the round-trip
    /// into `data.myEvents`.
    func testCreatingAnEventPublishesItToYourEvents() throws {
        launch(as: .instructor)
        let tile = app.buttons["dashboard.action.createEvent"]
        XCTAssertTrue(scrollToElement(tile), "Host-an-event action missing")
        _ = waitUntil({ tile.isHittable })
        tile.tap()

        let titleField = app.textFields["event.title"]
        guard titleField.waitForExistence(timeout: 8) else {
            throw XCTSkip("Composer is gated behind an active subscription, which this harness "
                          + "cannot grant (StoreKit entitlements aren't set via launch arguments). "
                          + "The subscription gate itself is covered by "
                          + "testHostAnEventIsGatedBehindTheSubscriptionPaywall.")
        }

        // Capacity defaults to a positive value, so the publish gate reduces to a non-empty title.
        let publish = app.buttons["event.create"]
        XCTAssertTrue(publish.waitForExistence(timeout: timeout), "Publish button missing")
        XCTAssertFalse(publish.isEnabled, "An untitled event shouldn't be publishable")

        let title = "Sunrise Reformer Flow"
        titleField.tap()
        titleField.typeText(title)
        XCTAssertTrue(waitUntil({ publish.isEnabled }),
                      "A titled event should become publishable")
        publish.tap()

        // Back on the dashboard, the new event shows in YOUR EVENTS with its organizer's own name.
        XCTAssertTrue(waitForAnyText([title], timeout: 15),
                      "A published event should appear in the dashboard's YOUR EVENTS")
    }
}
