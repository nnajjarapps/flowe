import XCTest
@testable import Flowe

/// Locks the booking **wire contract** — the same snake_case→camelCase decode whose drift once made an
/// instructor's inbox decode to zero rows (`instructor_id` vs `instructorID`). Decodes the exact Worker
/// row shape through the DEBUG-only `BookingWireDecodeSeam`, including the `cancelled` Int→Bool and
/// `cancelled_at`→`modifiedAt` mappings the No-Show Shield relies on.
final class BookingDecodeTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testPendingBookingDecodesSnakeCase() throws {
        let b = try BookingWireDecodeSeam.booking(
            data(#"{"id":"bk-1","instructor_id":"ins-1","student_id":"stu-1","student_name":"Dana","date":"Mon, Jun 1","time":"10:00 AM","type":"Reformer","duration":"50 min","created_at":1700000000000,"cancelled":0,"cancelled_at":null,"confirmed":null,"responded_at":null}"#))
        XCTAssertEqual(b.instructorID, "ins-1")   // instructor_id → instructorID (the inbox-empty lock)
        XCTAssertEqual(b.studentID, "stu-1")
        XCTAssertEqual(b.studentName, "Dana")
        XCTAssertFalse(b.cancelled)
        XCTAssertNil(b.modifiedAt)
    }

    func testCancelledBookingMapsFlagAndModifiedAt() throws {
        let b = try BookingWireDecodeSeam.booking(
            data(#"{"id":"bk-2","instructor_id":"ins-1","student_id":"stu-1","student_name":"Dana","date":"Mon, Jun 1","time":"10:00 AM","type":"Reformer","duration":"50 min","created_at":1700000000000,"cancelled":1,"cancelled_at":1700000005000,"confirmed":1,"responded_at":1700000003000}"#))
        XCTAssertTrue(b.cancelled)                // cancelled Int 1 → true
        XCTAssertNotNil(b.modifiedAt)             // cancelled_at → modifiedAt (No-Show Shield signal)
    }
}
