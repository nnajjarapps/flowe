import XCTest
@testable import Flowe

/// Locks the recurring-series CANCEL flow — the fix for the bug where a student could never leave a
/// standing weekly series: the cancel button only ever offered a one-off cancel, so `endSeriesAsStudent`
/// (and its `seriesend-<id>` tombstone) was unreachable and the rolling top-up regrew the series every
/// time the horizon advanced. These lock the two decision points the fix depends on. Pure value logic;
/// no host state. See [[flowe-recurring-series-cancel]].
final class RecurringSeriesTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_755_000_000)

    // MARK: - isRecurring / seriesID derivation (what the cancel button keys off)

    func testSeriesBookingIsRecurring() {
        let name = Booking.seriesRecordName(seriesID: "S-abc", occurrenceDate: fixedDate)
        let booking = Booking(remoteID: name)
        XCTAssertTrue(booking.isRecurring)
        XCTAssertEqual(booking.seriesID, "S-abc")
    }

    func testOneOffBookingIsNotRecurring() {
        XCTAssertFalse(Booking(remoteID: "msg-123").isRecurring)
        XCTAssertNil(Booking(remoteID: "msg-123").seriesID)
    }

    func testNilRemoteIDIsNotRecurring() {
        XCTAssertFalse(Booking(remoteID: nil).isRecurring)
    }

    func testSeriesIDRoundTripsThroughUUID() {
        let sid = UUID().uuidString   // a UUID has internal dashes — the parse must survive them
        let name = Booking.seriesRecordName(seriesID: sid, occurrenceDate: fixedDate)
        XCTAssertEqual(Booking(remoteID: name).seriesID, sid)
    }

    // MARK: - The cancel-kind decision (the wiring that was MISSING — button used to hardcode .oneOff)

    func testRecurringOffersSeriesCancel() {
        // Scenario 1: a standing series → the dialog offers skip-this-week vs end-series.
        XCTAssertTrue(BookingCard.offersSeriesCancel(isRecurring: true, isWaitlisted: false))
    }

    func testOneOffDoesNotOfferSeriesCancel() {
        // Scenario 2: a one-off booking → a plain cancel.
        XCTAssertFalse(BookingCard.offersSeriesCancel(isRecurring: false, isWaitlisted: false))
    }

    func testWaitlistedRecurringLeavesWaitlistNotSeries() {
        // Scenario 6: a waitlisted overflow week just leaves that week's waitlist (one-off), not the series.
        XCTAssertFalse(BookingCard.offersSeriesCancel(isRecurring: true, isWaitlisted: true))
    }

    // MARK: - The regrow guard (end-series STICKS; a one-off cancel does NOT end the series)

    func testFreshSeriesRegrows() {
        // Scenario 4: no tombstone / no remote end → top-up regrows it. This is exactly why cancelling a
        // single week (one-off) can't end a series — nothing here stops the regrow.
        XCTAssertFalse(MockDataStore.seriesIsEnded("S1", endedLocally: [], decisions: [:]))
    }

    func testLocallyEndedSeriesStops() {
        // Scenario 3a: end-series wrote the local tombstone → top-up skips it on THIS device.
        XCTAssertTrue(MockDataStore.seriesIsEnded("S1", endedLocally: ["S1"], decisions: [:]))
    }

    func testRemotelyEndedSeriesStops() {
        // Scenario 3b: the durable seriesend-<id> decision → top-up skips it on ANY device / after reinstall.
        let decisions = ["seriesend-S1": RemoteDecision(bookingID: "S1", confirmed: false)]
        XCTAssertTrue(MockDataStore.seriesIsEnded("S1", endedLocally: [], decisions: decisions))
    }

    func testAnotherSeriesEndDoesNotStopThisOne() {
        // A different series' end must not stop this one (guard is keyed on the exact series id).
        let decisions = ["seriesend-OTHER": RemoteDecision(bookingID: "OTHER", confirmed: false)]
        XCTAssertFalse(MockDataStore.seriesIsEnded("S1", endedLocally: ["OTHER"], decisions: decisions))
    }
}
