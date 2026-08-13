import Foundation
import CloudKit

/// A community event as it exists in the shared public store (plain DTO decoded from a CKRecord).
/// The event BODY stays on public CloudKit — it is organizer-authored and legitimately world-readable,
/// exactly like the instructor catalog. Only the ATTENDEE identity (registrations/decisions) moves
/// behind the authz backend, because "who's going" is a relationship-graph deanonymization leak.
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

/// One student's registration for one event. There is no count field — the attendee count *is* how
/// many of these an event has. Now decoded from the authz backend rather than a world-readable record.
struct RemoteRegistration {
    let eventID: String
    let studentID: String
    let studentName: String
    /// When the registration was created — the backend's unforgeable server timestamp, used to resolve
    /// admission seniority when an event is oversubscribed (`admitted`).
    let joinedAt: Date

    init(eventID: String, studentID: String, studentName: String, joinedAt: Date) {
        self.eventID = eventID
        self.studentID = studentID
        self.studentName = studentName
        self.joinedAt = joinedAt
    }
}

/// An organizer's accept/decline for one student's event request. Now the `accepted` column on the
/// backend registration row (collapsed), surfaced as this DTO so the existing merge is unchanged.
struct RemoteEventDecision {
    let eventID: String
    let studentID: String
    let accepted: Bool
    let respondedAt: Date

    init(eventID: String, studentID: String, accepted: Bool, respondedAt: Date) {
        self.eventID = eventID
        self.studentID = studentID
        self.accepted = accepted
        self.respondedAt = respondedAt
    }
}

/// Community events. **Hybrid:** the event BODY (`CommunityEvent` + highlight photo) stays on public
/// CloudKit (organizer-authored, legitimately public). The ATTENDEE identity — registrations and the
/// organizer's decisions — moves behind the per-request authz backend (via [[FloweBackendClient]]),
/// which returns "who's going" ONLY to entitled callers (the organizer, or a community-visible viewer
/// seeing community-visible attendees), closing the EventRegistration/EventDecision deanonymization
/// leak. The organizer registers their event's authoritative organizer with the backend so it can
/// authorize roster reads + decisions. See [[BookingBackend]] / flowe-booking-privacy-deferred.
@MainActor
final class EventService {
    static let eventRecordType = "CommunityEvent"
    static let registrationRecordType = "EventRegistration"

    /// Legacy: the field a CloudKit registration named the person to alert by. Kept for the
    /// AccountDeletionService CloudKit sweep of any pre-cutover records.
    static let joinTargetField = "joinTargetID"

    /// How many upcoming events are worth carrying on a phone.
    private static let eventLimit = 100

    /// How many highlight photos one sync will pull.
    private static let imagesPerSync = 12

    /// Everything on an event *except* the highlight photo (the list query asks for exactly these).
    private static let eventMetadataKeys = [
        "organizerID", "organizerName", "title", "about", "location", "startsAt",
        "durationMinutes", "capacity", "price", "cancelled", "hasHighlight",
        "createdAt", "updatedAt",
    ]

    static let decisionRecordType = "EventDecision"
    static let decisionRecipientField = "studentID"
    static func registrationRecordName(eventID: String, studentID: String) -> String { "reg-\(eventID)-\(studentID)" }
    static func decisionRecordName(eventID: String, studentID: String) -> String { "evdec-\(eventID)-\(studentID)" }

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    private let backend = FloweBackendClient.shared

    /// Decisions + authoritative accepted-counts captured during the most recent `fetchRegistrations`,
    /// so the immediately-following `fetchEventDecisions` / count read need no second round-trip.
    private var lastEventDecisions: [RemoteEventDecision] = []
    private var lastEventCounts: [String: Int] = [:]

    // MARK: - Events (BODY — stays on public CloudKit)

    /// Create, edit or cancel an event — one deterministic CloudKit upsert. Also registers the event's
    /// AUTHORITATIVE organizer with the backend so roster reads + decisions can be authorized there.
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
        let recordName = "event-\(localID.uuidString)"
        // Register the AUTHORITATIVE organizer with the backend BEFORE publishing to CloudKit. The event
        // id is an unguessable UUID until published, so this makes the real organizer the first (and,
        // with the backend's first-writer-wins, permanent) owner — no one can hijack the roster authz.
        await ensureEventOwner(eventID: recordName)
        let id = CKRecord.ID(recordName: recordName)
        let record = (try? await database.record(for: id)) ?? CKRecord(recordType: Self.eventRecordType, recordID: id)

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
            guard let server = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord else {
                return nil
            }
            Self.apply(
                to: server, organizerID: organizerID, organizerName: organizerName, title: title,
                about: about, location: location, startsAt: startsAt, durationMinutes: durationMinutes,
                capacity: capacity, price: price, cancelled: cancelled, createdAt: createdAt, staged: staged
            )
            guard let saved = try? await database.save(server) else { return nil }
            return saved.recordID.recordName
        } catch {
            return nil   // offline / not signed into iCloud / schema not deployed
        }
        #else
        return nil
        #endif
    }

    /// Delete an event: cascade its backend registrations, then remove the CloudKit body.
    func deleteEvent(id: String) async -> Bool {
        await deleteEventOwner(eventID: id)
        #if CLOUDKIT_ENABLED
        return await delete(CKRecord.ID(recordName: id))
        #else
        return false
        #endif
    }

    /// The soonest upcoming events. Nil when the query failed (offline / schema not deployed).
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

    /// An organizer's own events, newest first and with no time bound.
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
                  let data = try? Data(contentsOf: url) else { continue }
            images[id.recordName] = data
        }
        return images
        #else
        return [:]
        #endif
    }

    // MARK: - Registrations / decisions (ATTENDEE identity — BACKEND, authz'd)

    /// Register the organizer's own event with the backend so it can authorize roster reads + decisions
    /// (organizer = the authenticated caller). Idempotent; called on event create/edit. Returns whether
    /// it reached the server, so the caller can register once per session rather than every reconcile.
    @discardableResult
    func ensureEventOwner(eventID: String) async -> Bool {
        struct Body: Encodable { let eventID: String }
        do {
            _ = try await backend.authorized("/events", method: "POST", body: Body(eventID: eventID))
            return true
        } catch {
            return false
        }
    }

    private func deleteEventOwner(eventID: String) async {
        _ = try? await backend.authorized("/events/\(eventID)", method: "DELETE")
    }

    /// Add or remove this student's registration (student = the authenticated caller). Join = POST,
    /// leave = DELETE; both idempotent. `studentID`/`organizerID` are advisory — the backend files the
    /// row under the verified token and looks the organizer up from the `events` table.
    @discardableResult
    func setRegistration(_ joined: Bool,
                         eventID: String,
                         studentID: String,
                         studentName: String,
                         eventTitle: String,
                         organizerID: String) async -> Bool {
        do {
            if joined {
                struct Body: Encodable { let studentName: String }
                _ = try await backend.authorized("/events/\(eventID)/register", method: "POST", body: Body(studentName: studentName), interactive: true)
            } else {
                _ = try await backend.authorized("/events/\(eventID)/register", method: "DELETE", interactive: true)
            }
            return true
        } catch {
            return false
        }
    }

    /// Organizer answers ONE student's request. The backend verifies the caller organizes the event.
    func setEventDecision(accepted: Bool, eventID: String, studentID: String, organizerID: String) async -> Bool {
        struct Body: Encodable { let studentID: String; let accepted: Bool }
        do {
            _ = try await backend.authorized("/events/\(eventID)/decision", method: "POST", body: Body(studentID: studentID, accepted: accepted), interactive: true)
            return true
        } catch {
            return false
        }
    }

    /// Registrations for the given events, SCOPED server-side (see the backend `/events/registrations`):
    /// the organizer gets their full queue; a viewer gets their own row + community-visible accepted
    /// attendees only if they are themselves community-visible. Caches the inline decisions and the
    /// server-authoritative accepted counts for the immediately-following reads. Nil = request failed.
    func fetchRegistrations(eventIDs: [String]) async -> [RemoteRegistration]? {
        guard !eventIDs.isEmpty else { return [] }
        struct Body: Encodable { let eventIDs: [String] }
        do {
            let data = try await backend.authorized("/events/registrations", method: "POST", body: Body(eventIDs: eventIDs))
            struct Resp: Decodable { let registrations: [WireRegistration]; let counts: [String: Int] }
            let resp = try JSONDecoder.eventSnakeCase.decode(Resp.self, from: data)
            lastEventCounts = resp.counts
            lastEventDecisions = resp.registrations.compactMap { $0.decision }
            return resp.registrations.map(\.registration)
        } catch {
            return nil   // request failed — NOT "nobody joined"
        }
    }

    /// Decisions for the given events — derived from the inline `accepted` captured by the
    /// immediately-preceding `fetchRegistrations` (reconcileAttendance always calls them in that order).
    func fetchEventDecisions(eventIDs: [String]) async -> [RemoteEventDecision]? {
        let wanted = Set(eventIDs)
        return lastEventDecisions.filter { wanted.contains($0.eventID) }
    }

    /// The server-authoritative ACCEPTED count for an event (includes attendees whose names are
    /// withheld), from the last `fetchRegistrations`. nil if that event wasn't in the last fetch.
    func acceptedCount(forEventID eventID: String) -> Int? { lastEventCounts[eventID] }

    /// Who is actually admitted when registrations exceed capacity — the shared, pure seniority rule.
    /// `capacity <= 0` → everyone; otherwise the first `capacity` by `(joinedAt asc, studentID asc)`.
    nonisolated static func admitted(_ rows: [RemoteRegistration], capacity: Int) -> Set<String> {
        guard capacity > 0 else { return Set(rows.map(\.studentID)) }
        let ordered = rows.sorted {
            $0.joinedAt != $1.joinedAt ? $0.joinedAt < $1.joinedAt : $0.studentID < $1.studentID
        }
        return Set(ordered.prefix(capacity).map(\.studentID))
    }

    // MARK: - CloudKit event-body plumbing

    #if CLOUDKIT_ENABLED
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
        record["price"] = price
        record["cancelled"] = cancelled ? 1 : 0
        record["createdAt"] = createdAt
        record["updatedAt"] = Date()
        record["highlight"] = staged.map { CKAsset(fileURL: $0) }
        record["hasHighlight"] = staged == nil ? 0 : 1
    }

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

// MARK: - Wire decoding

private struct WireRegistration: Decodable {
    let eventId: String
    let studentId: String
    let studentName: String
    let accepted: Int?
    let createdAt: Double

    var registration: RemoteRegistration {
        RemoteRegistration(eventID: eventId, studentID: studentId, studentName: studentName,
                           joinedAt: Date(eventMsEpoch: createdAt))
    }
    var decision: RemoteEventDecision? {
        guard let accepted else { return nil }
        return RemoteEventDecision(eventID: eventId, studentID: studentId, accepted: accepted == 1,
                                   respondedAt: Date(eventMsEpoch: createdAt))
    }
}

private extension JSONDecoder {
    static var eventSnakeCase: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

private extension Date {
    init(eventMsEpoch ms: Double) { self.init(timeIntervalSince1970: ms / 1000) }
}
