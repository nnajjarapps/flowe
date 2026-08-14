import XCTest
@testable import Flowe

/// Locks the class-package **wire contract** — the snake_case backend JSON → camelCase DTO decode that,
/// when it drifted (`instructor_id` emitted as camelCase `instructorID`), silently produced an EMPTY
/// student wallet with no error. These feed the exact byte shapes the Cloudflare Worker emits
/// (flowe-backend/src/index.js) through the same `JSONDecoder.pkgSnake` the app uses, via the DEBUG-only
/// `PackageWireDecodeSeam`. If a `Wire*` field or the snake_case strategy changes, the break surfaces
/// LOUDLY here instead of quietly on a device.
final class PackageDecodeTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    // /balances element — FORCED snake_case (index.js documents the empty-wallet regression from a
    // camelCase key). `instructor_id` → `instructorID` is the whole ballgame.
    func testWalletEntryDecodesSnakeCase() throws {
        let entry = try PackageWireDecodeSeam.walletEntry(
            data(#"{"instructor_id":"001941.abc.1412","balance":8,"next_expiry":null}"#))
        XCTAssertEqual(entry.instructorID, "001941.abc.1412")
        XCTAssertEqual(entry.balance, 8)
        XCTAssertNil(entry.nextExpiry)
    }

    func testWalletEntryCarriesExpiry() throws {
        let entry = try PackageWireDecodeSeam.walletEntry(
            data(#"{"instructor_id":"ins-1","balance":3,"next_expiry":1893456000000}"#))
        XCTAssertEqual(entry.balance, 3)
        XCTAssertNotNil(entry.nextExpiry)
    }

    // /balance — top-level `instructorID`/`nextExpiry` are camelCase; lot keys are snake_case. The mixed
    // shape must still decode (convertFromSnakeCase leaves underscore-free keys untouched).
    func testBalanceAndLotsDecode() throws {
        let bal = try PackageWireDecodeSeam.balance(
            data(#"{"instructorID":"ins-1","balance":6,"nextExpiry":null,"lots":[{"id":"grant-1","total":10,"remaining":6,"expires_at":null,"created_at":1700000000000}]}"#),
            instructorID: "ins-1")
        XCTAssertEqual(bal.instructorID, "ins-1")
        XCTAssertEqual(bal.balance, 6)
        XCTAssertEqual(bal.lots.count, 1)
        XCTAssertEqual(bal.lots.first?.total, 10)
        XCTAssertEqual(bal.lots.first?.remaining, 6)
    }

    // A SELECT * offering row — `active` may be absent on the public read and must default to true.
    func testOfferingDecodesAndActiveDefaultsTrue() throws {
        let archived = try PackageWireDecodeSeam.offering(
            data(#"{"id":"offering-1","instructor_id":"ins-1","title":"10-pack","credits":10,"price":500,"validity_days":30,"active":0,"created_at":1,"updated_at":1}"#))
        XCTAssertEqual(archived.instructorID, "ins-1")
        XCTAssertEqual(archived.credits, 10)
        XCTAssertEqual(archived.validityDays, 30)
        XCTAssertFalse(archived.active)

        let publicRow = try PackageWireDecodeSeam.offering(
            data(#"{"id":"offering-2","instructor_id":"ins-1","title":"5-pack","credits":5,"price":200,"validity_days":null}"#))
        XCTAssertTrue(publicRow.active)          // absent → default active
        XCTAssertNil(publicRow.validityDays)     // null → never-expires
    }

    func testPurchaseDecodesPendingStatus() throws {
        let p = try PackageWireDecodeSeam.purchase(
            data(#"{"id":"purchase-1","offering_id":"offering-1","instructor_id":"ins-1","student_id":"stu-1","student_name":"Dana","credits":10,"price":500,"validity_days":30,"status":"pending","created_at":1700000000000,"responded_at":null}"#))
        XCTAssertEqual(p.instructorID, "ins-1")
        XCTAssertEqual(p.studentID, "stu-1")
        XCTAssertEqual(p.status, .pending)
        XCTAssertNil(p.respondedAt)
    }
}
