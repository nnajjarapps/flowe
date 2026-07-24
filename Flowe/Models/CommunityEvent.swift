import Foundation
import SwiftData

/// The five states an event can be in from a given reader's point of view. Computed, never stored,
/// so there is no CloudKit-legality question and no way for a stored copy to drift from the fields
/// it is derived from.
enum EventStatus: Equatable {
    case ended
    case cancelled
    case joined
    case full
    case open(spotsLeft: Int?)
}

/// A community event — an instructor-authored class, workshop or retreat that every student can see.
///
/// Like `FeedPost`, the body lives in the shared **public** database (see `EventService`) and this
/// `@Model` is the offline cache in the `UserData` configuration. SwiftData mirrors `UserData` to the
/// CloudKit *private* database, which is per-iCloud-account, so an event one instructor wrote could
/// never reach a student that way: the event record travels through the public database as raw
/// `CKRecord`, and this row caches it.
///
/// The one place events must diverge from `FeedPost`: `localID`. A `FeedPost` is minted server-side
/// and can duplicate if a publish is retried — survivable for a post. An event that duplicated would
/// split its attendee roster across two identical workshops, so its public recordName is derived
/// deterministically from `localID` (`event-<localID>`) and a re-publish overwrites the *same*
/// record. See `EventService.upsert`.
///
/// The attendee count is never a field on this record: a student cannot write the instructor's
/// record (public-DB `_creator`-write role), so the count *is* how many `EventRegistration` records
/// the event has — exactly the reasoning `CommunityLike` follows for likes.
@Model
final class CommunityEvent {
    // MARK: Identity
    var legacyId: Int = 0                 // local list id + accessibilityIdentifier suffix
    /// Minted at insert; the public recordName is "event-<localID>". This is what makes a re-publish
    /// (from a killed upload, or from a second device that received the row via the private mirror)
    /// overwrite one record instead of creating a duplicate event with a split roster.
    var localID: UUID = UUID()
    /// The delivered recordName; equals "event-<localID>" once the server confirms. Nil for the whole
    /// publish round-trip, so it must never be read as "never published".
    var remoteID: String?
    var createdAt: Date = Date.distantPast
    /// Last-writer-wins stamp used by the edit-conflict retry in `EventService.upsert`.
    var updatedAt: Date = Date.distantPast

    // MARK: Organizer (denormalised so the card renders offline and when the listing is hidden)
    var organizerID: String?             // AppSession owner id (Apple credential id, never currentUser.id)
    var organizerName: String = ""

    // MARK: Content (organizer-written; travels on the event record)
    var title: String = ""
    var about: String = ""
    /// Empty means the WHERE section is omitted — never rendered as "TBD".
    var location: String = ""
    var startsAt: Date = Date.distantPast
    var durationMinutes: Int = 60
    /// 0 means "no capacity stated" → the event is never full / unlimited. The composer requires ≥1.
    ///
    /// Kept as a non-optional `Int` (not `Int?`) so a decode failure of this required field defaults
    /// to 0 — the *safe* degradation. Defaulting a missing capacity to a full state would lock an
    /// event against everyone with no way to tell it apart from a genuinely full one.
    var capacity: Int = 0
    /// USD. nil == not stated (renders an em dash), 0 == genuinely free ("Free"), n == money(n).
    ///
    /// nil and 0 are different real states and must render differently, so this stays optional rather
    /// than collapsing "not stated" into a fabricated 0 — the instinct the codebase applies to nil
    /// ratings and optional locations.
    var price: Int? = nil
    var cancelled: Bool = false

    // MARK: Highlight photo
    @Attribute(.externalStorage) var highlight: Data?
    /// Whether the shared record carries a photo, known without downloading it — set from whether the
    /// asset actually staged, never from `highlight != nil`. Lets a row tell "no photo" apart from
    /// "photo not fetched yet", exactly like `FeedPost.hasImage`.
    var hasHighlight: Bool = false

    // MARK: This reader's own state — NEVER published on the event record
    var joined: Bool = false
    /// nil means no registration query has ever succeeded — which is NOT "nobody joined". A
    /// non-optional 0 would read "24 spots left" before anything was counted and would let an event
    /// be declared *not* full on evidence never gathered. Same rule as `fetchLikes` returning nil.
    var attendees: Int? = nil

    // MARK: Delivery state (set BEFORE the network call, cleared only on confirmed delivery)
    /// Create, edit AND cancel — every instructor-owned field write.
    var pendingUpload: Bool = false
    var pendingDelete: Bool = false
    /// Join AND leave — the desired state is `joined`, like `FeedPost.pendingLike`.
    var pendingJoin: Bool = false

    init(
        legacyId: Int = 0,
        localID: UUID = UUID(),
        remoteID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date.distantPast,
        organizerID: String? = nil,
        organizerName: String = "",
        title: String = "",
        about: String = "",
        location: String = "",
        startsAt: Date = Date.distantPast,
        durationMinutes: Int = 60,
        capacity: Int = 0,
        price: Int? = nil,
        cancelled: Bool = false,
        highlight: Data? = nil,
        hasHighlight: Bool = false,
        joined: Bool = false,
        attendees: Int? = nil,
        pendingUpload: Bool = false,
        pendingDelete: Bool = false,
        pendingJoin: Bool = false
    ) {
        self.legacyId = legacyId
        self.localID = localID
        self.remoteID = remoteID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.organizerID = organizerID
        self.organizerName = organizerName
        self.title = title
        self.about = about
        self.location = location
        self.startsAt = startsAt
        self.durationMinutes = durationMinutes
        self.capacity = capacity
        self.price = price
        self.cancelled = cancelled
        self.highlight = highlight
        self.hasHighlight = hasHighlight
        self.joined = joined
        self.attendees = attendees
        self.pendingUpload = pendingUpload
        self.pendingDelete = pendingDelete
        self.pendingJoin = pendingJoin
    }

    // MARK: Computed (no storage → no legality question)

    var endsAt: Date { startsAt.addingTimeInterval(TimeInterval(durationMinutes * 60)) }

    /// nil when we have not counted, OR when no capacity was stated — both are "unknown", and neither
    /// may be rendered as a number.
    var spotsLeft: Int? {
        guard capacity > 0, let attendees else { return nil }
        return max(0, capacity - attendees)
    }

    /// The ONLY thing anywhere that computes fullness — the card, the detail and the store all read
    /// this so they can never disagree.
    ///
    /// Precedence is the rule: `ended` first (a class that already happened cannot be joined);
    /// `cancelled` before `joined` (a joiner of a cancelled event sees "Cancelled", not "You're in");
    /// `joined` **before** `full` (a student who holds a spot never sees their own event greyed out —
    /// the single most common way this kind of screen looks broken).
    var status: EventStatus {
        if endsAt < Date() { return .ended }
        if cancelled { return .cancelled }
        if joined { return .joined }
        if let spotsLeft, spotsLeft == 0 { return .full }
        return .open(spotsLeft: spotsLeft)
    }
}
