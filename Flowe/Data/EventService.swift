import Foundation
import CloudKit

/// A community event as it exists in the shared public store (plain DTO decoded from a CKRecord).
struct RemoteEvent {
    let id: String
    let organizerID: String
    let organizerName: String
    let title: String
    let about: String
    let location: String
    let startsAt: Date
    let durationMinutes: Int
    let capacity: Int
    /// Kept optional — a record with no `price` key is "not stated" (nil), a `0` is genuinely free.
    let price: Int?
    let cancelled: Bool
    /// Whether the record carries a highlight photo, known from the metadata query, which does not
    /// download the asset itself — see `EventService.eventMetadataKeys`.
    let hasHighlight: Bool
    let createdAt: Date
    /// Carried so the conflict retry and the merge can resolve last-writer-wins.
    let updatedAt: Date

    init?(record: CKRecord) {
        // `organizerID` is the one field an event cannot be rendered without — everything else has a
        // safe default. Its absence means a record we can't attribute, so it is dropped.
        guard let organizerID = record["organizerID"] as? String else { return nil }
        id = record.recordID.recordName
        self.organizerID = organizerID
        organizerName = record["organizerName"] as? String ?? ""
        title = record["title"] as? String ?? ""
        about = record["about"] as? String ?? ""
        location = record["location"] as? String ?? ""
        startsAt = record["startsAt"] as? Date ?? .distantPast
        durationMinutes = record["durationMinutes"] as? Int ?? 60
        capacity = record["capacity"] as? Int ?? 0
        // `as? Int` on a missing key yields nil — exactly the "not stated" state we want to keep.
        price = record["price"] as? Int
        cancelled = (record["cancelled"] as? Int ?? 0) == 1
        hasHighlight = (record["hasHighlight"] as? Int ?? 0) == 1
        createdAt = record["createdAt"] as? Date ?? .distantPast
        updatedAt = record["updatedAt"] as? Date ?? .distantPast
    }
}

/// One student's registration for one event. There is no count field anywhere — the attendee count
/// *is* how many of these an event has (see the note on `EventService`).
struct RemoteRegistration {
    let eventID: String
    let studentID: String
    let studentName: String

    /// When the registration was created, used to resolve seniority when an event is oversubscribed.
    ///
    /// The record's server-assigned `creationDate` is preferred — it is unforgeable, so a device
    /// with a wrong clock can change *who* wins a race but cannot make two devices *disagree* about
    /// who won. The `createdAt` field is only a fallback, and `.distantFuture` (loses every
    /// tie-break) is the last resort so a record that somehow carries neither can never displace a
    /// genuine earlier joiner.
    let joinedAt: Date

    init?(record: CKRecord) {
        guard let eventID = record["eventID"] as? String,
              let studentID = record["studentID"] as? String else { return nil }
        self.eventID = eventID
        self.studentID = studentID
        studentName = record["studentName"] as? String ?? ""
        joinedAt = record.creationDate ?? record["createdAt"] as? Date ?? .distantFuture
    }
}

/// An organizer's accept/decline for one student's event request. Written by the ORGANIZER — the
/// student can't change their own registration's status (creator-write), so the answer is a separate
/// creator-owned record, exactly like `SessionDecision` answers a `SessionBooking`. Deterministic
/// recordName → one decision per (event, student), upserted on re-answer.
struct RemoteEventDecision {
    let eventID: String
    let studentID: String
    let accepted: Bool
    let respondedAt: Date

    init?(record: CKRecord) {
        guard let eventID = record["eventID"] as? String,
              let studentID = record["studentID"] as? String else { return nil }
        self.eventID = eventID
        self.studentID = studentID
        accepted = (record["accepted"] as? Int ?? 0) == 1
        respondedAt = record["respondedAt"] as? Date ?? record.creationDate ?? .distantPast
    }
}

/// Community events over CloudKit's **public** database, shaped exactly like `CommunityService`:
/// an instructor-authored `CommunityEvent` record read by everyone, and an `EventRegistration`
/// record written by each student who joins. SwiftData can only mirror the *private* database, which
/// is per-iCloud-account, so an event one instructor writes could never reach a student that way.
///
/// ## Why a registration is a record and not a counter
///
/// A public-database record is writable only by whoever created it. An `attendees` integer on the
/// event could therefore only ever be changed by the event's *organizer* — every student's join
/// would be rejected by CloudKit, and a client that "optimistically" bumped a local copy would show
/// a number nobody else could see. So a registration is its own record, `reg-<eventID>-<studentID>`,
/// created by the student who joins and deleted when they leave. Every write stays inside the
/// writer's own row, and the attendee count is simply how many registration records an event has.
/// This is the same reasoning `CommunityLike` follows for likes.
///
/// The tradeoff is that capacity is **eventually consistent**: two students can both pass a
/// client-side capacity check and both write, oversubscribing by one, because there is no server and
/// no transaction. `admitted(_:capacity:)` resolves that deterministically after the fact — see it
/// and `BOOKING-SYSTEM.md § Known limitations`.
@MainActor
final class EventService {
    static let eventRecordType = "CommunityEvent"
    static let registrationRecordType = "EventRegistration"

    /// The field a registration names the person to alert by — the event's organizer, and empty
    /// when that is the joining student themselves. Shared with `PushService`; a rename here breaks
    /// the query and the notification together rather than one silently.
    static let joinTargetField = "joinTargetID"

    /// How many upcoming events are worth carrying on a phone. Also bounds the `IN` lists the
    /// registration query builds, which CloudKit rejects if they grow without limit.
    private static let eventLimit = 100
    private static let pageSize = 400
    /// CloudKit dislikes very large `IN` arrays, so registrations are fetched in slices.
    private static let idsPerQuery = 50

    /// How many highlight photos one sync will pull. Fewer than the feed's 24: an event hero is the
    /// whole subject of its row and the list is short, so a pass takes the newest slice and the next
    /// sync takes the rest.
    private static let imagesPerSync = 12

    /// Everything on an event *except* the highlight photo.
    ///
    /// The list query asks for exactly these. Passing `desiredKeys: nil` would download every
    /// attached `CKAsset` too — up to `eventLimit` photos on every refresh, most for rows the reader
    /// never scrolls to. Photos come afterwards from `fetchHighlights`, once, per event.
    private static let eventMetadataKeys = [
        "organizerID", "organizerName", "title", "about", "location", "startsAt",
        "durationMinutes", "capacity", "price", "cancelled", "hasHighlight",
        "createdAt", "updatedAt",
    ]

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    // MARK: - Events

    /// Create, edit or cancel an event — all one deterministic upsert, because the recordName is
    /// derived from `localID` and the organizer is always the record's creator.
    ///
    /// Fetch-then-mutate so an edit preserves fields it doesn't touch and a re-publish overwrites the
    /// same record rather than duplicating it. Returns the remote id, or nil if it didn't reach the
    /// server.
    func upsert(localID: UUID,
                organizerID: String,
                organizerName: String,
                title: String,
                about: String,
                location: String,
                startsAt: Date,
                durationMinutes: Int,
                capacity: Int,
                price: Int?,
                cancelled: Bool,
                createdAt: Date,
                highlight: Data?) async -> String? {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: "event-\(localID.uuidString)")
        let record = (try? await database.record(for: id)) ?? CKRecord(recordType: Self.eventRecordType, recordID: id)

        // A CKAsset uploads from a file, so the photo has to be staged on disk for the save. The
        // staged URL must outlive a possible conflict retry, so `defer` (fires on return) cleans up.
        let staged = highlight.flatMap { Self.stageAsset($0) }
        defer { staged.map { try? FileManager.default.removeItem(at: $0) } }

        Self.apply(
            to: record, organizerID: organizerID, organizerName: organizerName, title: title,
            about: about, location: location, startsAt: startsAt, durationMinutes: durationMinutes,
            capacity: capacity, price: price, cancelled: cancelled, createdAt: createdAt, staged: staged
        )

        do {
            let saved = try await database.save(record)
            return saved.recordID.recordName
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Last-writer-wins: take the server record, re-apply our fields onto it, retry once. The
            // staged file outlives this block (`defer` fires on return), so the retry can reuse it —
            // otherwise a conflicting save would silently drop the new photo.
            guard let server = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord else {
                return nil
            }
            Self.apply(
                to: server, organizerID: organizerID, organizerName: organizerName, title: title,
                about: about, location: location, startsAt: startsAt, durationMinutes: durationMinutes,
                capacity: capacity, price: price, cancelled: cancelled, createdAt: createdAt, staged: staged
            )
            let saved = try? await database.save(server)
            return saved?.recordID.recordName
        } catch {
            return nil   // offline / not signed into iCloud / schema not deployed
        }
        #else
        return nil
        #endif
    }

    /// Delete an event. Only its organizer can, enforced by the public database. Returns whether the
    /// event is now gone from the server.
    func deleteEvent(id: String) async -> Bool {
        #if CLOUDKIT_ENABLED
        return await delete(CKRecord.ID(recordName: id))
        #else
        return false
        #endif
    }

    /// The soonest upcoming events, earliest first. The caller passes `now − 6h` so a class that
    /// started an hour ago doesn't vanish while people are in it; ascending + limit keeps the
    /// *soonest* hundred rather than an arbitrary slice.
    /// Nil when the query failed (offline / schema not deployed) — distinct from an empty array, which
    /// means "genuinely no upcoming events".
    func fetchUpcoming(since: Date) async -> [RemoteEvent]? {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.eventRecordType,
                            predicate: NSPredicate(format: "startsAt >= %@", since as NSDate))
        query.sortDescriptors = [NSSortDescriptor(key: "startsAt", ascending: true)]
        do {
            let (matches, _) = try await database.records(
                matching: query, desiredKeys: Self.eventMetadataKeys, resultsLimit: Self.eventLimit
            )
            return matches.compactMap { try? $0.1.get() }.compactMap(RemoteEvent.init)
        } catch {
            return nil   // query failed — NOT "no events"
        }
        #else
        return nil
        #endif
    }

    /// An organizer's own events, newest first and with no time bound — an organizer keeps their
    /// past events.
    func fetchMine(organizerID: String) async -> [RemoteEvent] {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.eventRecordType,
                            predicate: NSPredicate(format: "organizerID == %@", organizerID))
        query.sortDescriptors = [NSSortDescriptor(key: "startsAt", ascending: false)]
        do {
            let (matches, _) = try await database.records(
                matching: query, desiredKeys: Self.eventMetadataKeys, resultsLimit: Self.eventLimit
            )
            return matches.compactMap { try? $0.1.get() }.compactMap(RemoteEvent.init)
        } catch {
            return []
        }
        #else
        return []
        #endif
    }

    /// Download the highlight photos for specific events, capped at `imagesPerSync`.
    ///
    /// Keyed by record name; an event whose fetch failed is simply absent, so the caller keeps
    /// whatever it already had rather than caching an empty image over a good one.
    func fetchHighlights(eventIDs: [String]) async -> [String: Data] {
        #if CLOUDKIT_ENABLED
        let wanted = Array(eventIDs.prefix(Self.imagesPerSync))
        guard !wanted.isEmpty else { return [:] }
        let ids = wanted.map { CKRecord.ID(recordName: $0) }
        guard let results = try? await database.records(for: ids, desiredKeys: ["highlight"]) else {
            return [:]
        }
        var images: [String: Data] = [:]
        for (id, result) in results {
            guard let record = try? result.get(),
                  let url = (record["highlight"] as? CKAsset)?.fileURL,
                  // Read now: CloudKit reclaims the staged copy once this scope ends.
                  let data = try? Data(contentsOf: url) else { continue }
            images[id.recordName] = data
        }
        return images
        #else
        return [:]
        #endif
    }

    // MARK: - Registrations

    /// Deterministic record name, so joining twice updates one row instead of inflating the count,
    /// and so the student stays the creator of the record they later delete.
    static func registrationRecordName(eventID: String, studentID: String) -> String {
        "reg-\(eventID)-\(studentID)"
    }

    static let decisionRecordType = "EventDecision"
    /// The recipient field a student's push predicate tests (`studentID == me`), mirroring bookings.
    static let decisionRecipientField = "studentID"
    static func decisionRecordName(eventID: String, studentID: String) -> String {
        "evdec-\(eventID)-\(studentID)"
    }

    /// Organizer answers ONE student's request. Upsert by deterministic recordName so a re-answer
    /// updates in place and the organizer stays the record's creator.
    func setEventDecision(accepted: Bool, eventID: String, studentID: String, organizerID: String) async -> Bool {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: Self.decisionRecordName(eventID: eventID, studentID: studentID))
        let record = (try? await database.record(for: id))
            ?? CKRecord(recordType: Self.decisionRecordType, recordID: id)
        record["eventID"] = eventID
        record["studentID"] = studentID          // recipient — powers the student's push predicate
        record["accepted"] = accepted ? 1 : 0
        record["organizerID"] = organizerID
        record["respondedAt"] = Date()
        return (try? await database.save(record)) != nil
        #else
        return false
        #endif
    }

    /// Every decision for the given events. nil = the query itself failed (≠ "no decisions").
    func fetchEventDecisions(eventIDs: [String]) async -> [RemoteEventDecision]? {
        #if CLOUDKIT_ENABLED
        let records = await fetchAll(recordType: Self.decisionRecordType, eventIDs: eventIDs)
        return records.map { $0.compactMap(RemoteEventDecision.init) }
        #else
        return nil
        #endif
    }

    /// Add or remove this student's registration. Returns whether the change reached the server.
    @discardableResult
    func setRegistration(_ joined: Bool,
                         eventID: String,
                         studentID: String,
                         studentName: String,
                         eventTitle: String,
                         organizerID: String) async -> Bool {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: Self.registrationRecordName(eventID: eventID, studentID: studentID))
        guard joined else { return await delete(id) }

        let record = CKRecord(recordType: Self.registrationRecordType, recordID: id)
        record["eventID"] = eventID
        record["studentID"] = studentID
        record["studentName"] = studentName
        record["eventTitle"] = eventTitle
        record["createdAt"] = Date()
        // Empty when the organizer joins their own event: a pure-equality push predicate
        // (`joinTargetID == me`) then matches nobody, so self-notification is prevented by the data
        // rather than by a `!=` clause, which query subscriptions handle far less reliably.
        record["joinTargetID"] = organizerID == studentID ? "" : organizerID

        // Overwrite rather than fetch-then-save: the record is keyed by (event, student), so a save
        // that collides with an existing row is this same student joining again, not a conflict.
        do {
            let (saves, _) = try await database.modifyRecords(
                saving: [record], deleting: [], savePolicy: .allKeys
            )
            // Per-record failures don't throw, so the operation succeeding isn't enough.
            return saves.values.allSatisfy { if case .success = $0 { return true } else { return false } }
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    /// Every registration for the given events. Returns nil when the query itself failed, which is
    /// different from "nobody joined anything" — returning `[]` would zero every count while offline.
    func fetchRegistrations(eventIDs: [String]) async -> [RemoteRegistration]? {
        #if CLOUDKIT_ENABLED
        let records = await fetchAll(recordType: Self.registrationRecordType, eventIDs: eventIDs)
        return records.map { $0.compactMap(RemoteRegistration.init) }
        #else
        return nil
        #endif
    }

    /// Who is actually admitted to an event when its registrations exceed its capacity — the shared,
    /// pure seniority rule, called by both the post-write re-check and the list sync so every device
    /// computes the same answer.
    ///
    /// `capacity <= 0` means no capacity was stated → everyone is admitted. Otherwise the first
    /// `capacity` students by `(joinedAt asc, studentID asc)` are in. The `studentID` tie-break makes
    /// it total, so two devices with identical rows can never disagree about who won the last spot.
    nonisolated static func admitted(_ rows: [RemoteRegistration], capacity: Int) -> Set<String> {
        guard capacity > 0 else { return Set(rows.map(\.studentID)) }
        let ordered = rows.sorted {
            $0.joinedAt != $1.joinedAt ? $0.joinedAt < $1.joinedAt : $0.studentID < $1.studentID
        }
        return Set(ordered.prefix(capacity).map(\.studentID))
    }

    // MARK: - Shared plumbing

    #if CLOUDKIT_ENABLED

    /// Registrations attached to any of `eventIDs`, in slices small enough for an `IN` predicate and
    /// following each slice's cursor so a popular event's tail isn't silently dropped.
    ///
    /// Nil on failure; an empty array means there genuinely are none.
    private func fetchAll(recordType: String, eventIDs: [String]) async -> [CKRecord]? {
        guard !eventIDs.isEmpty else { return [] }
        var records: [CKRecord] = []

        for start in stride(from: 0, to: eventIDs.count, by: Self.idsPerQuery) {
            let slice = Array(eventIDs[start..<min(start + Self.idsPerQuery, eventIDs.count)])
            let query = CKQuery(recordType: recordType,
                                predicate: NSPredicate(format: "eventID IN %@", slice))
            do {
                var page = try await database.records(
                    matching: query, desiredKeys: nil, resultsLimit: Self.pageSize
                )
                records += page.matchResults.compactMap { try? $0.1.get() }
                while let cursor = page.queryCursor {
                    page = try await database.records(
                        continuingMatchFrom: cursor, desiredKeys: nil, resultsLimit: Self.pageSize
                    )
                    records += page.matchResults.compactMap { try? $0.1.get() }
                }
            } catch {
                return nil
            }
        }
        return records
    }

    /// Write every organizer-owned field onto a record — shared by the create/edit save and the
    /// conflict retry so the two can never apply a different set. `hasHighlight` is derived from
    /// whether the photo actually staged, not from `highlight != nil`: a photo that failed to stage
    /// is an event without one, and claiming otherwise leaves every reader reserving space for an
    /// asset that will never arrive.
    private static func apply(to record: CKRecord,
                              organizerID: String,
                              organizerName: String,
                              title: String,
                              about: String,
                              location: String,
                              startsAt: Date,
                              durationMinutes: Int,
                              capacity: Int,
                              price: Int?,
                              cancelled: Bool,
                              createdAt: Date,
                              staged: URL?) {
        record["organizerID"] = organizerID
        record["organizerName"] = organizerName
        record["title"] = title
        record["about"] = about
        record["location"] = location
        record["startsAt"] = startsAt
        record["durationMinutes"] = durationMinutes
        record["capacity"] = capacity
        // Assigning nil removes the key, which is how "price not stated" reaches other devices; a
        // free event writes 0. CKRecord has no boolean, so `cancelled` is an Int.
        record["price"] = price
        record["cancelled"] = cancelled ? 1 : 0
        record["createdAt"] = createdAt
        record["updatedAt"] = Date()
        record["highlight"] = staged.map { CKAsset(fileURL: $0) }
        record["hasHighlight"] = staged == nil ? 0 : 1
    }

    /// Write image bytes to a temp file so `CKAsset` can upload them. Nil simply means this save
    /// carries no photo rather than failing the whole publish — the event is still worth creating.
    private static func stageAsset(_ data: Data) -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("event-highlight-\(UUID().uuidString).jpg")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// A record that is already absent is the goal state, not a failure — a leave sent twice, or an
    /// event deleted from another device.
    private func delete(_ id: CKRecord.ID) async -> Bool {
        do {
            _ = try await database.deleteRecord(withID: id)
            return true
        } catch let error as CKError where error.code == .unknownItem {
            return true
        } catch {
            return false
        }
    }

    #endif
}
