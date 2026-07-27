import Foundation
import SwiftData

/// A lesson type's cancellation / no-show policy. Off-app by design: Flowe TRACKS the fee owed for the
/// instructor to collect directly, it never charges anything. `windowHours == 0` means no policy.
struct CancellationPolicy: Hashable {
    var windowHours: Int = 0
    var fee: Int = 0
    var feeIsPercent: Bool = false

    /// A policy only bites if there's both a notice window and a fee.
    var isActive: Bool { windowHours > 0 && fee > 0 }

    /// The fee owed for a session priced at `sessionPrice`. A percent policy scales with the price; a
    /// flat fee ignores it. Rounded to whole currency units.
    func amount(sessionPrice: Int) -> Int {
        guard isActive else { return 0 }
        return feeIsPercent ? Int((Double(sessionPrice) * Double(fee) / 100).rounded()) : fee
    }
}

/// A rich, instructor-authored lesson type — "Sunrise Reformer", "Prenatal Mat", "Rehab 1-on-1".
///
/// This replaces the old flat `Instructor.sessionTypes: [String]` chip list, where every instructor
/// ticked the same fixed menu (`Private`/`Duet`/`Group`/`Online`). Now each type is a free-form
/// object the instructor creates from scratch: a name they type, an optional highlight photo, a
/// description, an optional duration and price, and a max group size.
///
/// Like `CommunityEvent`, the body lives in the shared **public** database (see `LessonTypeService`)
/// and this `@Model` is the offline cache in the **UserData** configuration. SwiftData mirrors
/// `UserData` to the CloudKit *private* database, which is per-iCloud-account, so a type one
/// instructor authored could never reach a student that way: the record travels the public database
/// as raw `CKRecord`, and this row caches it. It lives in UserData (not the local-only `Reference`
/// config that `Instructor` uses) for exactly that reason — a reader's cache of a public record must
/// mirror the private DB, precisely as `CommunityEvent` does.
///
/// The recordName is derived deterministically from `localID` (`lessontype-<localID>`), so a
/// re-publish overwrites the *same* record instead of forking a duplicate. See `LessonTypeService.upsert`.
///
/// ## Capacity is displayed group size, not a live gauge
///
/// A Flowe `Booking` is a 1:1 *request* keyed to `instructorId + date + time + type` strings — there
/// is no scheduled shared session instance a lesson type could fill, and no registration record for
/// one. So `capacity` here is a static descriptive attribute (max group size, "Up to 10"), never a
/// "spots left / fully booked" gauge: a spots-remaining number would be state nobody ever counted.
/// That is why there is deliberately no `EventStatus` / `spotsLeft` / `attendees` analog here — those
/// exist on `CommunityEvent` only because `EventRegistration` records give it a real live count.
@Model
final class LessonType {
    // MARK: Identity
    var legacyId: Int = 0                 // local list id + accessibilityIdentifier suffix
    /// Minted at insert; the public recordName is "lessontype-<localID>". This is what makes a
    /// re-publish (from a killed upload, or from a second device that received the row via the private
    /// mirror) overwrite one record instead of creating a duplicate type.
    var localID: UUID = UUID()
    /// The delivered recordName; equals "lessontype-<localID>" once the server confirms. Nil for the
    /// whole publish round-trip, so it must never be read as "never published".
    var remoteID: String? = nil
    var createdAt: Date = Date.distantPast
    /// Last-writer-wins stamp used by the edit-conflict retry in `LessonTypeService.upsert`.
    var updatedAt: Date = Date.distantPast

    // MARK: Owner (query key)
    /// The authoring instructor's AppSession owner id (Apple credential id, the same identity as
    /// `CommunityEvent.organizerID` — never `currentUser.id`). A student fetches one instructor's
    /// types by this field; it is the single field a row cannot be attributed without.
    var ownerID: String? = nil

    // MARK: Content (instructor-written; travels on the record)
    /// Free-form user text ("Sunrise Reformer"). Rendered verbatim, never localized.
    var name: String = ""
    var details: String = ""
    /// 0 means "not stated" → the duration line is omitted; a stated value also replaces the
    /// `type == "Private" ? 55 : 50` heuristic in `MockDataStore.addBooking`.
    var durationMinutes: Int = 0
    /// Max GROUP SIZE. 0 means "not stated" → the capacity line is omitted (a migrated bare legacy
    /// name never had a size). 1 renders "1-on-1"; ≥2 renders "Up to N". Never a live availability count.
    var capacity: Int = 0
    /// nil == not stated (line omitted), 0 == genuinely Free, n == money(n). nil and 0 are different
    /// real states, so this stays optional rather than collapsing "not stated" into a fabricated 0 —
    /// the identical rule to `CommunityEvent.price`.
    var price: Int? = nil
    /// Explicit instructor-controlled display order, published so students see the same order. Replaces
    /// the fixed canonical-list ordering the deleted `["Private","Duet","Group","Online"]` menu gave.
    var order: Int = 0

    // MARK: No-Show Shield policy (PUBLISHED — the student sees it before booking)
    /// Hours of notice required to cancel without a fee. 0 = no cancellation policy at all.
    var cancelWindowHours: Int = 0
    /// The late-cancel / no-show fee. A percent (0–100) of the session price when `cancelFeeIsPercent`,
    /// otherwise a flat currency amount. 0 = no fee. Off-app: Flowe only TRACKS what's owed.
    var cancelFee: Int = 0
    /// Whether `cancelFee` is a percentage of the session price (true) or a flat amount (false).
    var cancelFeeIsPercent: Bool = false

    /// The resolved policy value used by both the student-facing display and the fee ledger.
    var cancellationPolicy: CancellationPolicy {
        CancellationPolicy(windowHours: cancelWindowHours, fee: cancelFee, feeIsPercent: cancelFeeIsPercent)
    }

    // MARK: Highlight photo
    @Attribute(.externalStorage) var highlight: Data?
    /// Whether the shared record carries a photo, known without downloading it — set from whether the
    /// asset actually staged, never from `highlight != nil`. Lets a row tell "no photo" apart from
    /// "photo not fetched yet", exactly like `CommunityEvent.hasHighlight`.
    var hasHighlight: Bool = false

    // MARK: Delivery state (set BEFORE the network call, cleared only on confirmed delivery)
    /// Create AND edit — every instructor-owned field write. There is deliberately NO reader-only
    /// state (no join/attendee analog): a lesson type is 100% descriptive and publishes every field.
    var pendingUpload: Bool = false
    var pendingDelete: Bool = false

    init(
        legacyId: Int = 0,
        localID: UUID = UUID(),
        remoteID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date.distantPast,
        ownerID: String? = nil,
        name: String = "",
        details: String = "",
        durationMinutes: Int = 0,
        capacity: Int = 0,
        price: Int? = nil,
        order: Int = 0,
        cancelWindowHours: Int = 0,
        cancelFee: Int = 0,
        cancelFeeIsPercent: Bool = false,
        highlight: Data? = nil,
        hasHighlight: Bool = false,
        pendingUpload: Bool = false,
        pendingDelete: Bool = false
    ) {
        self.legacyId = legacyId
        self.localID = localID
        self.remoteID = remoteID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.ownerID = ownerID
        self.name = name
        self.details = details
        self.durationMinutes = durationMinutes
        self.capacity = capacity
        self.price = price
        self.order = order
        self.cancelWindowHours = cancelWindowHours
        self.cancelFee = cancelFee
        self.cancelFeeIsPercent = cancelFeeIsPercent
        self.highlight = highlight
        self.hasHighlight = hasHighlight
        self.pendingUpload = pendingUpload
        self.pendingDelete = pendingDelete
    }
}

/// The single render currency both student surfaces (the OFFERS card and the booking-type picker)
/// consume, so one card renderer degrades per-field: a rich authored type maps to a full card, while
/// a legacy name-only offer maps to a clean minimal card via `init(name:)`.
///
/// A value struct, not the `@Model` — it flattens whichever source the resolver had (owned
/// `LessonType` rows, or the denormalized `Instructor.sessionTypes` name cache) into one shape, so no
/// view ever touches a persisted row or has to know which source produced it.
struct ResolvedLessonType: Identifiable, Hashable {
    /// Stable, unique per resolved value — a `UUID` rather than `legacyId` because several name-only
    /// fallbacks all carry `legacyId == 0`, which would collide as a `ForEach` id.
    let id: UUID
    /// The authored row's list id, for `lessonType.card.<legacyId>` accessibility ids. 0 for a
    /// name-only fallback, where the view falls back to the array index instead.
    let legacyId: Int
    let name: String
    let details: String
    let durationMinutes: Int
    let capacity: Int
    let price: Int?
    /// The cancellation policy, so the booking flow can show it to the student before they commit.
    let cancellationPolicy: CancellationPolicy
    /// Whether a photo exists to show (from the row's `hasHighlight`), so the card can reserve the
    /// photo band before the asset itself has been fetched.
    let hasPhoto: Bool
    let photo: Data?

    init(
        id: UUID = UUID(),
        legacyId: Int = 0,
        name: String,
        details: String = "",
        durationMinutes: Int = 0,
        capacity: Int = 0,
        price: Int? = nil,
        cancellationPolicy: CancellationPolicy = CancellationPolicy(),
        hasPhoto: Bool = false,
        photo: Data? = nil
    ) {
        self.id = id
        self.legacyId = legacyId
        self.name = name
        self.details = details
        self.durationMinutes = durationMinutes
        self.capacity = capacity
        self.price = price
        self.cancellationPolicy = cancellationPolicy
        self.hasPhoto = hasPhoto
        self.photo = photo
    }
}
