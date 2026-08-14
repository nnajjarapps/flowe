import XCTest
@testable import Flowe

/// Pins the pure session-timing logic reconstructed from a booking's language-neutral display strings
/// (no timestamp is stored). The nearest-of-three-years choice in `sessionEnd` is the subtle one — a
/// "Dec 30" seen on "Jan 2" must resolve to LAST year — and it drives the confirmed→completed
/// transition nothing else performs. All static/pure: no CloudKit, no host state.
final class BookingTimingTests: XCTestCase {

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func testTimeTokenFormatsTo24hHHmm() {
        XCTAssertEqual(Booking.timeToken("9:00 AM"), "0900")
        XCTAssertEqual(Booking.timeToken("12:30 PM"), "1230")
        XCTAssertEqual(Booking.timeToken("12:00 AM"), "0000")   // midnight, not noon
        XCTAssertNil(Booking.timeToken("not a time"))
    }

    func testSessionEndResolvesAcrossTheYearBoundary() throws {
        // "Dec 30, 9:00 AM, 55 min" observed on Jan 2 2026 → the session was Dec 30 2025 (last year).
        let end = try XCTUnwrap(
            Booking.sessionEnd(date: "Sat, Dec 30", time: "9:00 AM", duration: "55 min", now: at(2026, 1, 2)))
        let cal = Calendar(identifier: .gregorian)
        XCTAssertEqual(cal.component(.year, from: end), 2025)
        XCTAssertEqual(cal.component(.hour, from: end), 9)
        XCTAssertEqual(cal.component(.minute, from: end), 55)
    }

    func testSessionEndIsNilOnUnparseableStrings() {
        XCTAssertNil(Booking.sessionEnd(date: "whenever", time: "??", duration: "55 min", now: at(2026, 1, 2)))
    }

    func testIsOverComparesSessionEndToNow() {
        // Session on "Jun 1". Two weeks after → over; two weeks before → not over; garbage → not over
        // (an un-datable booking must never be wrongly marked delivered).
        XCTAssertTrue(Booking.isOver(date: "Mon, Jun 1", time: "10:00 AM", duration: "50 min", now: at(2026, 6, 15)))
        XCTAssertFalse(Booking.isOver(date: "Mon, Jun 1", time: "10:00 AM", duration: "50 min", now: at(2026, 5, 15)))
        XCTAssertFalse(Booking.isOver(date: "garbage", time: "x", duration: "50 min", now: at(2026, 6, 15)))
    }
}
