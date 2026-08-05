import Foundation
import CloudKit

/// An "Out of Studio" coverage request as it exists in the shared catalog (plain DTO decoded from a
/// CKRecord). Written by the instructor who is stepping out; `filledByID` is flipped by that same owner
/// once they pick a winner, which is how the owner's side of the two-sided approval is recorded.
struct RemoteCoverageRequest {
    let id: String              // recordName — "coverage-<bookingID>"
    let requesterID: String     // the OOS owner's ownerID
    let filledByID: String      // the awarded replacer's ownerID, or "" while still open
    let bookingID: String       // the session that needs covering
    let sessionDate: String
    let sessionTime: String
    let sessionDuration: String
    let sessionType: String
    let windowStart: Date
    let windowEnd: Date
    let status: Int             // 0 open / 1 filled / 2 cancelled
    let createdAt: Date

    init?(record: CKRecord) {
        guard let requesterID = record["requesterID"] as? String,
              let bookingID = record["bookingID"] as? String else { return nil }
        id = record.recordID.recordName
        self.requesterID = requesterID
        filledByID = record["filledByID"] as? String ?? ""
        self.bookingID = bookingID
        sessionDate = record["sessionDate"] as? String ?? ""
        sessionTime = record["sessionTime"] as? String ?? ""
        sessionDuration = record["sessionDuration"] as? String ?? ""
        sessionType = record["sessionType"] as? String ?? ""
        windowStart = record["windowStart"] as? Date ?? .distantPast
        windowEnd = record["windowEnd"] as? Date ?? .distantFuture
        status = record["status"] as? Int ?? 0
        createdAt = record["createdAt"] as? Date ?? .distantPast
    }
}

/// One addressed offer, auto-fanned to a ranked candidate. Carries only the booking reference and the
/// coarse session facts a candidate needs to decide — never the student's name/id or any lat/long.
struct RemoteCoverageOffer {
    let id: String              // recordName — "offer-<bookingID>-<candidateID>"
    let candidateID: String     // the instructor this offer is addressed to
    let requesterID: String     // who is out of studio
    let bookingID: String
    let sessionType: String
    let sessionDate: String
    let createdAt: Date

    init?(record: CKRecord) {
        guard let candidateID = record["candidateID"] as? String,
              let bookingID = record["bookingID"] as? String else { return nil }
        id = record.recordID.recordName
        self.candidateID = candidateID
        requesterID = record["requesterID"] as? String ?? ""
        self.bookingID = bookingID
        sessionType = record["sessionType"] as? String ?? ""
        sessionDate = record["sessionDate"] as? String ?? ""
        createdAt = record["createdAt"] as? Date ?? .distantPast
    }
}

/// A candidate's response to an offer. Writing this with `accepted == 1` IS the replacer's half of the
/// two-sided approval; the OOS owner then awards one claimant by flipping their request's `filledByID`.
struct RemoteCoverageClaim {
    let id: String              // recordName — "claim-<bookingID>-<replacerID>"
    let requesterID: String     // addressed back to the OOS owner
    let replacerID: String      // the candidate claiming
    let bookingID: String
    let replacerName: String    // display name only — never an email
    let accepted: Bool
    let claimedAt: Date

    init?(record: CKRecord) {
        guard let requesterID = record["requesterID"] as? String,
              let bookingID = record["bookingID"] as? String else { return nil }
        id = record.recordID.recordName
        self.requesterID = requesterID
        replacerID = record["replacerID"] as? String ?? ""
        self.bookingID = bookingID
        replacerName = record["replacerName"] as? String ?? ""
        accepted = (record["accepted"] as? Int ?? 0) == 1
        claimedAt = record["claimedAt"] as? Date ?? .distantPast
    }
}

/// The single record the student ever sees for a covered session, addressed to them by `studentID`.
/// Their own `SessionBooking` is never touched — this record is what the booking card reads to show
/// "Covered by <name>". The lone Coverage* record that carries a student identifier, and only because
/// it is addressed to the very student it concerns.
struct RemoteCoverageSession {
    let id: String              // recordName — "coverSession-<bookingID>"
    let studentID: String       // the student this cover is news for
    let coveringInstructorID: String
    let coveringInstructorName: String
    let requesterID: String     // the original instructor who stepped out
    let status: Int             // 0 covered / 1 cancelled
    let createdAt: Date

    /// The covered booking's id, derived from the deterministic recordName ("coverSession-<bookingID>")
    /// rather than stored as its own field — the booking id is always recoverable from the name.
    var bookingID: String {
        id.hasPrefix("coverSession-") ? String(id.dropFirst("coverSession-".count)) : id
    }

    init?(record: CKRecord) {
        guard let studentID = record["studentID"] as? String else { return nil }
        id = record.recordID.recordName
        self.studentID = studentID
        coveringInstructorID = record["coveringInstructorID"] as? String ?? ""
        coveringInstructorName = record["coveringInstructorName"] as? String ?? ""
        requesterID = record["requesterID"] as? String ?? ""
        status = record["status"] as? Int ?? 0
        createdAt = record["createdAt"] as? Date ?? .distantPast
    }
}

/// "Out of Studio" coverage exchange over CloudKit's **public** database.
///
/// Structurally a sibling of `BookingService`: SwiftData can only mirror the *private* database, so any
/// record that has to travel between two different users lives in the public database as raw CloudKit.
/// Public-DB security grants write to `_creator` and read to `_world`, so — exactly as with bookings —
/// each side only ever writes records it owns, and effective state is merged client-side in
/// `MockDataStore`:
///
/// - `CoverageRequest` — written by the OOS owner. Awarding a winner is the owner flipping `filledByID`
///   on this record they own (their half of the two-sided approval).
/// - `CoverageOffer` — written by the OOS owner, one per ranked candidate (auto-fan, K ≤ 10).
/// - `CoverageClaim` — written by a candidate. `accepted == 1` is the candidate's half of the approval.
/// - `CoverageSession` — written by the OOS owner, addressed to the student, so the student's booking
///   card can show "Covered by <name>" without ever mutating the student-owned `SessionBooking`.
///
/// PILOT-ONLY privacy note: like bookings, these records are world-readable and deepen the known
/// deanonymization debt tracked for the pilot. Deliberately, no Coverage* record carries a student
/// name/id or any lat/long **except** `CoverageSession`, which carries `studentID` and only because it
/// is addressed to the very student it concerns. Offers reference the booking id and coarse session
/// facts, nothing more.
@MainActor
final class CoverageService {
    static let requestRecordType = "CoverageRequest"
    static let offerRecordType = "CoverageOffer"
    static let claimRecordType = "CoverageClaim"
    static let sessionRecordType = "CoverageSession"

    /// The field each record type addresses its *recipient* by — the person the record is news for, who
    /// is never the person who wrote it. `PushService` builds its subscription predicates from these, so
    /// renaming a field breaks the query and the notification together instead of leaving a subscription
    /// that silently never fires. `CoverageRequest` is addressed to the awarded replacer via `filledByID`
    /// — empty while open, so the "you were picked" subscription only fires once it is set.
    static let offerRecipientField = "candidateID"
    static let claimRecipientField = "requesterID"
    static let requestRecipientField = "filledByID"
    static let sessionRecipientField = "studentID"

    /// CloudKit rejects an unbounded query; a pilot instructor is nowhere near this.
    private static let fetchLimit = 200

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    // MARK: - Owner writes

    /// Publish (or refresh) the coverage request for a booking. The recordName is derived from the
    /// booking so reporting OOS twice for the same session updates rather than duplicates, and so the
    /// owner stays the creator of the record they later edit when awarding. Returns the remote id so it
    /// can be cached locally, or nil if the write didn't reach the server.
    func publishRequest(bookingID: String,
                        sessionDate: String,
                        sessionTime: String,
                        sessionDuration: String,
                        sessionType: String,
                        windowStart: Date,
                        windowEnd: Date) async -> String? {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: "coverage-\(bookingID)")
        let record = (try? await database.record(for: id))
            ?? CKRecord(recordType: Self.requestRecordType, recordID: id)
        // The requester is the instructor on the booking being covered — copied off `SessionBooking`
        // the same way `BookingService.respond` copies the student off a booking, rather than trusting
        // a caller-supplied id. Only written when the lookup succeeds, so a failed fetch on a re-publish
        // can't blank a `requesterID` already there.
        if let requesterID = await requesterID(forBooking: bookingID) {
            record["requesterID"] = requesterID
        }
        record["bookingID"] = bookingID
        record["sessionDate"] = sessionDate
        record["sessionTime"] = sessionTime
        record["sessionDuration"] = sessionDuration
        record["sessionType"] = sessionType
        record["windowStart"] = windowStart
        record["windowEnd"] = windowEnd
        record["status"] = 0
        // Only stamped on first creation, so a refresh keeps the original open time; and `filledByID`
        // is deliberately left untouched here so re-publishing an already-awarded request can't blank a
        // winner already recorded.
        if record["createdAt"] == nil { record["createdAt"] = Date() }
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

    /// Auto-fan one addressed offer per ranked candidate. Each recordName is derived from booking +
    /// candidate so re-fanning is idempotent rather than duplicating, and each offer carries only the
    /// booking reference and coarse session facts — never a student identifier or any location.
    func fanOutOffers(bookingID: String,
                      requesterID: String,
                      candidateIDs: [String],
                      sessionType: String,
                      sessionDate: String) async {
        #if CLOUDKIT_ENABLED
        for candidateID in candidateIDs {
            let id = CKRecord.ID(recordName: "offer-\(bookingID)-\(candidateID)")
            let record = (try? await database.record(for: id))
                ?? CKRecord(recordType: Self.offerRecordType, recordID: id)
            record["candidateID"] = candidateID
            record["requesterID"] = requesterID
            record["bookingID"] = bookingID
            record["sessionType"] = sessionType
            record["sessionDate"] = sessionDate
            if record["createdAt"] == nil { record["createdAt"] = Date() }
            _ = try? await database.save(record)
        }
        #endif
    }

    /// Award one claimant by flipping this request's `filledByID` (and marking it filled). The owner
    /// created the request, so editing it is workable under `_creator`-write; addressing the record to
    /// the winner is also what lets the "you were picked" subscription fire. Returns whether the change
    /// reached the server.
    @discardableResult
    func award(bookingID: String, replacerID: String) async -> Bool {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: "coverage-\(bookingID)")
        guard let record = try? await database.record(for: id) else { return false }
        record["filledByID"] = replacerID
        record["status"] = 1
        do {
            _ = try await database.save(record)
            return true
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Last-writer-wins: take the server record, re-apply just the award, retry once.
            if let server = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                server["filledByID"] = replacerID
                server["status"] = 1
                return (try? await database.save(server)) != nil
            }
            return false
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    /// Cancel an open coverage request — flip status to cancelled (2) and clear any winner, on the record
    /// the owner already wrote (`_creator`-write). The request row is kept (not deleted) so a candidate
    /// resolving `swapConfirmed` reads a definite cancelled state rather than a vanished record. Pair with
    /// `withdrawOffers` to actually remove it from candidates' inboxes. Returns whether it reached the server.
    @discardableResult
    func cancelRequest(bookingID: String) async -> Bool {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: "coverage-\(bookingID)")
        guard let record = try? await database.record(for: id) else { return false }
        record["status"] = 2
        record["filledByID"] = ""
        return (try? await database.save(record)) != nil
        #else
        return false
        #endif
    }

    /// Withdraw every offer fanned out for a booking — the "cancel the swap I sent the other instructors"
    /// half. Deletes the offer records (queried by `bookingID`, which is QUERYABLE) so they leave every
    /// candidate's inbox. The owner created each offer, so `_creator`-write permits the delete.
    func withdrawOffers(bookingID: String) async {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.offerRecordType,
                            predicate: NSPredicate(format: "bookingID == %@", bookingID))
        guard let (matches, _) = try? await database.records(
            matching: query, desiredKeys: [], resultsLimit: Self.fetchLimit
        ) else { return }
        for (recordID, _) in matches {
            _ = try? await database.deleteRecord(withID: recordID)
        }
        #endif
    }

    /// Publish the student-facing cover record for a booking, addressed to the student by `studentID`.
    /// The recordName is derived from the booking so a re-award updates rather than duplicates. This is
    /// the only place a student identifier touches a Coverage* record, and only because the record is
    /// news for that student. Returns whether the write reached the server.
    @discardableResult
    func publishCoverSession(bookingID: String,
                             studentID: String,
                             coveringInstructorID: String,
                             coveringInstructorName: String,
                             requesterID: String) async -> Bool {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: "coverSession-\(bookingID)")
        let record = (try? await database.record(for: id))
            ?? CKRecord(recordType: Self.sessionRecordType, recordID: id)
        record["studentID"] = studentID
        record["coveringInstructorID"] = coveringInstructorID
        record["coveringInstructorName"] = coveringInstructorName
        record["requesterID"] = requesterID
        record["status"] = 0
        if record["createdAt"] == nil { record["createdAt"] = Date() }
        return (try? await database.save(record)) != nil
        #else
        return false
        #endif
    }

    /// Mark a cover as cancelled (the covered session fell through). Flips status on the record the
    /// owner already wrote rather than deleting it, so the student's card can reflect the change.
    /// Returns whether the change reached the server.
    @discardableResult
    func cancelCoverSession(bookingID: String) async -> Bool {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: "coverSession-\(bookingID)")
        guard let record = try? await database.record(for: id) else { return false }
        record["status"] = 1
        return (try? await database.save(record)) != nil
        #else
        return false
        #endif
    }

    // MARK: - Candidate writes

    /// A candidate's response to an offer. Written as the candidate's *own* record (recordName derived
    /// from booking + replacer so claiming twice updates rather than duplicates), which keeps the
    /// default `_creator`-write security workable. `accepted == true` is the candidate's half of the
    /// two-sided approval. Addressed back to the owner via `requesterID` so their subscription fires.
    /// Returns whether the claim reached the server.
    @discardableResult
    func claim(bookingID: String,
               replacerID: String,
               replacerName: String,
               requesterID: String,
               accepted: Bool) async -> Bool {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: "claim-\(bookingID)-\(replacerID)")
        let record = (try? await database.record(for: id))
            ?? CKRecord(recordType: Self.claimRecordType, recordID: id)
        record["requesterID"] = requesterID
        record["replacerID"] = replacerID
        record["bookingID"] = bookingID
        record["replacerName"] = replacerName
        record["accepted"] = accepted ? 1 : 0
        record["claimedAt"] = Date()
        return (try? await database.save(record)) != nil
        #else
        return false
        #endif
    }

    // MARK: - Booking lookup

    #if CLOUDKIT_ENABLED
    /// The instructor on a booking — the person stepping out of studio, hence the coverage requester.
    /// Read off the student-written `SessionBooking` so the id is authoritative rather than caller-
    /// supplied; nil when the booking can't be read, which is not fatal to the request.
    private func requesterID(forBooking bookingID: String) async -> String? {
        let record = try? await database.record(for: CKRecord.ID(recordName: bookingID))
        return record?["instructorID"] as? String
    }
    #endif

    // MARK: - Reads

    /// Offers addressed to a candidate. Nil when the query itself failed (offline / schema not deployed)
    /// — distinct from an empty array, which means "genuinely no offers".
    func fetchOffers(candidateID: String) async -> [RemoteCoverageOffer]? {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.offerRecordType,
                            predicate: NSPredicate(format: "candidateID == %@", candidateID))
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        do {
            let (matches, _) = try await database.records(
                matching: query, desiredKeys: nil, resultsLimit: Self.fetchLimit
            )
            return matches.compactMap { try? $0.1.get() }.compactMap(RemoteCoverageOffer.init)
        } catch {
            return nil   // query failed — NOT "no offers"
        }
        #else
        return nil
        #endif
    }

    /// Coverage requests an owner has opened. Nil when the query failed; empty when there are none.
    func fetchMyRequests(requesterID: String) async -> [RemoteCoverageRequest]? {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.requestRecordType,
                            predicate: NSPredicate(format: "requesterID == %@", requesterID))
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        do {
            let (matches, _) = try await database.records(
                matching: query, desiredKeys: nil, resultsLimit: Self.fetchLimit
            )
            return matches.compactMap { try? $0.1.get() }.compactMap(RemoteCoverageRequest.init)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// A single coverage request read by its deterministic recordName. Nil when it doesn't exist or the
    /// point read failed. Used by candidates to resolve `swapConfirmed` — reading whether the owner has
    /// flipped `filledByID` to them.
    func fetchRequest(bookingID: String) async -> RemoteCoverageRequest? {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: "coverage-\(bookingID)")
        guard let record = try? await database.record(for: id) else { return nil }
        return RemoteCoverageRequest(record: record)
        #else
        return nil
        #endif
    }

    /// Claims addressed to an owner (their picker inbox). Nil when the query failed; empty when none.
    func fetchClaims(requesterID: String) async -> [RemoteCoverageClaim]? {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.claimRecordType,
                            predicate: NSPredicate(format: "requesterID == %@", requesterID))
        query.sortDescriptors = [NSSortDescriptor(key: "claimedAt", ascending: false)]
        do {
            let (matches, _) = try await database.records(
                matching: query, desiredKeys: nil, resultsLimit: Self.fetchLimit
            )
            return matches.compactMap { try? $0.1.get() }.compactMap(RemoteCoverageClaim.init)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// The student-facing cover record for a booking, read by its deterministic recordName. Nil when the
    /// session isn't covered or the point read failed.
    func fetchCoverSession(bookingID: String) async -> RemoteCoverageSession? {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: "coverSession-\(bookingID)")
        guard let record = try? await database.record(for: id) else { return nil }
        return RemoteCoverageSession(record: record)
        #else
        return nil
        #endif
    }
}
