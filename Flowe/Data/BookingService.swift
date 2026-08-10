import Foundation
import CloudKit

/// A session request as it exists in the shared catalog (plain DTO decoded from a CKRecord).
struct RemoteBooking {
    let id: String              // recordName — the stable booking identity
    let instructorID: String    // instructor's ownerID
    let studentID: String       // student's ownerID
    let studentName: String     // display name only — never an email
    let date: String
    let time: String
    let type: String
    let duration: String
    let createdAt: Date
    let cancelled: Bool
    /// The record's last server modification time. Since `cancel()` is the last write a booking ever
    /// receives, for a cancelled booking this IS the cancellation time — which lets No-Show Shield
    /// measure a late-cancel against the policy window without adding a `cancelledAt` schema field.
    let modifiedAt: Date?

    init?(record: CKRecord) {
        guard let instructorID = record["instructorID"] as? String,
              let studentID = record["studentID"] as? String else { return nil }
        id = record.recordID.recordName
        self.instructorID = instructorID
        self.studentID = studentID
        studentName = record["studentName"] as? String ?? ""
        date = record["date"] as? String ?? ""
        time = record["time"] as? String ?? ""
        type = record["type"] as? String ?? ""
        duration = record["duration"] as? String ?? ""
        createdAt = record["createdAt"] as? Date ?? .distantPast
        cancelled = (record["cancelled"] as? Int ?? 0) == 1
        modifiedAt = record.modificationDate
    }
}

/// An instructor's accept/decline for a booking.
struct RemoteDecision {
    let bookingID: String
    let confirmed: Bool
    let respondedAt: Date

    init(bookingID: String, confirmed: Bool, respondedAt: Date = .distantPast) {
        self.bookingID = bookingID
        self.confirmed = confirmed
        self.respondedAt = respondedAt
    }

    init?(record: CKRecord) {
        guard let bookingID = record["bookingID"] as? String else { return nil }
        self.bookingID = bookingID
        confirmed = (record["confirmed"] as? Int ?? 0) == 1
        respondedAt = record["respondedAt"] as? Date ?? .distantPast
    }
}

/// Booking exchange over CloudKit's **public** database.
///
/// SwiftData can only mirror the *private* database, where each user sees only their own records —
/// so a student's booking would never reach the instructor. Bookings therefore live in the public
/// database as raw CloudKit, the same way `CatalogService` handles listings.
///
/// Public-DB security grants write to `_creator` and read to `_world`, which means a record is only
/// editable by whoever created it. A booking is consequently modelled as **two** records rather
/// than one mutable row:
///
/// - `SessionBooking` — written by the student (and cancellable by them).
/// - `SessionDecision` — written by the instructor, referencing the booking id.
///
/// Each side only ever writes its own records, so the default security roles are sufficient and no
/// world-writable record type is needed. Effective status is merged client-side in `MockDataStore`.
@MainActor
final class BookingService {
    static let bookingRecordType = "SessionBooking"
    static let decisionRecordType = "SessionDecision"

    /// The field each record type addresses its *recipient* by — the person the record is news for,
    /// who is never the person who wrote it. `PushService` builds its subscription predicates from
    /// these, so renaming a field breaks the query and the notification together instead of leaving
    /// a subscription that silently never fires.
    static let bookingRecipientField = "instructorID"
    static let decisionRecipientField = "studentID"

    /// CloudKit rejects an unbounded query; a pilot instructor is nowhere near this.
    private static let fetchLimit = 200

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    // MARK: - Student writes

    /// Publish a new booking request. Returns the remote id so it can be cached locally.
    ///
    /// `recordName` is nil for a one-off (server-random id, the original path). A recurring standing
    /// slot passes the deterministic `sb-<seriesUUID>-<yyyy-MM-dd>` name so every week of the series
    /// carries its identity in the recordName with NO new public field/record type. That path is
    /// **fetch-or-create (idempotent)**: re-materializing a week that already exists is a no-op, and it
    /// must NEVER reset an existing `cancelled=1` (a skipped week would otherwise silently un-skip).
    func create(instructorID: String,
                studentID: String,
                studentName: String,
                date: String,
                time: String,
                type: String,
                duration: String,
                recordName: String? = nil) async -> String? {
        #if CLOUDKIT_ENABLED
        let record: CKRecord
        let isNew: Bool
        if let recordName {
            let id = CKRecord.ID(recordName: recordName)
            if let existing = try? await database.record(for: id) {
                record = existing
                isNew = false
            } else {
                record = CKRecord(recordType: Self.bookingRecordType, recordID: id)
                isNew = true
            }
        } else {
            record = CKRecord(recordType: Self.bookingRecordType)
            isNew = true
        }
        record["instructorID"] = instructorID
        record["studentID"] = studentID
        record["studentName"] = studentName
        record["date"] = date
        record["time"] = time
        record["type"] = type
        record["duration"] = duration
        // Only stamp createdAt / cancelled when the record is genuinely new. Re-saving an existing
        // series occurrence must leave its `cancelled` flag (a student skip) and original createdAt
        // untouched.
        if isNew {
            record["createdAt"] = Date()
            record["cancelled"] = 0
        }
        do {
            let saved = try await database.save(record)
            return saved.recordID.recordName
        } catch {
            return nil   // offline / not signed into iCloud / schema not deployed
        }
        #else
        return nil
        #endif
    }

    /// Student-initiated cancellation — allowed because the student created this record.
    /// Returns whether the change reached the server.
    @discardableResult
    func cancel(bookingID: String) async -> Bool {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: bookingID)
        guard let record = try? await database.record(for: id) else { return false }
        record["cancelled"] = 1
        return (try? await database.save(record)) != nil
        #else
        return false
        #endif
    }

    // MARK: - Instructor writes

    /// Accept or decline a booking. The instructor creates their *own* record rather than editing
    /// the student's, which is what keeps the default `_creator`-write security workable.
    /// Returns whether the decision reached the server.
    @discardableResult
    func respond(bookingID: String, confirmed: Bool) async -> Bool {
        #if CLOUDKIT_ENABLED
        // recordName is derived from the booking so responding twice updates rather than duplicates,
        // and so the instructor stays the creator of the record they are editing.
        let id = CKRecord.ID(recordName: "decision-\(bookingID)")
        let record = (try? await database.record(for: id))
            ?? CKRecord(recordType: Self.decisionRecordType, recordID: id)
        record["bookingID"] = bookingID
        record["confirmed"] = confirmed ? 1 : 0
        record["respondedAt"] = Date()
        // The student this answer is *for*, copied off the booking.
        //
        // A `CKQuerySubscription` predicate can only test fields on the record that changed, so
        // without this the student has no way to be notified that their request was answered —
        // `SessionDecision` otherwise identifies the booking and nobody else. Only written when the
        // lookup succeeds, so a failed fetch on a re-answer can't blank out a value already there.
        if let studentID = await studentID(forBooking: bookingID) {
            record["studentID"] = studentID
        }
        return (try? await database.save(record)) != nil
        #else
        return false
        #endif
    }

    /// Approve or end a whole standing series with ONE decision — the instructor agrees (or ends) once,
    /// never per week. Reuses the existing `SessionDecision` record type (no schema change): the
    /// bookingID is a new string namespace, `series-<id>` (approve, confirmed=1) or `seriesend-<id>`
    /// (end/decline, confirmed=0). Every occurrence — including weeks that roll into the horizon later —
    /// resolves against this single record client-side, so future weeks auto-confirm for free.
    /// `studentID` is copied on so a push subscription can notify the student, exactly like `respond`.
    @discardableResult
    func respondSeries(seriesID: String, confirmed: Bool, studentID: String?) async -> Bool {
        #if CLOUDKIT_ENABLED
        let bookingID = confirmed ? "series-\(seriesID)" : "seriesend-\(seriesID)"
        let id = CKRecord.ID(recordName: "decision-\(bookingID)")
        let record = (try? await database.record(for: id))
            ?? CKRecord(recordType: Self.decisionRecordType, recordID: id)
        record["bookingID"] = bookingID
        record["confirmed"] = confirmed ? 1 : 0
        record["respondedAt"] = Date()
        if let studentID { record["studentID"] = studentID }
        return (try? await database.save(record)) != nil
        #else
        return false
        #endif
    }

    // MARK: - Slot seat-lock (atomic serverless mutex)
    //
    // The 1-on-1 guarantee and privacy-clean occupancy count both ride ONE new PII-free public record
    // type, `SlotHold`. A seat is claimed by a per-seat create-if-absent atomic mutex: saving a FRESH
    // `CKRecord` (no pre-fetch → no change tag) whose recordID already exists on the server is a
    // precondition violation → `CKError.serverRecordChanged`. So two racers for the same seat → exactly
    // one wins; the loser tries the next seat or reports Full. This is the OPPOSITE of `create(recordName:)`
    // above, which PRE-FETCHES (holds a change tag → last-writer-wins overwrite, never conflicts); the
    // series top-up depends on that overwrite behavior, so this must be a separate method — do NOT fold
    // the two together.
    //
    // The hold recordName `hold-<instructorID>-<yyyy-MM-dd>-<HHmm>-<seat>` is derived ONLY from the
    // physical slot, so a one-off and a standing-series week on the same instructor+date+time contend on
    // the identical key. The hold carries NO studentID/studentName, so returning it to a browsing student
    // as an occupancy count is not a deanonymization leak (see `flowe-booking-privacy-deferred`).

    static let slotHoldRecordType = "SlotHold"

    /// Outcome of a per-slot seat claim. `.claimed` carries the won hold's recordName so the caller can
    /// store it on the booking and later release it; `.waitlisted` carries the won OVERFLOW hold plus a
    /// 0-based waitlist rank (seat index − capacity) — the class was full so the student took a seat
    /// beyond capacity and is on the waitlist; `.slotTaken` means every admitted AND overflow seat is
    /// held (genuinely closed); `.failed` means offline or the `SlotHold` type isn't deployed yet (the
    /// caller degrades to booking WITHOUT a hold — today's unlocked behavior — so the feature ships
    /// incrementally).
    enum SeatClaimResult: Equatable {
        case claimed(recordName: String)
        case waitlisted(recordName: String, rank: Int)
        case slotTaken
        case failed
    }

    /// Outcome of one single-seat create-if-absent attempt: `.won` (this fresh record saved), `.taken`
    /// (the recordID already existed → `serverRecordChanged` → someone holds this exact seat), `.error`
    /// (offline / schema not deployed). The atomic mutex is entirely in `.won` vs `.taken`.
    private enum SingleSeatOutcome { case won(String), taken, error }

    /// The deterministic `SlotHold` recordName for one seat of a physical slot. `date` is POSIX
    /// "yyyy-MM-dd"; `time` is 24h "HHmm". Uniform across one-offs and series occurrences.
    static func slotHoldRecordName(instructorID: String, date: String, time: String, seat: Int) -> String {
        "hold-\(instructorID)-\(date)-\(time)-\(seat)"
    }

    #if CLOUDKIT_ENABLED
    /// One atomic create-if-absent attempt on a specific seat index. Saves a FRESH `CKRecord` (no fetch
    /// → no change tag); a tag-less save whose recordID already exists fails `serverRecordChanged`, which
    /// IS the mutex. Shared by the admitted loop, the waitlist-overflow loop, and the targeted promotion
    /// claim so all three contend identically.
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
    /// Capacity 0 (unstated) normalizes to 1 seat — a slot is NEVER overbooked on an unstated capacity.
    /// Returns the first admitted seat that saved cleanly. When all admitted seats are held: if
    /// `allowWaitlist` and this is a real group type (`cap >= 2`) it continues into OVERFLOW seats
    /// `cap..<(cap+window)` and returns `.waitlisted` on the first that saves (rank = seat − cap); else
    /// `.slotTaken`. `.failed` on any non-conflict error (offline / schema missing) so booking proceeds
    /// unlocked. A cap-1 (Private) slot with the default `allowWaitlist == false` tries only seat 0 and
    /// returns `.slotTaken`/`.failed` exactly as before — the shipped 1-on-1 mutex is byte-identical.
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
        // Every admitted seat is held. Group types can overflow into a bounded waitlist window; a cap-1
        // slot never does (allowWaitlist defaults off), so the 1-on-1 guarantee is untouched.
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

    /// Atomically claim ONE specific seat index — used when PROMOTING a waitlister into a freed
    /// in-capacity seat. Same create-if-absent mutex as `claimSeat`; `.slotTaken` means that exact seat
    /// was won first (a racing fresh booker or a concurrent promotion) so the caller tries the next free
    /// seat; `.failed` degrades (retry next sync). `.waitlisted` is never returned by this path.
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

    /// Release a seat by DELETING its hold — the recordName then goes absent and the next
    /// create-if-absent naturally re-wins it (reuse-if-cancelled). Only the hold's creator (the booking
    /// student) can delete it. Returns whether the delete reached the server.
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

    /// Live occupancy of an instructor's slots on a day, as `[HHmm token: seats taken]`. One query on
    /// the two QUERYABLE fields (`instructorID`, `date`), bucketed client-side by the hold's `time`. Nil
    /// when the query itself failed (offline / schema not deployed) — distinct from an empty dictionary,
    /// which means "genuinely no holds". A DISPLAY HINT only; the atomic claim at confirm is the guarantee.
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

    /// Live seat SETS of an instructor's slots on a day, as `[HHmm token: Set<seat index>]`. Like
    /// `fetchSlotOccupancy` but keeps the individual seat indices so a client can DETERMINISTICALLY
    /// re-derive its waitlist rank and the freed in-capacity seats for promotion. Adds `seat` to
    /// `desiredKeys` — a NON-queryable field fetched by key, which needs no index and no schema change
    /// (the predicate still hits only the queryable `instructorID`+`date`). Nil on query failure.
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

    // MARK: - Push subscriptions

    #if CLOUDKIT_ENABLED
    /// Who made a booking. Used to address the decision record so a query subscription can find it
    /// (see `respond`); nil when the booking can't be read, which is not fatal to the decision.
    private func studentID(forBooking bookingID: String) async -> String? {
        let record = try? await database.record(for: CKRecord.ID(recordName: bookingID))
        return record?["studentID"] as? String
    }
    #endif

    // MARK: - Reads

    /// Bookings addressed to an instructor. Nil when the query itself failed (offline / schema not
    /// deployed) — distinct from an empty array, which means "genuinely no bookings".
    func fetchForInstructor(ownerID: String) async -> [RemoteBooking]? {
        await fetchBookings(matching: NSPredicate(format: "instructorID == %@", ownerID))
    }

    /// Bookings a student has made. Nil when the query failed; empty when there are none.
    func fetchForStudent(ownerID: String) async -> [RemoteBooking]? {
        await fetchBookings(matching: NSPredicate(format: "studentID == %@", ownerID))
    }

    /// Every booking on an instructor's date — the raw slot roster (public, world-readable). The caller
    /// narrows to the exact slot (time + type) and honours community opt-in. See [[Flowe-Community]].
    func fetchSlotRoster(instructorID: String, date: String) async -> [RemoteBooking]? {
        await fetchBookings(matching: NSPredicate(format: "instructorID == %@ AND date == %@", instructorID, date))
    }

    private func fetchBookings(matching predicate: NSPredicate) async -> [RemoteBooking]? {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.bookingRecordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        do {
            let (matches, _) = try await database.records(
                matching: query, desiredKeys: nil, resultsLimit: Self.fetchLimit
            )
            return matches.compactMap { try? $0.1.get() }.compactMap(RemoteBooking.init)
        } catch {
            return nil   // query failed — NOT "no bookings"
        }
        #else
        return nil
        #endif
    }

    /// Decisions for the given bookings, keyed by booking id.
    func fetchDecisions(bookingIDs: [String]) async -> [String: RemoteDecision] {
        #if CLOUDKIT_ENABLED
        guard !bookingIDs.isEmpty else { return [:] }
        let query = CKQuery(recordType: Self.decisionRecordType,
                            predicate: NSPredicate(format: "bookingID IN %@", bookingIDs))
        do {
            let (matches, _) = try await database.records(
                matching: query, desiredKeys: nil, resultsLimit: Self.fetchLimit
            )
            let decisions = matches.compactMap { try? $0.1.get() }.compactMap(RemoteDecision.init)
            return Dictionary(decisions.map { ($0.bookingID, $0) }, uniquingKeysWith: {
                $0.respondedAt >= $1.respondedAt ? $0 : $1
            })
        } catch {
            return [:]
        }
        #else
        return [:]
        #endif
    }
}
