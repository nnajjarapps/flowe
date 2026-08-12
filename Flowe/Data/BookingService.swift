import Foundation
import CloudKit

/// A session request as it exists in the backend (plain DTO decoded from JSON). Field shape is kept
/// byte-identical to the old CloudKit-decoded form so `MockDataStore` (the only caller) is unchanged.
struct RemoteBooking {
    let id: String              // stable booking identity (backend row id)
    let instructorID: String    // instructor's ownerID
    let studentID: String       // student's ownerID
    let studentName: String     // display name only — never an email
    let date: String
    let time: String
    let type: String
    let duration: String
    let createdAt: Date
    let cancelled: Bool
    /// For a cancelled booking this IS the cancellation time (server `cancelled_at`), which lets
    /// No-Show Shield measure a late-cancel against the policy window without a separate field.
    let modifiedAt: Date?
}

/// An instructor's accept/decline for a booking. Reconstructed from the inline decision the backend
/// returns on each booking row (per-occurrence) or from the series_decisions table (standing series).
struct RemoteDecision {
    let bookingID: String
    let confirmed: Bool
    let respondedAt: Date

    init(bookingID: String, confirmed: Bool, respondedAt: Date = .distantPast) {
        self.bookingID = bookingID
        self.confirmed = confirmed
        self.respondedAt = respondedAt
    }
}

/// Booking exchange. **Hybrid:** the booking/decision/roster paths go through the authorization
/// backend (FloweBackendClient) so who-booked-whom is returned ONLY to the two parties — the
/// per-request authz CloudKit's public DB cannot do. The PII-free `SlotHold` seat mutex stays on
/// CloudKit (atomic create-if-absent; no studentID/name, so no deanonymization). See
/// flowe_vault/nodes/system/BookingBackend.md and [[flowe-booking-privacy-deferred]].
@MainActor
final class BookingService {
    // Legacy CloudKit record-type / recipient-field constants (kept for reference; the booking &
    // decision records themselves now live in the backend, not CloudKit).
    static let bookingRecordType = "SessionBooking"
    static let decisionRecordType = "SessionDecision"
    static let bookingRecipientField = "instructorID"
    static let decisionRecipientField = "studentID"

    /// CloudKit rejects an unbounded query; a pilot instructor is nowhere near this. (SlotHold reads.)
    private static let fetchLimit = 200

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    /// Per-occurrence decisions captured inline during the most recent inbox fetch, so the immediately
    /// following `fetchDecisions(bookingIDs:)` can return them without a second round-trip. Populated by
    /// `fetchForInstructor`/`fetchForStudent`; consumed by `fetchDecisions`. syncBookings always calls
    /// the fetch then fetchDecisions in that order, so the cache is fresh.
    private var lastDecisions: [String: RemoteDecision] = [:]

    private let backend = FloweBackendClient.shared

    // MARK: - Student writes (backend)

    /// Publish a new booking request. `recordName` nil = one-off (server-random id); a recurring
    /// standing slot passes the deterministic `sb-<seriesUUID>-<yyyy-MM-dd>` id so every week carries
    /// its identity and the backend's `ON CONFLICT(id) DO NOTHING` makes re-materializing idempotent
    /// (never resurrecting a cancelled week). The student is the authenticated caller — the backend
    /// files the row under the verified token, so `studentID` here is advisory only.
    func create(instructorID: String,
                studentID: String,
                studentName: String,
                date: String,
                time: String,
                type: String,
                duration: String,
                recordName: String? = nil) async -> String? {
        struct Body: Encodable {
            let id: String?
            let instructorID: String
            let studentName: String
            let date: String
            let time: String
            let type: String
            let duration: String
        }
        let body = Body(id: recordName, instructorID: instructorID, studentName: studentName,
                        date: date, time: time, type: type, duration: duration)
        do {
            let data = try await backend.authorized("/bookings", method: "POST", body: body, interactive: true)
            struct Resp: Decodable { let id: String }
            return try JSONDecoder().decode(Resp.self, from: data).id
        } catch {
            return nil   // offline / not authenticated with the backend yet
        }
    }

    /// Student-initiated cancellation — the backend enforces that only the creating student can cancel.
    @discardableResult
    func cancel(bookingID: String) async -> Bool {
        do {
            _ = try await backend.authorized("/bookings/\(bookingID)/cancel", method: "POST", interactive: true)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Instructor writes (backend)

    /// Accept or decline a booking. The backend verifies the caller is that booking's instructor.
    @discardableResult
    func respond(bookingID: String, confirmed: Bool) async -> Bool {
        struct Body: Encodable { let confirmed: Bool }
        do {
            _ = try await backend.authorized("/bookings/\(bookingID)/decision", method: "POST", body: Body(confirmed: confirmed), interactive: true)
            return true
        } catch {
            return false
        }
    }

    /// Approve or end a whole standing series with ONE decision. The backend records it in
    /// series_decisions (verifying the caller teaches the series) and every occurrence resolves against
    /// it client-side. `studentID` lets the backend push the student.
    @discardableResult
    func respondSeries(seriesID: String, confirmed: Bool, studentID: String?) async -> Bool {
        struct Body: Encodable { let confirmed: Bool; let studentID: String? }
        do {
            _ = try await backend.authorized("/series/\(seriesID)/decision", method: "POST", body: Body(confirmed: confirmed, studentID: studentID), interactive: true)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Slot seat-lock (atomic serverless mutex — STAYS ON CLOUDKIT)
    //
    // The 1-on-1 guarantee and privacy-clean occupancy count both ride ONE PII-free public record
    // type, `SlotHold`. A seat is claimed by a per-seat create-if-absent atomic mutex: saving a FRESH
    // `CKRecord` (no pre-fetch → no change tag) whose recordID already exists on the server is a
    // precondition violation → `CKError.serverRecordChanged`. So two racers for the same seat → exactly
    // one wins. It carries NO studentID/studentName, so returning it to a browsing student as an
    // occupancy count is not a deanonymization leak (see flowe-booking-privacy-deferred).

    static let slotHoldRecordType = "SlotHold"

    /// Outcome of a per-slot seat claim. `.claimed` carries the won hold's recordName; `.waitlisted`
    /// carries the OVERFLOW hold plus a 0-based waitlist rank; `.slotTaken` = genuinely closed;
    /// `.failed` = offline / type not deployed (caller degrades to booking WITHOUT a hold).
    enum SeatClaimResult: Equatable {
        case claimed(recordName: String)
        case waitlisted(recordName: String, rank: Int)
        case slotTaken
        case failed
    }

    private enum SingleSeatOutcome { case won(String), taken, error }

    /// The deterministic `SlotHold` recordName for one seat. `date` POSIX "yyyy-MM-dd"; `time` 24h "HHmm".
    static func slotHoldRecordName(instructorID: String, date: String, time: String, seat: Int) -> String {
        "hold-\(instructorID)-\(date)-\(time)-\(seat)"
    }

    #if CLOUDKIT_ENABLED
    /// One atomic create-if-absent attempt on a specific seat index. Saves a FRESH `CKRecord` (no fetch
    /// → no change tag); a tag-less save whose recordID already exists fails `serverRecordChanged` — the mutex.
    private func attemptSeat(instructorID: String, date: String, time: String, seat: Int) async -> SingleSeatOutcome {
        let id = CKRecord.ID(recordName: Self.slotHoldRecordName(
            instructorID: instructorID, date: date, time: time, seat: seat))
        let record = CKRecord(recordType: Self.slotHoldRecordType, recordID: id)
        record["instructorID"] = instructorID
        record["date"] = date
        record["time"] = time
        record["seat"] = seat
        record["createdAt"] = Date()
        do {
            let saved = try await database.save(record)
            return .won(saved.recordID.recordName)
        } catch let error as CKError where error.code == .serverRecordChanged {
            return .taken
        } catch {
            return .error
        }
    }
    #endif

    /// Atomically claim a seat on `instructor+date+time`, trying admitted seats `0..<capacity` in order.
    /// Capacity 0 normalizes to 1. When all admitted seats are held: if `allowWaitlist` and a real group
    /// type (`cap >= 2`) it continues into OVERFLOW seats and returns `.waitlisted`; else `.slotTaken`.
    func claimSeat(instructorID: String, date: String, time: String, capacity: Int,
                   allowWaitlist: Bool = false, waitlistWindow: Int = 10) async -> SeatClaimResult {
        #if CLOUDKIT_ENABLED
        let cap = max(capacity, 1)   // capacity 0 (unstated) => 1 seat (never overbook)
        for seat in 0..<cap {
            switch await attemptSeat(instructorID: instructorID, date: date, time: time, seat: seat) {
            case .won(let name): return .claimed(recordName: name)   // won an admitted seat
            case .taken:         continue                            // this seat is taken — try the next
            case .error:         return .failed                      // offline / schema not deployed
            }
        }
        if allowWaitlist && cap >= 2 {
            for seat in cap..<(cap + max(waitlistWindow, 0)) {
                switch await attemptSeat(instructorID: instructorID, date: date, time: time, seat: seat) {
                case .won(let name): return .waitlisted(recordName: name, rank: seat - cap)
                case .taken:         continue
                case .error:         return .failed
                }
            }
        }
        return .slotTaken   // every admitted (and overflow) seat held
        #else
        return .failed
        #endif
    }

    /// Atomically claim ONE specific seat index — used when PROMOTING a waitlister into a freed seat.
    func claimSeat(instructorID: String, date: String, time: String, seat: Int) async -> SeatClaimResult {
        #if CLOUDKIT_ENABLED
        switch await attemptSeat(instructorID: instructorID, date: date, time: time, seat: seat) {
        case .won(let name): return .claimed(recordName: name)
        case .taken:         return .slotTaken
        case .error:         return .failed
        }
        #else
        return .failed
        #endif
    }

    /// Release a seat by DELETING its hold — the next create-if-absent naturally re-wins it. Only the
    /// hold's creator (the booking student) can delete it.
    @discardableResult
    func releaseSeat(recordName: String) async -> Bool {
        #if CLOUDKIT_ENABLED
        do {
            _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: recordName))
            return true
        } catch let error as CKError where error.code == .unknownItem {
            return true   // hold already absent — a delete of a gone record IS a successful release
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    // MARK: - Reads

    /// Bookings addressed to an instructor — the backend returns ONLY rows where the caller is the
    /// instructor (authorization is the WHERE clause). nil = request failed (offline / not
    /// authenticated); [] = genuinely none. Also caches inline decisions for `fetchDecisions`.
    func fetchForInstructor(ownerID: String) async -> [RemoteBooking]? {
        await fetchInbox("/inbox/instructor")
    }

    /// Bookings a student has made — backend returns only rows where the caller is the student.
    func fetchForStudent(ownerID: String) async -> [RemoteBooking]? {
        await fetchInbox("/inbox/student")
    }

    private func fetchInbox(_ path: String) async -> [RemoteBooking]? {
        do {
            let data = try await backend.authorized(path)
            struct Resp: Decodable { let bookings: [WireBooking] }
            let wires = try JSONDecoder.snakeCase.decode(Resp.self, from: data).bookings
            cacheDecisions(from: wires)
            return wires.map(\.remote)
        } catch {
            return nil   // request failed — NOT "no bookings"
        }
    }

    /// Every booking on an instructor's date — the roster the caller may see only because they are a
    /// party to that slot (the backend enforces it: 403 otherwise). The caller narrows to the exact
    /// slot and honours community opt-in. See [[Flowe-Community]]. Does NOT touch the decision cache
    /// (this is a peer read, not the caller's own inbox).
    func fetchSlotRoster(instructorID: String, date: String) async -> [RemoteBooking]? {
        do {
            let data = try await backend.authorized("/roster", query: [
                URLQueryItem(name: "instructorID", value: instructorID),
                URLQueryItem(name: "date", value: date),
            ])
            struct Resp: Decodable { let bookings: [WireBooking] }
            return try JSONDecoder.snakeCase.decode(Resp.self, from: data).bookings.map(\.remote)
        } catch {
            return nil
        }
    }

    /// Decisions for the given bookings, keyed by booking id (and by the synthetic `series-<sid>` /
    /// `seriesend-<sid>` ids the resolver expects). Per-occurrence decisions come from the inline cache
    /// populated by the immediately-preceding inbox fetch; series-level decisions are fetched per series.
    func fetchDecisions(bookingIDs: [String]) async -> [String: RemoteDecision] {
        var out: [String: RemoteDecision] = [:]
        for id in bookingIDs {
            if let decision = lastDecisions[id] { out[id] = decision }
        }
        let seriesIDs = Set(bookingIDs.compactMap { id -> String? in
            id.hasPrefix("series-") ? String(id.dropFirst("series-".count)) : nil
        })
        for sid in seriesIDs {
            for (key, value) in await fetchSeriesDecisions(seriesID: sid) { out[key] = value }
        }
        return out
    }

    /// Series-level decisions for one series, keyed `series-<sid>` (approve) / `seriesend-<sid>` (end).
    private func fetchSeriesDecisions(seriesID: String) async -> [String: RemoteDecision] {
        struct Row: Decodable { let ended: Int; let confirmed: Int; let respondedAt: Double? }
        struct Resp: Decodable { let decisions: [Row] }
        do {
            let data = try await backend.authorized("/series/\(seriesID)/decision")
            let rows = try JSONDecoder.snakeCase.decode(Resp.self, from: data).decisions
            var out: [String: RemoteDecision] = [:]
            for row in rows {
                let key = row.ended == 1 ? "seriesend-\(seriesID)" : "series-\(seriesID)"
                out[key] = RemoteDecision(bookingID: key, confirmed: row.confirmed == 1,
                                          respondedAt: row.respondedAt.map(Date.init(msEpoch:)) ?? .distantPast)
            }
            return out
        } catch {
            return [:]
        }
    }

    private func cacheDecisions(from wires: [WireBooking]) {
        var dict: [String: RemoteDecision] = [:]
        for wire in wires where wire.confirmed != nil {
            dict[wire.id] = RemoteDecision(bookingID: wire.id, confirmed: wire.confirmed == 1,
                                           respondedAt: wire.respondedAt.map(Date.init(msEpoch:)) ?? .distantPast)
        }
        lastDecisions = dict
    }

    /// Live occupancy of an instructor's slots on a day, as `[HHmm token: seats taken]` (SlotHold —
    /// CloudKit). Nil when the query failed. A DISPLAY HINT only; the atomic claim at confirm is the guarantee.
    func fetchSlotOccupancy(instructorID: String, date: String) async -> [String: Int]? {
        #if CLOUDKIT_ENABLED
        let predicate = NSPredicate(format: "instructorID == %@ AND date == %@", instructorID, date)
        let query = CKQuery(recordType: Self.slotHoldRecordType, predicate: predicate)
        do {
            let (matches, _) = try await database.records(
                matching: query, desiredKeys: ["time"], resultsLimit: Self.fetchLimit
            )
            let holds = matches.compactMap { try? $0.1.get() }
            var counts: [String: Int] = [:]
            for hold in holds {
                if let token = hold["time"] as? String { counts[token, default: 0] += 1 }
            }
            return counts
        } catch {
            return nil   // query failed — NOT "no holds"
        }
        #else
        return nil
        #endif
    }

    /// Live seat SETS of an instructor's slots on a day, as `[HHmm token: Set<seat index>]` (SlotHold —
    /// CloudKit), so a client can deterministically re-derive waitlist rank and freed seats. Nil on failure.
    func fetchSlotHolds(instructorID: String, date: String) async -> [String: Set<Int>]? {
        #if CLOUDKIT_ENABLED
        let predicate = NSPredicate(format: "instructorID == %@ AND date == %@", instructorID, date)
        let query = CKQuery(recordType: Self.slotHoldRecordType, predicate: predicate)
        do {
            let (matches, _) = try await database.records(
                matching: query, desiredKeys: ["time", "seat"], resultsLimit: Self.fetchLimit
            )
            let holds = matches.compactMap { try? $0.1.get() }
            var out: [String: Set<Int>] = [:]
            for hold in holds {
                guard let token = hold["time"] as? String, let seat = hold["seat"] as? Int else { continue }
                out[token, default: []].insert(seat)
            }
            return out
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Legacy CloudKit series-decision cleanup on account deletion. Post-cutover the SessionDecision
    /// records no longer exist, so this is a harmless no-op; backend series_decisions are purged by
    /// `FloweBackendClient.deleteAccount()` (DELETE /me) in the account-deletion flow.
    func deleteSeriesDecisions(seriesIDs: [String]) async {
        #if CLOUDKIT_ENABLED
        for seriesID in seriesIDs {
            for bookingID in ["series-\(seriesID)", "seriesend-\(seriesID)"] {
                _ = try? await database.deleteRecord(withID: CKRecord.ID(recordName: "decision-\(bookingID)"))
            }
        }
        #endif
    }
}

// MARK: - Wire decoding

/// The backend booking row (snake_case JSON → camelCase via `.convertFromSnakeCase`).
private struct WireBooking: Decodable {
    let id: String
    let instructorId: String
    let studentId: String
    let studentName: String
    let date: String
    let time: String
    let type: String
    let duration: String
    let createdAt: Double
    let cancelled: Int
    let cancelledAt: Double?
    let confirmed: Int?
    let respondedAt: Double?

    var remote: RemoteBooking {
        RemoteBooking(id: id, instructorID: instructorId, studentID: studentId,
                      studentName: studentName, date: date, time: time, type: type, duration: duration,
                      createdAt: Date(msEpoch: createdAt), cancelled: cancelled == 1,
                      modifiedAt: cancelledAt.map(Date.init(msEpoch:)))
    }
}

private extension JSONDecoder {
    static var snakeCase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

private extension Date {
    /// Backend timestamps are JS `Date.now()` — milliseconds since the epoch.
    init(msEpoch ms: Double) { self.init(timeIntervalSince1970: ms / 1000) }
}
