import SwiftUI
import SwiftData
import Observation
import CoreLocation
import CloudKit

/// The identity to render for an authored record, resolved LIVE at display time from the author's
/// current public profile rather than the denormalised snapshot frozen onto the record at creation.
///
/// A student who posts before completing their profile, then fills in their name + photo, must have
/// every past post / comment / review / booking row show the new identity — the snapshot on those
/// records can never be edited by anyone but the author (and re-stamps itself from the remote each
/// sync), so display-time resolution is the only durable fix. See `MockDataStore.displayIdentity`.
///
/// `img` is an Unsplash id for instructor authors (empty for students, who carry an uploaded `photo`
/// or nothing); `photo` is an uploaded blob. Both feed straight into `AvatarView`/`RemoteImage`.
struct AuthorIdentity {
    var name: String
    var img: String
    var photo: Data?
}

/// Repository facade over SwiftData. Keeps the same public API the screens already use, so the
/// storage swap (JSON → `ModelContext`, later CloudKit-synced) doesn't ripple into the views.
///
/// Cached arrays are re-fetched via `refresh()` after each mutation so `@Observable` re-renders.
@MainActor
@Observable
final class MockDataStore {
    private let context: ModelContext

    private(set) var instructors: [Instructor] = []
    /// Cached public student profiles — the owner's own row plus instructor-side rows for students
    /// they transact with. The counterpart to `instructors`; see `StudentProfile`.
    private(set) var studentProfiles: [StudentProfile] = []
    private(set) var posts: [FeedPost] = []
    private(set) var postComments: [PostComment] = []
    private(set) var bookings: [Booking] = []
    private(set) var messages: [Message] = []
    private(set) var blocked: [BlockedUser] = []
    /// The instructor's PRIVATE clinical/safety notes about their clients — injuries, pregnancy,
    /// conditions. Private-DB only (see [[ClientNote]]); NEVER published to any public record.
    private(set) var clientNotes: [ClientNote] = []
    private(set) var reviews: [Review] = []
    private(set) var events: [CommunityEvent] = []
    /// Every cached lesson type — the owner's own rows plus any fetched for an instructor a student is
    /// viewing. Kept as `@Model` rows (not `ResolvedLessonType`) because the editor mutates them and
    /// the sync merges into them; views consume the flattened `lessonTypes(for:)` resolver instead.
    private(set) var lessonTypes: [LessonType] = []
    /// Flowe Education — authored programs + video exercises (the signed-in instructor's own, or, when a
    /// student views an instructor, theirs merged from the public store). Both ordered by `order`.
    private(set) var programs: [Program] = []
    private(set) var videoExercises: [VideoExercise] = []
    /// Cached career-marketplace opportunities (Flowe Pro — see [[FlowePro]]). Local cache of a public
    /// record, like `instructors`; fetched via a future OpportunityService, seeded for now.
    private(set) var opportunities: [Opportunity] = []
    /// Cached applications to opportunities (both mine-as-applicant and mine-as-poster's-inbox).
    private(set) var opportunityApplications: [OpportunityApplication] = []
    /// Cached poster decisions on applications (the pipeline stage).
    private(set) var applicationDecisions: [ApplicationDecision] = []
    /// Cached peer recommendations (Flowe Pro Phase 5) — endorsements addressed to an instructor, fetched
    /// when their profile is viewed, plus the signed-in instructor's own written ones. See [[FlowePro]].
    private(set) var recommendations: [InstructorRecommendation] = []

    private let catalog = CatalogService()
    private let studentDirectory = StudentDirectoryService()
    private let bookingService = BookingService()
    private let messagingService = MessagingService()
    private let messageCrypto = MessageCrypto()
    private let noteCrypto = NoteCrypto()   // encryption-at-rest for private ClientNotes (health data)
    private let deletionService = AccountDeletionService()
    private let reportService = ReportService()
    private let reviewService = ReviewService()
    private let communityService = CommunityService()
    private let eventService = EventService()
    private let packageService = PackageService()
    private let lessonTypeService = LessonTypeService()
    private let programService = ProgramService()
    private let exerciseService = ExerciseService()
    private let coverageService = CoverageService()
    private let opportunityService = OpportunityService()
    private let recommendationService = RecommendationService()

    // MARK: - Feed load state

    /// Per-feed load phase, so a screen can tell "first load in flight", "loaded with nothing", and
    /// "the load failed" apart instead of rendering all three as the same empty state. Written by the
    /// sync methods below, read by the feed views. Once a feed has loaded, a later background-refresh
    /// failure leaves it `.loaded` (the cached data stays on screen) rather than flipping to `.failed`.
    private(set) var catalogPhase: LoadPhase = .idle
    private(set) var bookingsPhase: LoadPhase = .idle
    private(set) var communityPhase: LoadPhase = .idle
    private(set) var eventsPhase: LoadPhase = .idle
    private(set) var packagesPhase: LoadPhase = .idle   // instructor offerings + purchase-request inbox
    private(set) var walletPhase: LoadPhase = .idle      // student credit wallet
    /// Always `false`. Retained only because ~60 call sites still `guard !isPreview`; the app no
    /// longer has any seed / preview / offline mode — every path talks to the CloudKit-synced store.
    private let isPreview = false

    /// The app is CloudKit-only: the store starts EMPTY and fills purely from the synced public/
    /// private databases. No mock, seed, or preview data is ever loaded, in any build configuration.
    init(_ context: ModelContext) {
        self.context = context
        refresh()
        #if DEBUG
        seedDevDataIfRequested()
        #endif
    }

    /// Wipes every locally-stored model — used when the signed-in user deletes their account (after the
    /// public-DB records are swept) so no stale data lingers in the on-device store.
    /// Returns false if the wipe did not commit. That MATTERS: these rows are the source SwiftData
    /// re-uploads from, so a swallowed save failure means the private mirror zone gets deleted and then
    /// immediately RE-CREATED from the surviving local rows — resurrecting exactly the data the user
    /// asked to erase. The caller gates deletion success on this.
    @discardableResult
    private static func deleteAll(_ context: ModelContext) -> Bool {
        try? context.delete(model: Instructor.self)
        try? context.delete(model: StudentProfile.self)
        try? context.delete(model: FeedPost.self)
        try? context.delete(model: PostComment.self)
        try? context.delete(model: Booking.self)
        try? context.delete(model: Message.self)
        try? context.delete(model: BlockedUser.self)
        try? context.delete(model: ClientNote.self)
        try? context.delete(model: Review.self)
        try? context.delete(model: CommunityEvent.self)
        try? context.delete(model: LessonType.self)
        // Reference-config, local-only @Models (cloudKitDatabase: .none) — still keyed by ownerID
        // (posterID/applicantID/fromID), so on a same-Apple-ID re-signup the stale rows would resurface
        // as the user's own opportunities/applications/recommendations. Same omission class as the
        // AccountDeletionService public-sweep gap, on the local store.
        try? context.delete(model: Opportunity.self)
        try? context.delete(model: OpportunityApplication.self)
        try? context.delete(model: ApplicationDecision.self)
        try? context.delete(model: InstructorRecommendation.self)
        // Flowe Education. Both are in the SYNCED (UserData) config exactly like LessonType, so omitting
        // them left a published library on the device — and in the private CloudKit mirror — after an
        // account deletion, to resurface on a same-Apple-ID re-signup.
        try? context.delete(model: Program.self)
        try? context.delete(model: VideoExercise.self)
        do { try context.save(); return true } catch { return false }
    }

    func refresh() {
        instructors = fetch(sortBy: \Instructor.order)
        studentProfiles = fetch(sortBy: \StudentProfile.order)
        // Newest first: the feed is a timeline, and a shared feed has no meaningful local `order`.
        posts       = (try? context.fetch(
            FetchDescriptor<FeedPost>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )) ?? []
        postComments = (try? context.fetch(
            FetchDescriptor<PostComment>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        )) ?? []
        bookings    = fetch(sortBy: \Booking.order)
        messages    = (try? context.fetch(
            FetchDescriptor<Message>(sortBy: [SortDescriptor(\.sentAt, order: .forward)])
        )) ?? []
        blocked     = (try? context.fetch(
            FetchDescriptor<BlockedUser>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )) ?? []
        mirrorBlockedToAppGroup()   // hand the block list to the Notification Service Extension on load
        clientNotes = (try? context.fetch(
            FetchDescriptor<ClientNote>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        )) ?? []
        reviews     = (try? context.fetch(
            FetchDescriptor<Review>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )) ?? []
        // Earliest-starting first: the events list is a chronological schedule, and the store never
        // relies on a local `order` for shared records.
        events      = (try? context.fetch(
            FetchDescriptor<CommunityEvent>(sortBy: [SortDescriptor(\.startsAt, order: .forward)])
        )) ?? []
        // By the instructor-controlled `order`, so the editor list and both student surfaces show the
        // exact sequence the instructor arranged.
        lessonTypes = (try? context.fetch(
            FetchDescriptor<LessonType>(sortBy: [SortDescriptor(\.order, order: .forward)])
        )) ?? []
        programs = (try? context.fetch(
            FetchDescriptor<Program>(sortBy: [SortDescriptor(\.order, order: .forward)])
        )) ?? []
        videoExercises = (try? context.fetch(
            FetchDescriptor<VideoExercise>(sortBy: [SortDescriptor(\.order, order: .forward)])
        )) ?? []
        opportunities = (try? context.fetch(
            FetchDescriptor<Opportunity>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )) ?? []
        opportunityApplications = (try? context.fetch(
            FetchDescriptor<OpportunityApplication>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )) ?? []
        applicationDecisions = (try? context.fetch(FetchDescriptor<ApplicationDecision>())) ?? []
        recommendations = (try? context.fetch(
            FetchDescriptor<InstructorRecommendation>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )) ?? []
        applyCompletions()
    }

    /// Turn confirmed sessions whose time has passed into `.completed`.
    ///
    /// The sync resolver applies the identical rule to freshly-fetched bookings; this covers the
    /// cases sync doesn't reach — a session that ends while the app is open (or offline) with no
    /// re-sync, and a booking created locally that hasn't round-tripped. Derived purely from the
    /// clock, so it is idempotent and self-heals on relaunch; deliberately no `save()` here (it would
    /// recurse through `refresh`), so the change persists on the next save or recomputes next launch.
    ///
    /// Skipped for previews/tests: seeded data carries hand-set statuses (an explicitly `.confirmed`
    /// session dated today) the demo and the UI suite depend on staying put.
    private func applyCompletions() {
        guard !isPreview else { return }
        for booking in bookings where booking.status == .confirmed
            && Booking.isOver(date: booking.date, time: booking.time, duration: booking.duration) {
            booking.status = .completed
        }
    }

    private func fetch<M: PersistentModel>(sortBy key: KeyPath<M, Int>) -> [M] {
        let descriptor = FetchDescriptor<M>(sortBy: [SortDescriptor(key, order: .forward)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func instructor(id: Int) -> Instructor? {
        instructors.first { $0.legacyId == id }
    }

    /// Resolve a cached listing by its owner id — the RELIABLE instructor key. Legacy `instructorId`
    /// (an Int) is 0 for a booking whose instructor wasn't cached at materialization, so `instructor(id:)`
    /// can miss; `instructorOwnerID` never does. Used by the "Your Teachers" rebook rail.
    func instructor(ownerID: String?) -> Instructor? {
        guard let ownerID else { return nil }
        return instructors.first { $0.ownerID == ownerID }
    }

    // MARK: - Saved instructors (local wishlist)

    private static let savedInstructorsKey = "flowe.savedInstructors"

    /// Instructor ownerIDs the student saved — a LOCAL wishlist (UserDefaults, THIS device only; a
    /// cross-device version is a deferred additive-schema upgrade). Ordered most-recently-saved first.
    /// `@Observable`, so toggling live-refreshes every heart + the profile rail.
    private(set) var savedInstructorIDs: [String] =
        UserDefaults.standard.stringArray(forKey: MockDataStore.savedInstructorsKey) ?? []

    func isSaved(_ ownerID: String?) -> Bool {
        guard let ownerID else { return false }
        return savedInstructorIDs.contains(ownerID)
    }

    /// Save / unsave an instructor. Local-only — never publishes to CloudKit.
    func toggleSaved(_ ownerID: String?) {
        guard let ownerID, !ownerID.isEmpty else { return }
        if let idx = savedInstructorIDs.firstIndex(of: ownerID) {
            savedInstructorIDs.remove(at: idx)
        } else {
            savedInstructorIDs.insert(ownerID, at: 0)   // most-recently-saved first
        }
        UserDefaults.standard.set(savedInstructorIDs, forKey: Self.savedInstructorsKey)
    }

    /// Saved instructors resolved to cached listings (most-recently-saved first); unresolved ids skipped.
    var savedInstructors: [Instructor] {
        savedInstructorIDs.compactMap { instructor(ownerID: $0) }
    }

    /// Instructors students can see: an active subscription (Visible/Boost), a set-up listing,
    /// and a fresh subscription check. Boosted first, then by rating, then order.
    var visibleInstructors: [Instructor] {
        instructors.filter { Self.isEligible($0) && !isBlocked($0.ownerID) }.sorted {
            if $0.visibilityRaw != $1.visibilityRaw { return $0.visibilityRaw > $1.visibilityRaw }
            if $0.rating != $1.rating { return $0.rating > $1.rating }
            return $0.order < $1.order
        }
    }

    /// The featured slot — the top boosted instructor (falls back to the first visible one).
    var featuredInstructor: Instructor? {
        visibleInstructors.first { $0.visibility == .boosted } ?? visibleInstructors.first
    }

    /// Back-compat alias for the student feed.
    var publishedInstructors: [Instructor] { visibleInstructors }

    /// How long a listing stays discoverable on a student's device without the owner's device
    /// re-confirming the subscription. See `isEligible` for why this must exceed the 16-day grace.
    static let visibilityTTL: TimeInterval = 30 * 24 * 3600
    /// Warn this far before the TTL expires, so the instructor can just open the app and reset it.
    static let visibilityWarnAfter: TimeInterval = 23 * 24 * 3600

    private static func isEligible(_ ins: Instructor) -> Bool {
        // `ins.price > 0` now means "has at least one PRICED lesson type": `price` is the derived
        // cheapest lesson-type price (see `Instructor.startingPrice` + `publishMyListing`), so this line
        // preserves the old discoverability semantics unchanged. It relies on `publishMyListing`
        // re-deriving `price` BEFORE the listing is published/evaluated — do not repoint it at
        // `lessonTypes(for:)`: this is static and remote instructors carry no cached LessonType rows.
        guard ins.visibility != .none, ins.price > 0, !ins.name.isEmpty else { return false }
        // Check-in backstop: a lapsed subscription on a device that never reopened stays hidden.
        //
        // MUST stay comfortably longer than Apple's BILLING GRACE PERIOD (16 days on this app's
        // subscriptions). At the old 7 days the backstop was TIGHTER than the grace window, so an
        // instructor whose payment was retrying — still entitled as far as Apple is concerned — could
        // be dropped from Discover on day 8 for the sole reason that they hadn't opened the app.
        // 30 days clears 16 with real headroom while still bounding a genuinely-lapsed listing to a
        // month. Paired with `PushService.scheduleVisibilityCheckIn`, which warns them BEFORE it bites
        // — this check runs on every STUDENT's device, so without that nudge the instructor gets no
        // signal at all and simply concludes Flowe doesn't work.
        if let verified = ins.visibilityVerifiedAt {
            return Date().timeIntervalSince(verified) < Self.visibilityTTL
        }
        return true
    }

    /// Stamp the signed-in instructor's listing with their subscription-derived visibility,
    /// and push the change to the public catalog so students see (or stop seeing) them.
    func applyVisibility(_ level: InstructorVisibility, for ownerID: String) {
        guard let listing = instructors.first(where: { $0.ownerID == ownerID }) else { return }
        listing.visibility = level
        listing.visibilityVerifiedAt = Date()
        // Re-arm the "you're about to go hidden" nudge from this fresh check-in.
        Task { await PushService.shared.scheduleVisibilityCheckIn(isVisible: level != .none) }
        // Mark for republish BEFORE the network attempt (mirrors `publishMyListing`). A DOWNGRADE
        // to `.none` that fails to reach CloudKit — device offline, signed out of iCloud, or
        // throttled — would otherwise leave the PUBLIC listing stuck at visibility>0 (the instructor
        // stays discoverable and bookable) with nothing to correct it: this is a fire-and-forget
        // Task, not a retried write. Setting `pendingPublish` hands the retry to `flushPendingListing`
        // on the next instructor sync / foreground. Only ever the signed-in instructor's own listing
        // reaches here (sole caller passes `session.ownerID`), so it IS `currentInstructor` and the
        // flush — which keys off `currentInstructor.pendingPublish` — will pick it up.
        listing.pendingPublish = true
        save()
        // Advance the own-listing baseline from this publish's server timestamp too, so a
        // visibility-only push doesn't leave `lastSyncedAt` stale and trigger a spurious self
        // re-apply on the next foreground.
        if !isPreview {
            Task {
                if let ts = await catalog.publish(listing) {
                    listing.lastSyncedAt = ts
                    listing.pendingPublish = false
                    save()
                }
            }
        }
        // A downgrade hides the listing, but any CommunityEvent the instructor already published is a
        // SEPARATE public record `applyVisibility` doesn't touch — so a lapsed instructor would still
        // surface in Community → Events. Call those off too.
        if level == .none { retractEventsOnDowngrade() }
    }

    /// Call off the signed-in instructor's FUTURE, not-already-cancelled events when their subscription
    /// lapses (`applyVisibility(.none)`). Uses `cancelEvent` (not `deleteEvent`) so students who already
    /// registered see the class was called off rather than having it silently vanish, and so it rides
    /// the audited cancel → upload → retry path. Past and already-cancelled events are skipped. Only the
    /// signed-in instructor's own events are reachable via `myEvents`, matching `applyVisibility`'s scope.
    private func retractEventsOnDowngrade() {
        let now = Date()
        for event in myEvents where !event.cancelled && event.endsAt >= now {
            cancelEvent(event)
        }
    }

    // MARK: - Bookings

    /// Upcoming sessions, SOONEST first — a stable, sensible order (the raw cache order looked jumbled
    /// when switching tabs). `sessionStart` is cheap now that Booking's formatters are cached.
    ///
    /// A booking whose session has already ENDED is excluded even when its status is still "upcoming":
    /// a `.pending` request is never expired by `applyCompletions` (which only heals `.confirmed`), so a
    /// never-accepted request keeps a past `sessionStart` and — under the soonest-first sort — would
    /// otherwise float to the very TOP of the list, above every live session. Time-gating on
    /// `sessionEnd` keeps such dead/stale rows out of Upcoming (a `.confirmed` past session is separately
    /// healed to `.completed` on the next sync and then lands in Past).
    var upcomingBookings: [Booking] {
        let now = Date()
        return myBookings
            .filter { $0.status.isUpcoming && ($0.sessionEnd(now: now) ?? .distantFuture) >= now }
            .sorted { ($0.sessionStart() ?? .distantFuture) < ($1.sessionStart() ?? .distantFuture) }
    }
    /// Past sessions, MOST RECENT first.
    var pastBookings: [Booking] {
        myBookings.filter { !$0.status.isUpcoming }
            .sorted { ($0.sessionStart() ?? .distantPast) > ($1.sessionStart() ?? .distantPast) }
    }

    var upcomingCount: Int { upcomingBookings.count }
    var completedCount: Int { myBookings.filter { $0.status == .completed }.count }

    /// Distinct instructors the signed-in student has booked (any non-cancelled booking), MOST-RECENTLY
    /// seen first — the "Your Teachers" one-tap rebook rail on the profile. Resolved against the local
    /// catalog cache by ownerID; a booked instructor no longer cached locally is skipped (their listing
    /// re-caches on the next Discover sync). No new data, no schema.
    var bookedInstructors: [Instructor] {
        var seen = Set<String>()
        var result: [Instructor] = []
        for booking in myBookings
            .filter({ $0.status != .cancelled })
            .sorted(by: { ($0.sessionStart() ?? .distantPast) > ($1.sessionStart() ?? .distantPast) }) {
            guard let ownerID = booking.instructorOwnerID, !seen.contains(ownerID),
                  let ins = instructor(ownerID: ownerID) else { continue }
            seen.insert(ownerID)
            result.append(ins)
        }
        return result
    }

    /// Sessions this instructor has actually delivered.
    var instructorCompletedCount: Int {
        incomingBookings.filter { $0.status == .completed }.count
    }

    // MARK: - Instructor analytics & earnings
    //
    // All derived from real incoming bookings. Bookings carry a *display* date string, not a
    // timestamp, so there is deliberately no month-by-month time series here — inventing one would
    // be exactly the mock data these screens are meant to replace. Every number below is something
    // that actually happened.

    /// The earning for one booked session — the price of the ACTUAL lesson type booked, resolved by
    /// name. Falls back to 0 (never crashes) when the booking's type was renamed/deleted so its name no
    /// longer matches any owned row, or when the type carries no price: earnings then under-count rather
    /// than fabricate a number. Distinct from `sessionPrice(for:)`, whose `?? me.price` no-show-fee base
    /// is intentionally the derived rate.
    func sessionEarning(for b: Booking) -> Int {
        guard let me = currentInstructor else { return 0 }
        return ownedLessonTypes(for: me).first { $0.name == b.type }?.price ?? 0
    }

    /// The price of an owned lesson type resolved by name, for the earnings-by-type breakdown. 0 when
    /// the name no longer resolves or the type is unpriced — mirrors `sessionEarning`.
    func priceForType(_ name: String) -> Int {
        guard let me = currentInstructor else { return 0 }
        return ownedLessonTypes(for: me).first { $0.name == name }?.price ?? 0
    }

    /// Earnings summed from the ACTUAL booked lesson-type prices, not a single rate × count — each
    /// instructor now prices per lesson type. Payment is arranged directly with the student, so
    /// `collected` is what completed sessions were worth and `projected` what accepted-but-not-yet-
    /// delivered sessions will be worth — a forecast, not an in-app balance.
    var instructorEarnings: (collected: Int, projected: Int) {
        let collected = incomingBookings
            .filter { $0.status == .completed }
            .reduce(0) { $0 + sessionEarning(for: $1) }
        let projected = incomingBookings
            .filter { $0.status == .confirmed }
            .reduce(0) { $0 + sessionEarning(for: $1) }
        return (collected, projected)
    }

    /// Delivered + accepted sessions grouped by type (Private, Duet, …) — a real dimension, unlike
    /// a fabricated timeline, so it's safe to chart.
    var instructorSessionsByType: [(type: String, count: Int)] {
        let counted = incomingBookings.filter { $0.status == .completed || $0.status == .confirmed }
        let grouped = Dictionary(grouping: counted, by: { $0.type.isEmpty ? "Other" : $0.type })
        return grouped
            .map { (type: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    /// Distinct students who have booked more than one non-cancelled session — the clearest signal
    /// an instructor is retaining people.
    var instructorRepeatStudentCount: Int {
        let active = incomingBookings.filter { $0.status != .cancelled }
        let perStudent = Dictionary(grouping: active) { $0.studentID ?? $0.studentName }
        return perStudent.values.filter { $0.count > 1 }.count
    }

    /// Distinct students seen, ever.
    var instructorStudentCount: Int {
        Set(incomingBookings.filter { $0.status != .cancelled }.map { $0.studentID ?? $0.studentName }).count
    }

    /// Share of decided requests the instructor accepted. Pending requests aren't decided yet, so
    /// they're excluded; nil when nothing has been decided, so the UI shows "—" rather than 0%.
    var instructorAcceptanceRate: Double? {
        let accepted = incomingBookings.filter { $0.status == .confirmed || $0.status == .completed }.count
        let declined = incomingBookings.filter { $0.status == .cancelled }.count
        let decided = accepted + declined
        guard decided > 0 else { return nil }
        return Double(accepted) / Double(decided)
    }

    /// Total practiced hours from completed sessions' durations (e.g. "55 min").
    var hoursDisplay: String {
        let minutes = myBookings
            .filter { $0.status == .completed }
            .reduce(0) { $0 + (Int($1.duration.filter(\.isNumber)) ?? 0) }
        let hours = Double(minutes) / 60
        return hours == hours.rounded() ? String(format: "%.0f", hours) : String(format: "%.1f", hours)
    }

    /// The outcome of a booking attempt. `.slotTaken` (the atomic seat claim lost a race) and
    /// `.selfDuplicate` (this student already holds the slot) must NOT create a phantom local booking —
    /// the sheet keeps the user on the picker and refreshes availability instead of showing success.
    enum BookingResult: Equatable {
        case booked            // an admitted seat claimed (or degraded to unlocked offline) and the booking created
        case waitlisted(rank: Int)  // the group class was full → an OVERFLOW seat claimed; booking created, on the waitlist
        case slotTaken         // the slot was just booked by someone else — pick another time
        case selfDuplicate     // this student already booked/holds this exact slot
        case failed            // reserved (booking currently never returns this — a claim failure degrades to .booked)
    }

    /// Creates a booking from a completed BookingSheet flow and publishes it to the shared
    /// database so the instructor actually receives it.
    ///
    /// The booking starts `pending`: it is a *request* until the instructor accepts. Payment is
    /// arranged directly with the instructor — this release takes no money in-app.
    ///
    /// Before anything is created it acquires an ATOMIC per-seat lock on the physical slot
    /// (instructor+date+time) via `BookingService.claimSeat` — the serverless mutex that stops two
    /// students holding the same 1-on-1 slot. A lost claim returns `.slotTaken` WITHOUT inserting a row.
    @discardableResult
    func addBooking(instructor: Instructor, day: String, time: String, type: String, useCredit: Bool = false) async -> BookingResult {
        // Resolve the chosen type name to its authored lesson type: a stated duration wins, so a
        // "90 min" reformer no longer collapses to the old Private/other 55-vs-50 guess. A migrated
        // bare name (durationMinutes 0) or an unresolved past type falls back to that heuristic, so a
        // booking always carries some duration. Capacity (seats) comes from the same resolved type.
        let lessonType = ownedLessonTypes(for: instructor).first { $0.name == type }
        let stated = lessonType?.durationMinutes ?? 0
        let duration = stated > 0 ? "\(stated) min" : (type == "Private" ? "55 min" : "50 min")
        let capacity = lessonType?.capacity ?? 0   // 0 (unstated) => claimSeat normalizes to 1 seat

        // One-off self-collision guard (client-side, fast + clear message): an EXACT-date match on this
        // instructor+time+date. The atomic hold is the cross-device backstop.
        let bookingDate = Self.formatDay(day)
        let selfClash = myBookings.contains {
            $0.status != .cancelled
                && $0.instructorOwnerID == instructor.ownerID
                && $0.time == time
                && $0.date == bookingDate
        }
        if selfClash { return .selfDuplicate }

        // Defensive backstop: never create a one-off on a date the instructor has closed. The picker
        // already dims/disables a closed day (`isBookable(onDate:)`), so this only catches a stale
        // in-flight tap; it degrades as before when the date can't be resolved. `.slotTaken` prompts a
        // clean re-pick with refreshed availability.
        if let resolved = Self.date(forPickerValue: day), instructor.isClosedOverride(onDate: resolved) {
            return .slotTaken
        }

        // Atomic seat claim BEFORE creating anything. A lost race (.slotTaken) returns without inserting
        // so no phantom booking is left behind; a claim that can't run (offline / preview / schema not
        // deployed) degrades to an UNLOCKED booking (today's behavior) rather than blocking the student.
        // A real group/duet type (cap >= 2) allows the claim to overflow into a WAITLIST seat when every
        // admitted seat is taken, rather than dead-ending on `.slotTaken`. A Private (cap 1 / unstated)
        // never sets allowWaitlist, so it stays the hard 1-on-1 mutex.
        var holdName: String? = nil
        var waitlistRank: Int? = nil
        if !isPreview, let instructorID = instructor.ownerID, let token = Booking.timeToken(time),
           let date = Self.date(forPickerValue: day) {
            switch await bookingService.claimSeat(instructorID: instructorID,
                                                  date: Booking.seriesDateString(date),
                                                  time: token, capacity: capacity,
                                                  allowWaitlist: capacity >= 2) {
            case .claimed(let name):               holdName = name
            case .waitlisted(let name, let rank):  holdName = name; waitlistRank = rank
            case .slotTaken:                       return .slotTaken
            case .failed:                          holdName = nil   // degrade to unlocked
            }
        }

        let nextId = (bookings.map(\.legacyId).max() ?? 0) + 1
        let topOrder = (bookings.map(\.order).min() ?? 0) - 1   // smaller order sorts first
        let booking = Booking(
            legacyId: nextId,
            instructorId: instructor.legacyId,
            date: bookingDate,
            time: time,
            type: type,
            duration: duration,
            status: .pending,
            ownerID: currentUserID,
            order: topOrder,
            instructorOwnerID: instructor.ownerID,
            studentID: currentUserID,
            studentName: currentUserName,
            holdRecordName: holdName
        )
        // A WAITLISTED booking does NOT publish a public SessionBooking — only its overflow SlotHold seat
        // (already saved by claimSeat) persists the waitlist position server-side. Publishing it would put
        // a seatless waitlister in the instructor's request inbox, where accepting it would mis-count
        // earnings and could No-Show-fee someone who never had a seat. It is published only on promotion
        // (see promoteWaitlistedSeats), when it actually holds an admitted seat.
        let isWaitlist = waitlistRank != nil
        // Marked pending up front (non-waitlist only): if the app is killed before the upload finishes, the
        // next sync retries it rather than losing the booking.
        booking.pendingUpload = !isWaitlist
        booking.bookedCapacity = capacity   // freeze so promotion/top-up survive a cold type cache
        context.insert(booking)
        save()

        guard !isWaitlist, !isPreview,
              let instructorID = instructor.ownerID,
              let studentID = currentUserID else {
            return waitlistRank.map { .waitlisted(rank: $0) } ?? .booked
        }
        // Redeeming a class-credit: pass the intent + the ISO class date (for the delivery-gated refund)
        // to the upload. The backend ignores useCredit with no capacity (books normally, credited:false).
        let creditClassDate = Self.date(forPickerValue: day).map { Booking.seriesDateString($0) }
        Task { await upload(booking, instructorID: instructorID, studentID: studentID,
                            useCredit: useCredit, creditClassDate: creditClassDate) }
        return .booked
    }

    /// Live seat occupancy for an instructor's slots on a picker day, as `[HHmm token: seats taken]`, so
    /// the booking picker can show a full time as disabled. Best-effort: returns `[:]` when the day can't
    /// be resolved or the query fails — the atomic claim at confirm is the real guarantee, this is only a
    /// display hint. `day` is the English/POSIX picker value ("EEE MMM d").
    func slotOccupancy(for instructor: Instructor, day: String) async -> [String: Int] {
        guard let instructorID = instructor.ownerID,
              let date = Self.date(forPickerValue: day) else { return [:] }
        let dateString = Booking.seriesDateString(date)
        return await bookingService.fetchSlotOccupancy(instructorID: instructorID, date: dateString) ?? [:]
    }

    // MARK: - Standing (recurring weekly) bookings
    //
    // A standing slot ("every Tuesday 9am until I cancel") is materialized as ONE ordinary pending
    // Booking per matching weekday out to the 12-week horizon, every occurrence sharing a deterministic
    // recordName `sb-<seriesUUID>-<yyyy-MM-dd>`. Because each week is a normal Booking row, every
    // existing surface (My Sessions, calendar, No-Show Shield, reviews, earnings) keeps working
    // unchanged. The instructor approves the series ONCE (a single `series-<id>` decision); weeks that
    // roll into the horizon later auto-confirm against that same decision (see `status(for:)`).

    /// Mint a series and materialize its full-horizon batch of weekly occurrences, then upload each.
    /// Each week claims its own seat in the SAME slot namespace as one-offs, so a standing week and a
    /// one-off on the same instructor+date+time genuinely contend; a week that's already full is SKIPPED
    /// (graceful degrade — never a silent double-book). Returns `.selfDuplicate` on a standing self-clash,
    /// `.slotTaken` only if EVERY week was full (nothing materialized), else `.booked`.
    @discardableResult
    private func addStandingSeries(instructor: Instructor, day: String, time: String,
                                   type: String, duration: String, capacity: Int) async -> BookingResult {
        guard let anchor = Self.date(forPickerValue: day) else {
            // Fall back to a single booking if the picked day can't be resolved to a real date.
            return await addBooking(instructor: instructor, day: day, time: time, type: type)
        }
        // Self-collision guard: a student can't hold two standing slots on the same instructor +
        // weekday + time. The atomic per-week hold is the cross-device backstop against real overbooking.
        let weekday = String(FloweWeek.bookingDateString(for: anchor).prefix(3))
        // Only another STANDING slot on the same weekday+time collides. Scoping to `isRecurring` avoids a
        // false positive where a lone one-off on some Tuesday would block ALL future Tuesday series (both
        // store the "EEE, …" date, so a bare `hasPrefix` can't tell a one-off from a series).
        let clash = myBookings.contains {
            $0.isRecurring
                && $0.status != .cancelled
                && $0.instructorOwnerID == instructor.ownerID
                && $0.time == time
                && $0.date.hasPrefix(weekday)
        }
        if clash { return .selfDuplicate }

        let seriesID = UUID().uuidString
        let created = await materializeSeriesOccurrences(
            instructor: instructor, from: anchor, time: time, type: type,
            duration: duration, seriesID: seriesID, approved: false, capacity: capacity
        )
        save()
        guard !isPreview,
              let instructorID = instructor.ownerID,
              let studentID = currentUserID else {
            return created.isEmpty ? .slotTaken : .booked
        }
        Task {
            for booking in created { await uploadSeries(booking, instructorID: instructorID, studentID: studentID) }
        }
        return created.isEmpty ? .slotTaken : .booked
    }

    /// Insert (but do not upload) the missing weekly occurrences of a series from `from` out to the
    /// horizon, returning the newly-inserted rows. Idempotent against the local cache — an occurrence
    /// whose deterministic recordName already exists is skipped, so top-up never duplicates a week.
    ///
    /// Each new week first CLAIMS its seat on the physical slot: `.claimed` → the row carries the hold;
    /// `.slotTaken` → the week is SKIPPED (never overbooked); `.failed` (offline / preview / schema not
    /// deployed) → the row is created UNLOCKED so a standing booking is never blocked. `capacity` is the
    /// booked type's seat count (0 unstated → 1 seat).
    @discardableResult
    private func materializeSeriesOccurrences(instructor: Instructor, from: Date, time: String,
                                              type: String, duration: String, seriesID: String,
                                              approved: Bool, capacity: Int,
                                              calendar: Calendar = .current) async -> [Booking] {
        let startToday = calendar.startOfDay(for: Date())
        let horizonEnd = calendar.date(byAdding: .day, value: FloweWeek.maxDayID, to: startToday) ?? from
        var nextId = bookings.map(\.legacyId).max() ?? 0
        var topOrder = bookings.map(\.order).min() ?? 0
        var created: [Booking] = []
        let token = Booking.timeToken(time)
        var date = from
        while date <= horizonEnd {
            // Skip a week the instructor made unbookable AT THIS TIME: a CLOSED (vacation) date, OR a
            // CUSTOM override that moved/removed this series' time. `date` advances at the END of the loop
            // body, so advance here too before `continue` or a skipped date spins forever. Gated on
            // `hasDateOverride` so a NORMAL week is never touched (no format-match risk), and a token-less
            // instructor placeholder — which top-up may pass — reports no override (empty `hours`) → never
            // skips the whole series. Subsumes the old CLOSED-only check (a closed date has an override and
            // empty `hours(onDate:)`, so it can't contain the time).
            if instructor.hasDateOverride(onDate: date), !instructor.hours(onDate: date).contains(time) {
                date = calendar.date(byAdding: .day, value: 7, to: date) ?? date.addingTimeInterval(7 * 86_400)
                continue
            }
            let recordName = Booking.seriesRecordName(seriesID: seriesID, occurrenceDate: date)
            if !bookings.contains(where: { $0.remoteID == recordName }) {
                // Claim this week's seat before minting the row.
                var holdName: String? = nil
                var skip = false
                if !isPreview, let instructorID = instructor.ownerID, let token {
                    switch await bookingService.claimSeat(instructorID: instructorID,
                                                          date: Booking.seriesDateString(date),
                                                          time: token, capacity: capacity) {
                    case .claimed(let name):        holdName = name
                    case .waitlisted(let name, _):  holdName = name   // unreachable (series never allowWaitlist); treat as claimed
                    case .slotTaken:                skip = true       // week full — degrade gracefully, skip it
                    case .failed:                   holdName = nil     // offline / schema missing — unlocked week
                    }
                }
                if !skip {
                    nextId += 1; topOrder -= 1
                    let booking = Booking(
                        legacyId: nextId,
                        instructorId: instructor.legacyId,
                        date: FloweWeek.bookingDateString(for: date),
                        time: time,
                        type: type,
                        duration: duration,
                        status: approved ? .confirmed : .pending,
                        ownerID: currentUserID,
                        order: topOrder,
                        remoteID: recordName,           // deterministic name set up front — parseable offline
                        instructorOwnerID: instructor.ownerID,
                        studentID: currentUserID,
                        studentName: currentUserName,
                        holdRecordName: holdName
                    )
                    booking.bookedCapacity = capacity   // freeze so a later top-up reads the right capacity
                    booking.pendingUpload = true
                    context.insert(booking)
                    created.append(booking)
                }
            }
            date = calendar.date(byAdding: .day, value: 7, to: date) ?? date.addingTimeInterval(7 * 86_400)
        }
        return created
    }

    /// Upload one series occurrence by its deterministic recordName (fetch-or-create, idempotent). The
    /// recordName stays set even on failure (it is deterministic and already parseable); only
    /// `pendingUpload` toggles, so the next sync retries it.
    private func uploadSeries(_ booking: Booking, instructorID: String, studentID: String) async {
        let saved = await bookingService.create(
            instructorID: instructorID,
            studentID: studentID,
            studentName: booking.studentName,
            date: booking.date,
            time: booking.time,
            type: booking.type,
            duration: booking.duration,
            recordName: booking.remoteID
        )
        booking.pendingUpload = saved == nil
        save()
    }

    /// The real `Date` for a booking day-picker value ("EEE MMM d", English/POSIX), found by scanning
    /// the bookable horizon — within 12 weeks a "MMM d" is unambiguous, so no year is needed.
    private static func date(forPickerValue value: String, calendar: Calendar = .current) -> Date? {
        let start = calendar.startOfDay(for: Date())
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d"
        for offset in 0...FloweWeek.maxDayID {
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            if f.string(from: date) == value { return date }
        }
        return nil
    }

    /// Push a locally-created booking to the shared database, flagging it for retry if it fails.
    /// `useCredit` redeems ONE class-credit against this instructor as part of the same backend insert
    /// (only ever passed from `addBooking`'s first attempt — a retry books WITHOUT a credit, which fails
    /// toward the student: they keep the credit rather than lose it to a partial write).
    private func upload(_ booking: Booking, instructorID: String, studentID: String,
                        useCredit: Bool = false, creditClassDate: String? = nil) async {
        // Idempotency key: assign a stable client id on the FIRST attempt and REUSE it on every retry,
        // so a re-sent one-off (an auth retry, or a flush after a lost response) collapses to ONE row
        // via the backend's ON CONFLICT(id) DO NOTHING — this is the duplicate-booking-request fix.
        // Mirrors the series path, which is already idempotent through its deterministic recordName.
        if booking.remoteID == nil { booking.remoteID = "bk-\(UUID().uuidString)" }
        let result = await bookingService.create(
            instructorID: instructorID,
            studentID: studentID,
            studentName: booking.studentName,
            date: booking.date,
            time: booking.time,
            type: booking.type,
            duration: booking.duration,
            recordName: booking.remoteID,          // deterministic → a retry never creates a second row
            useCredit: useCredit,
            creditClassDate: creditClassDate
        )
        // NEVER nil the id back out on failure — the retry must re-send the SAME key to dedupe.
        if let id = result?.id { booking.remoteID = id }
        booking.pendingUpload = result == nil
        save()
        // A credit was requested and the booking landed → refresh the per-instructor balance + wallet so
        // the ring reflects the redemption (or the graceful no-capacity fallback, credited == false).
        if useCredit, result != nil {
            await refreshBalance(with: instructorID)
            await syncWallet()
        }
    }

    /// Instructor accepts or declines a request; the student sees the result on their next sync.
    func respond(to booking: Booking, confirmed: Bool) {
        booking.status = confirmed ? .confirmed : .cancelled
        booking.pendingDecision = true
        save()
        // Reconcile reminders immediately on a local status flip — a foreground accept/decline
        // changes no scenePhase and triggers no sync, so without this a just-declined session could
        // keep its pending reminder (and fire) until the next sync.
        Task { await PushService.shared.scheduleSessionReminders() }
        guard !isPreview, let remoteID = booking.remoteID else { return }
        Task {
            let delivered = await bookingService.respond(bookingID: remoteID, confirmed: confirmed)
            booking.pendingDecision = !delivered
            save()
        }
    }

    /// Student cancels their own booking. Also RELEASES the seat hold so the slot reopens: a deleted
    /// hold recordName goes absent and is immediately re-claimable. The `holdRecordName` is nil'd only on
    /// a confirmed release, so a release that fails offline is retried by `releaseOrphanedHolds` on the
    /// next sync (delete of an already-absent hold counts as a successful release, so no infinite retry).
    func cancel(_ booking: Booking) {
        booking.status = .cancelled
        booking.pendingDecision = true
        save()
        // Cancel this session's pending reminder now, not on the next sync — a foreground cancel a
        // few minutes before start must not still fire "your session is soon".
        Task { await PushService.shared.scheduleSessionReminders() }
        guard !isPreview else { booking.holdRecordName = nil; return }
        if let hold = booking.holdRecordName {
            Task {
                if await bookingService.releaseSeat(recordName: hold) {
                    booking.holdRecordName = nil
                    save()
                }
            }
        }
        guard let remoteID = booking.remoteID else { return }
        Task {
            let delivered = await bookingService.cancel(bookingID: remoteID)
            booking.pendingDecision = !delivered
            save()
            // A not-yet-delivered cancel refunds any class-credit used — refresh so the ring ticks back up.
            if delivered, let instructorID = booking.instructorOwnerID {
                await refreshBalance(with: instructorID)
                await syncWallet()
            }
        }
    }

    // MARK: - Standing series: approve / skip / end

    /// Instructor approves (`confirmed: true`) or ends (`confirmed: false`) a whole standing series with
    /// ONE decision — never per week. Called from the de-duped series request card. Optimistically
    /// resolves local occurrences; the next sync re-derives the same state from the series decision.
    func respondSeries(_ booking: Booking, confirmed: Bool) {
        guard let sid = booking.seriesID else { return }
        let now = Date()
        if confirmed {
            for occ in incomingBookings where occ.seriesID == sid && occ.status == .pending {
                occ.status = .confirmed
            }
        } else {
            // End: future occurrences resolve cancelled (resolver-driven; the student-owned record is
            // NOT flipped, so no student fee is ever mis-attributed to an instructor-initiated end).
            for occ in incomingBookings where occ.seriesID == sid {
                if (occ.sessionStart(now: now) ?? .distantPast) >= now && occ.status != .completed {
                    occ.status = .cancelled
                }
            }
        }
        save()
        // A one-shot series approval confirms up to 12 weeks (or an end cancels them) with no sync in
        // between; reconcile reminders against the new local state right away. (endSeriesAsStudent
        // reconciles transitively — it cancels each future occurrence via `cancel`.)
        Task { await PushService.shared.scheduleSessionReminders() }
        guard !isPreview else { return }
        let studentID = booking.studentID
        Task { await bookingService.respondSeries(seriesID: sid, confirmed: confirmed, studentID: studentID) }
    }

    /// Student ends their whole standing series: cancel every FUTURE non-cancelled occurrence (each a
    /// normal student cancel), persist a local tombstone so this device's rolling top-up stops
    /// re-materializing the series, AND write a durable server-side `seriesend-<id>` decision. The
    /// server-side tombstone is what makes the end survive a reinstall / second device — without it the
    /// local UserDefaults tombstone is gone, no remote end exists, and top-up would resurrect the series
    /// (minting fresh confirmed/pending weeks) as horizon rolls forward. Past/completed weeks untouched.
    func endSeriesAsStudent(_ booking: Booking) {
        guard let sid = booking.seriesID else { return }
        markSeriesEnded(sid)
        let now = Date()
        let future = bookings.filter {
            $0.seriesID == sid && $0.status != .cancelled
                && ($0.sessionStart(now: now) ?? .distantPast) >= now
        }
        for occ in future { cancel(occ) }
        save()
        guard !isPreview else { return }
        // studentID: nil — no self-push; the resolver/top-up guard only read bookingID + respondedAt.
        Task { await bookingService.respondSeries(seriesID: sid, confirmed: false, studentID: nil) }
    }

    /// Pending requests de-duplicated so a 12-week standing series shows as ONE inbox card (its soonest
    /// pending occurrence). One-off requests pass through unchanged. Used by the instructor calendar and
    /// dashboard so a standing slot doesn't spam the inbox with 12 identical cards.
    var pendingRequestCards: [Booking] {
        let now = Date()
        // A request for a session that has already ENDED is dead — it can't be meaningfully accepted —
        // and (soonest-first) would otherwise float above every live request. Gate it out, mirroring
        // `upcomingBookings`, so the inbox only surfaces still-actionable requests.
        let pending = incomingBookings
            .filter { $0.status == .pending && ($0.sessionEnd(now: now) ?? .distantFuture) >= now }
            .sorted { ($0.sessionStart() ?? .distantFuture) < ($1.sessionStart() ?? .distantFuture) }
        var seenSeries = Set<String>()
        var out: [Booking] = []
        for booking in pending {
            if let sid = booking.seriesID {
                if seenSeries.contains(sid) { continue }
                seenSeries.insert(sid)
            }
            out.append(booking)
        }
        return out
    }

    /// A group/duet class's ROSTER — the students booked into ONE physical slot — or a singleton wrapper
    /// for a 1-on-1. The model is NOT collapsed: each seat stays its own `Booking` (so earnings, No-Show
    /// Shield, reviews and per-student decisions stay per-row); this only groups for DISPLAY.
    struct SlotGroup: Identifiable {
        let id: String
        let bookings: [Booking]
        /// The booked type's capacity (0 when uncached). A real group/duet is `>= 2`.
        let capacity: Int
        /// Render as a roster (group card / one dashboard row) vs a single 1-on-1 card.
        var isGroup: Bool { capacity >= 2 }
        /// The representative booking for the shared time/type header.
        var primary: Booking { bookings[0] }
    }

    /// Group a day's bookings by physical slot identity (instructor owner + date + time + type) so a
    /// group/duet class renders as ONE roster entity instead of N scattered rows, while a 1-on-1 stays a
    /// singleton. First-seen order is preserved. Same de-dup shape as `pendingRequestCards`, keyed on the
    /// slot instead of the series. Capacity is resolved from the booked type (`>= 2` ⇒ group).
    func sessionGroups(_ dayBookings: [Booking]) -> [SlotGroup] {
        var order: [String] = []
        var byKey: [String: [Booking]] = [:]
        for b in dayBookings {
            let key = "\(b.instructorOwnerID ?? "")|\(b.date)|\(b.time)|\(b.type)"
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(b)
        }
        return order.map { key in
            let group = byKey[key] ?? []
            return SlotGroup(id: key, bookings: group, capacity: group.first.flatMap { bookingCapacity($0) } ?? 0)
        }
    }

    /// Series the student has ended locally — a persisted tombstone (mirrors `deletedMessagesKey`) so
    /// top-up stops extending them even before the instructor's end-decision has been fetched.
    private let endedSeriesKey = "flowe.endedSeries"

    private func markSeriesEnded(_ seriesID: String) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: endedSeriesKey) ?? [])
        ids.insert(seriesID)
        UserDefaults.standard.set(Array(ids), forKey: endedSeriesKey)
    }

    private var endedSeriesIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: endedSeriesKey) ?? [])
    }

    /// Re-send anything that never reached the server — a booking made offline, or a decision
    /// taken while the network was down.
    private func flushPendingWrites() async {
        // One-offs now carry a client idempotency key (bk-<uuid>) from their first upload attempt, so
        // retry them by `pendingUpload` (not `remoteID == nil`) — re-sending the same key can't create a
        // duplicate. Series occurrences are excluded here (they retry via the deterministic path below).
        for booking in bookings where booking.pendingUpload && !booking.isRecurring {
            guard let instructorID = booking.instructorOwnerID,
                  let studentID = booking.studentID else { continue }
            await upload(booking, instructorID: instructorID, studentID: studentID)
        }
        // Series occurrences carry their deterministic recordName up front (remoteID != nil), so they
        // are retried through the idempotent series path rather than the one-off create above.
        for booking in bookings where booking.pendingUpload && booking.isRecurring {
            guard let instructorID = booking.instructorOwnerID,
                  let studentID = booking.studentID else { continue }
            await uploadSeries(booking, instructorID: instructorID, studentID: studentID)
        }
        for booking in bookings where booking.pendingDecision {
            guard let remoteID = booking.remoteID else { continue }
            let delivered = booking.status == .cancelled && booking.studentID == currentUserID
                ? await bookingService.cancel(bookingID: remoteID)
                : await bookingService.respond(bookingID: remoteID,
                                               confirmed: booking.status == .confirmed)
            booking.pendingDecision = !delivered
        }
        save()
    }

    // MARK: - Booking sync

    /// Bookings addressed to the signed-in instructor (what the dashboard and calendar show).
    var incomingBookings: [Booking] {
        guard let currentUserID else { return [] }
        return bookings.filter { $0.instructorOwnerID == currentUserID }
    }

    /// Bookings the signed-in student has made. Bookings with no `studentID` predate the shared
    /// booking system (or come from seeded preview data), so they are treated as the user's own.
    var myBookings: [Booking] {
        guard let currentUserID else { return bookings }
        return bookings.filter { $0.studentID == nil || $0.studentID == currentUserID }
    }

    /// Pull bookings for whichever side the user is on, merge in the instructor's decisions, and
    /// cache the result locally so the UI works offline.
    /// Guards against a second `syncBookings` starting while one is mid-flight. `syncBookings` suspends
    /// at several `await`s and is reachable concurrently (pull-to-refresh, sign-in `.task`, scenePhase,
    /// push delivery). Two interleaved runs could each promote the SAME waitlister into a DIFFERENT freed
    /// seat (the seat mutex can't catch distinct indices) → an overbook + orphaned hold. Set/checked
    /// synchronously on the main actor before the first await, so the check-and-set is atomic.
    private var isSyncingBookings = false

    /// One-time cutover to the booking backend. The backend is now the authoritative source for
    /// bookings, so any pre-cutover local `Booking` rows (mirrored from the old world-readable CloudKit
    /// SessionBooking records, which are NOT migrated) are cleared ONCE — otherwise they linger as
    /// ghosts that never reconcile away (the backend soft-deletes via `cancelled`, so an absent id never
    /// means "delete this local row"). Pilot booking data is disposable; users re-book against the backend.
    private func runBookingCutoverIfNeeded() {
        let key = "flowe.backend.bookingCutover.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        try? context.delete(model: Booking.self)
        try? context.save()
        UserDefaults.standard.set(true, forKey: key)
    }

    func syncBookings(asInstructor: Bool, recoverSession: Bool = false) async {
        guard !isPreview, let currentUserID else { return }
        guard !isSyncingBookings else { return }
        isSyncingBookings = true
        defer { isSyncingBookings = false }
        // User-initiated refresh/retry only: a user who signed in before the backend existed (or whose
        // refresh token was wiped) has no backend session, and a non-interactive read can't establish
        // one — so it would silently show an empty inbox forever. An explicit pull-to-refresh / retry
        // escalates to a one-time contextual Apple re-auth. Silent-first, so a user who already has a
        // session sees no prompt; once recovered, the fetch below (and every other backend call on this
        // screen) works.
        if recoverSession { await FloweBackendClient.shared.recoverSessionIfNeeded() }
        runBookingCutoverIfNeeded()
        if bookingsPhase != .loaded { bookingsPhase = .loading }
        if asInstructor { await flushPendingListing() } else { await flushPendingStudentProfile() }
        await flushPendingWrites()
        let fetched = asInstructor
            ? await bookingService.fetchForInstructor(ownerID: currentUserID)
            : await bookingService.fetchForStudent(ownerID: currentUserID)
        guard let remote = fetched else {
            if bookingsPhase != .loaded { bookingsPhase = .failed }
            return
        }
        bookingsPhase = .loaded
        guard !remote.isEmpty else {
            // A successful fetch that returned nothing still needs the reminder reconcile: it
            // clear-then-rebuilds from live LOCAL confirmed bookings, so a session cancelled while its
            // remote record was already gone doesn't leave a dangling reminder waiting on the scenePhase
            // backstop. Idempotent — reads local state, schedules nothing new when there's nothing due.
            await PushService.shared.scheduleSessionReminders()
            return
        }

        // The decision id list is the occurrence recordNames PLUS the series-level ids
        // (`series-<id>` / `seriesend-<id>`) for every distinct series seen, so the resolver can see a
        // one-time series approval or end. `fetchDecisions` already takes an arbitrary `bookingID IN`
        // list — only this caller changes.
        var decisionIDs = Set(remote.map(\.id))
        for entry in remote {
            if let sid = Booking.seriesID(fromRecordName: entry.id) {
                decisionIDs.insert("series-\(sid)")
                decisionIDs.insert("seriesend-\(sid)")
            }
        }
        let decisions = await bookingService.fetchDecisions(bookingIDs: Array(decisionIDs))
        var nextId = bookings.map(\.legacyId).max() ?? 0
        var nextOrder = bookings.map(\.order).max() ?? 0

        for entry in remote {
            // Keep the REAL event times before they're discarded — the Activity feed reads these so a
            // booking row shows when the thing it announces actually happened, not when this device
            // first saw it. Request time, decision time and cancel time are three DIFFERENT moments.
            bookingRequestedAt[entry.id] = entry.createdAt
            // A per-occurrence decision wins over the series-wide one, mirroring `status(for:decisions:)`.
            let seriesKey = Booking.seriesID(fromRecordName: entry.id).map { "series-\($0)" }
            if let decided = decisions[entry.id] ?? seriesKey.flatMap({ decisions[$0] }),
               decided.respondedAt != .distantPast {
                bookingDecidedAt[entry.id] = decided.respondedAt
            }
            if let cancelledAt = entry.modifiedAt { bookingCancelledAt[entry.id] = cancelledAt }
            let status = Self.status(for: entry, decisions: decisions)
            if let cached = bookings.first(where: { $0.remoteID == entry.id }) {
                // Don't undo a local decision whose write hasn't landed yet — that would flip the row
                // back and re-prompt / resurrect. Two cases:
                //  (1) an offline accept/decline saved since this fetch started (status re-derives
                //      .pending because the decision record isn't visible yet), and
                //  (2) an in-flight student CANCEL whose remote write failed transiently while the fetch
                //      still returned the record un-cancelled (status re-derives .confirmed). Without this
                //      the cancel is reverted to .confirmed AND flushPendingWrites then pushes a CONFIRM
                //      (it keys the retry on the now-clobbered status), permanently resurrecting it.
                let losesLocalDecision = status == .pending && cached.status != .pending
                let losesLocalCancel = cached.pendingDecision && cached.status == .cancelled && status != .cancelled
                if !losesLocalDecision && !losesLocalCancel { cached.status = status }
                // No-Show Shield: flag a fee-worthy late cancellation (instructor side only).
                if asInstructor { flagLateCancelIfNeeded(cached, entry: entry) }
                continue
            }
            nextId += 1; nextOrder += 1
            let booking = Booking(
                legacyId: nextId,
                instructorId: instructors.first { $0.ownerID == entry.instructorID }?.legacyId ?? 0,
                date: entry.date,
                time: entry.time,
                type: entry.type,
                duration: entry.duration,
                status: status,
                ownerID: currentUserID,
                order: nextOrder,
                remoteID: entry.id,
                instructorOwnerID: entry.instructorID,
                studentID: entry.studentID,
                studentName: entry.studentName
            )
            context.insert(booking)
            if asInstructor { flagLateCancelIfNeeded(booking, entry: entry) }
        }

        // STUDENT-side rolling top-up: extend every active standing series to the horizon as weeks roll
        // in. Runs on a successful fetch so it can honor a remote `seriesend` tombstone and the local
        // ended-series tombstone. The eager full-horizon batch is created at booking time, so this only
        // ADDS the newly-in-range weeks. No instructor-side write is needed — rolled-in weeks resolve to
        // confirmed against the single series-approve decision automatically.
        if !asInstructor { await topUpStandingSeries(decisions: decisions) }
        // Free the seat for any of the student's own bookings now resolved cancelled but still holding a
        // seat — this is what releases the hold on an INSTRUCTOR-initiated decline/end (the instructor
        // can't delete the student's creator-owned hold), plus a retry for any student cancel whose
        // release failed offline. Idempotent: a released hold is nil'd so it isn't re-swept.
        if !asInstructor { await releaseOrphanedHolds() }
        // STUDENT-side deterministic waitlist promotion: re-derive, from the live seat set every device
        // sees identically, whether this student is now the earliest waitlister for a slot with a freed
        // in-capacity seat, and if so move its own hold into that seat (creator-write). No server trigger.
        if !asInstructor { await promoteWaitlistedSeats() }
        // Instructor-side: warm the profiles (name + photo) of every student on the freshly-fetched
        // schedule, so their avatars render in the calendar / dashboard / request cards. Previously
        // `syncStudentProfiles()` ran ONLY once at login (FlowApp), so a booking that arrived since —
        // via pull-to-refresh or a push — showed a gradient placeholder until the app was relaunched.
        // Keyed off `remote` (the authoritative set of students on the schedule) and routed through the
        // de-duped `fetchAuthorProfiles`, which skips self/blocked/instructors and ALREADY-CACHED ids —
        // so once every current student is cached this is a cheap no-op, not a per-refresh re-download.
        if asInstructor {
            await fetchAuthorProfiles(Set(remote.compactMap { $0.studentID }))
        }
        // Reconcile local session reminders against the freshly-resolved booking set. This is THE
        // single source of truth for reminders (alongside releaseOrphanedHolds / promoteWaitlistedSeats):
        // it recomputes the desired reminders from the confirmed, future bookings and clears any whose
        // session was cancelled/declined/ended/completed or has passed — so a stale reminder can never
        // outlive its booking. Both roles reconcile: the student is reminded of their own sessions, the
        // instructor of the sessions on their schedule.
        await PushService.shared.scheduleSessionReminders()
        save()
    }

    /// Release the seat holds of any of the signed-in student's bookings that have resolved `.cancelled`
    /// but still carry a `holdRecordName`. Covers instructor decline / end-series (the seat frees on the
    /// student's device, since only the hold's creator can delete it) and retries an offline student
    /// cancel. Runs on the student side of `syncBookings` after status resolution.
    private func releaseOrphanedHolds() async {
        for booking in myBookings where booking.status == .cancelled {
            guard let hold = booking.holdRecordName else { continue }
            if await bookingService.releaseSeat(recordName: hold) {
                booking.holdRecordName = nil
            }
        }
        save()
    }

    // MARK: - Group classes: waitlist derivation + deterministic promotion
    //
    // A group/duet class is NOT a new record type — it reuses the SlotHold seat mutex with OVERFLOW
    // seats. Admitted seats are `0..<capacity`; a full-class booker atomically wins the first free
    // seat `>= capacity` (its waitlist rank = seatIndex − capacity). Waitlisted-ness is DERIVED off the
    // seat index vs the booked type's cached `LessonType.capacity` — no stored column, no BookingStatus
    // case. Promotion is a pure function of the visible SlotHold set, computed identically on every
    // device (mirrors `EventService.admitted`), and only the promoted student's OWN device performs the
    // seat move (creator-write, like `reconcileAttendance`).

    /// The seat capacity of the `LessonType` a booking was made against, resolved from the cached lesson
    /// types by the booking's instructor owner + type name (works on BOTH sides: the instructor owns the
    /// rows; a student cached them via `syncLessonTypes` when booking). Nil when no matching type is
    /// cached, so callers degrade rather than guess.
    /// Minutes to DISPLAY for a booking: prefer the CURRENT lesson type's stated duration, so a booking
    /// whose `duration` string was frozen with the old "50 min"/"55 min" guess (created before the type
    /// resolved) shows the real value. Falls back to the number parsed from the frozen string when the
    /// type isn't cached. Fixes "the type is 30 min but the session shows 50".
    func bookingDurationMinutes(_ booking: Booking) -> Int {
        if let owner = booking.instructorOwnerID,
           let mins = lessonTypes.first(where: { $0.ownerID == owner && $0.name == booking.type })?.durationMinutes,
           mins > 0 {
            return mins
        }
        return booking.durationMinutes
    }

    func bookingCapacity(_ booking: Booking) -> Int? {
        // Prefer the capacity FROZEN on the booking at claim time. That is what a seat's admitted/waitlist
        // status was decided against, so an instructor later EDITING the lesson type's capacity must not
        // retroactively reclassify existing bookings (dropping an admitted student onto the waitlist, or
        // vice-versa). Fall back to the live cached type only when no frozen value exists (legacy rows).
        if booking.bookedCapacity > 0 { return booking.bookedCapacity }
        guard let owner = booking.instructorOwnerID else { return nil }
        return lessonTypes.first(where: { $0.ownerID == owner && $0.name == booking.type })?.capacity
    }

    /// True when a booking occupies an OVERFLOW seat — i.e. it is on the waitlist, not admitted. Derived
    /// purely from the hold's seat index vs the cached group capacity; false when there is no hold, the
    /// capacity isn't cached, the type isn't a real group (`< 2`), or the booking is already cancelled
    /// (a cancelled overflow hold is being released). On the INSTRUCTOR's device incoming bookings carry
    /// no `holdRecordName` (seat index is student-private), so this is always false there — the roster
    /// shows counts only, by design.
    func isWaitlisted(_ booking: Booking) -> Bool {
        guard booking.status != .cancelled,
              let seat = booking.seatIndex,
              let cap = bookingCapacity(booking), cap >= 2 else { return false }
        return seat >= cap
    }

    /// The student's 1-based waitlist position (#1 = next in line), from the seat index vs capacity, or
    /// nil when not waitlisted. A DISPLAY hint: it counts from the raw seat index, so it can overstate
    /// the position if earlier waitlisters have left; it corrects to a real seat on the next sync when
    /// this student is promoted. The authoritative ordering lives in `promoteWaitlistedSeats`.
    func waitlistRank(for booking: Booking) -> Int? {
        guard isWaitlisted(booking), let seat = booking.seatIndex,
              let cap = bookingCapacity(booking) else { return nil }
        return seat - cap + 1
    }

    /// The (POSIX `yyyy-MM-dd` date, `HHmm` time) of a hold recordName
    /// `hold-<instr>-<yyyy-MM-dd>-<HHmm>-<seat>`, read from the TAIL so dashes inside the instructorID
    /// don't confuse it (from the end: seat, HHmm, then dd, MM, yyyy are the five trailing tokens).
    /// Reading straight off the stored hold string keeps promotion byte-consistent with the key every
    /// other device sees. Nil if the shape doesn't match.
    private static func holdSlot(_ name: String) -> (date: String, time: String)? {
        let p = name.split(separator: "-")
        guard p.count >= 7 else { return nil }   // hold, instr(>=1), yyyy, MM, dd, HHmm, seat
        let n = p.count
        return (date: "\(p[n - 5])-\(p[n - 4])-\(p[n - 3])", time: String(p[n - 2]))
    }

    /// Deterministic client-side waitlist promotion — no server trigger. For each of the signed-in
    /// student's OWN waitlisted (overflow-seat) bookings, re-derive from the live seat set whether this
    /// student is the earliest waitlister (rank 0) for a slot that now has a free in-capacity seat, and
    /// if so move its hold from the overflow seat into the lowest free admitted seat. Only this student's
    /// device can do it (creator-write). Every device computes the same rank from the same visible seat
    /// set, so nobody jumps the queue. If the rank-0 student is OFFLINE, lower-ranked online waitlisters
    /// still SEE that student's lower overflow index → compute rank > 0 → do not promote; the freed seat
    /// stays absent (can briefly look free in the picker) until the rank-0 student next syncs — a
    /// documented EventRegistration-style eventual-consistency window, seniority preserved.
    private func promoteWaitlistedSeats() async {
        guard !isPreview, let currentUserID else { return }
        let mine = myBookings.filter { isWaitlisted($0) }
        guard !mine.isEmpty else { return }
        for booking in mine {
            guard let hold = booking.holdRecordName,
                  let (dateString, token) = Self.holdSlot(hold),
                  let owner = booking.instructorOwnerID,
                  let cap = bookingCapacity(booking), cap >= 2,
                  let myK = booking.seatIndex else { continue }
            guard let live = await bookingService.fetchSlotHolds(instructorID: owner, date: dateString),
                  let liveSeats = live[token] else { continue }
            // Re-read after the await: the student may have cancelled this exact booking mid-fetch (which
            // nils holdRecordName and frees the seat). Claiming now would resurrect a dead hold.
            guard isWaitlisted(booking), booking.holdRecordName == hold else { continue }
            // My rank among overflow holders present in the live set: how many overflow seats below mine.
            let myRank = liveSeats.filter { $0 >= cap && $0 < myK }.count
            guard myRank == 0 else { continue }   // a senior waitlister is still ahead — not my turn
            let freeSeats = (0..<cap).filter { !liveSeats.contains($0) }.sorted()
            guard !freeSeats.isEmpty else { continue }
            // Claim the lowest free admitted seat; on loss (a fresh booker or a racing promotion won it)
            // try the next free seat, and abort on failure — never double-book, never drop the overflow.
            seatLoop: for seat in freeSeats {
                switch await bookingService.claimSeat(instructorID: owner, date: dateString, time: token, seat: seat) {
                case .claimed(let newName):
                    booking.holdRecordName = newName
                    save()
                    _ = await bookingService.releaseSeat(recordName: hold)   // free the old overflow seat
                    // The waitlist entry never published a SessionBooking (so a seatless waitlister never
                    // reached the instructor). Now that it holds an ADMITTED seat, publish it as a normal
                    // pending request the instructor can accept. `owner` is the instructor bound above.
                    if booking.remoteID == nil {
                        await upload(booking, instructorID: owner, studentID: currentUserID)
                    }
                    break seatLoop
                case .slotTaken:
                    continue seatLoop
                case .failed, .waitlisted:
                    break seatLoop
                }
            }
        }
        save()
    }

    /// Whether a standing series must NO LONGER be topped up (regrown) — because the student ended it on
    /// THIS device (local `endedSeriesIDs` tombstone) or on ANY device (durable `seriesend-<id>` decision).
    /// The single guard `topUpStandingSeries` applies, extracted `nonisolated static` so it's unit-testable
    /// off the main actor: this is exactly what makes `endSeriesAsStudent` stick and a one-off cancel NOT
    /// end the series. See [[flowe-recurring-series-cancel]].
    nonisolated static func seriesIsEnded(_ seriesID: String,
                                          endedLocally: Set<String>,
                                          decisions: [String: RemoteDecision]) -> Bool {
        endedLocally.contains(seriesID) || decisions["seriesend-\(seriesID)"] != nil
    }

    /// Extend each active standing series (no local ended tombstone, no fetched `seriesend` decision)
    /// whose latest materialized week is short of the horizon, materializing and uploading the missing
    /// weeks. New weeks are born `.confirmed` when the series is already approved, else `.pending`.
    private func topUpStandingSeries(decisions: [String: RemoteDecision]) async {
        guard let currentUserID else { return }
        let ended = endedSeriesIDs
        let mine = bookings.filter { $0.isRecurring && ($0.studentID == nil || $0.studentID == currentUserID) }
        let bySeries = Dictionary(grouping: mine, by: { $0.seriesID ?? "" })
        for (sid, occs) in bySeries where !sid.isEmpty {
            if Self.seriesIsEnded(sid, endedLocally: ended, decisions: decisions) { continue }
            guard let earliest = occs.compactMap({ Self.occurrenceDate($0) }).min(),
                  let template = occs.max(by: { (Self.occurrenceDate($0) ?? .distantPast) < (Self.occurrenceDate($1) ?? .distantPast) }),
                  let instructor = instructors.first(where: { $0.ownerID == template.instructorOwnerID })
                    ?? instructorPlaceholder(from: template)
            else { continue }
            let approved = decisions["series-\(sid)"]?.confirmed == true
            // Seats for a newly-in-range week honor the booked type's capacity. Prefer the value FROZEN on
            // an existing occurrence (bookedCapacity) — the live cache may be cold or the instructor a
            // hours-less placeholder, which would wrongly collapse a real group to a 1-seat slot and skip
            // its weeks. Fall back to the live lookup only when no occurrence carries a frozen capacity.
            let frozenCap = occs.map(\.bookedCapacity).max() ?? 0
            let capacity = frozenCap > 0
                ? frozenCap
                : (ownedLessonTypes(for: instructor).first { $0.name == template.type }?.capacity ?? 0)
            let calendar = Calendar.current
            // Re-scan from the series' weekday anchor on/after today — NOT just past the last materialized
            // week. `materializeSeriesOccurrences` skips any week whose recordName already exists (no dup,
            // and no redundant claim, since the seat claim sits inside that existence guard), so anchoring
            // here also RE-ATTEMPTS the seat claim for an INTERIOR week that was full at first materialize
            // and has since freed up. Anchoring at last+7 (the old behavior) dropped such a gap forever.
            let startToday = calendar.startOfDay(for: Date())
            var anchor = earliest
            while anchor < startToday {
                guard let bumped = calendar.date(byAdding: .day, value: 7, to: anchor) else { break }
                anchor = bumped
            }
            let created = await materializeSeriesOccurrences(
                instructor: instructor, from: anchor, time: template.time, type: template.type,
                duration: template.duration, seriesID: sid, approved: approved, capacity: capacity, calendar: calendar
            )
            guard !created.isEmpty else { continue }
            save()
            guard !isPreview, let instructorID = template.instructorOwnerID else { continue }
            Task { for booking in created { await uploadSeries(booking, instructorID: instructorID, studentID: currentUserID) } }
        }
    }

    /// A minimal `Instructor` carrying only the ids `materializeSeriesOccurrences` reads, for a series
    /// whose instructor listing isn't in the local cache (so top-up never stalls on a missing listing).
    private func instructorPlaceholder(from template: Booking) -> Instructor? {
        guard let ownerID = template.instructorOwnerID else { return nil }
        // A bare, uninserted value carrier — `materializeSeriesOccurrences` only reads legacyId/ownerID.
        return Instructor(legacyId: template.instructorId, ownerID: ownerID)
    }

    /// The occurrence `Date` parsed from a series booking's recordName suffix ("yyyy-MM-dd"). Used for
    /// top-up bookkeeping — deterministic and independent of `sessionStart`'s nearest-year reconstruction.
    private static func occurrenceDate(_ booking: Booking, calendar: Calendar = .current) -> Date? {
        guard let s = booking.occurrenceDateString else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = calendar.timeZone
        return f.date(from: s)
    }

    /// A booking is pending until the instructor responds; a student cancellation always wins; and a
    /// confirmed session whose time has passed has been delivered → `.completed`.
    ///
    /// The completion step lives here, in the one resolver every sync runs, so the merge writes
    /// `.completed` directly and a later sync can't revert it (the alternative — a local-only
    /// transition — would be clobbered the next time this returned `.confirmed`). Nothing else in
    /// production ever produced `.completed`, which left the Past tab, instructor earnings/sessions
    /// and the whole review flow permanently unreachable.
    /// For a standing series, a single decision covers every week, resolved here in precedence order:
    /// (1) a decision addressed to THIS occurrence — a one-off's decision, or an instructor accept/
    /// decline of a single week — wins; else (2) an instructor series-END tombstone cancels FUTURE
    /// weeks only (start ≥ end time), leaving past/completed weeks resolving as approved so reviews and
    /// earnings survive; else (3) the one-time series APPROVAL confirms every week, including weeks that
    /// rolled into the horizon after approval; else `.pending`. A student-owned cancel always wins.
    private static func status(for booking: RemoteBooking, decisions: [String: RemoteDecision],
                               now: Date = Date()) -> BookingStatus {
        if booking.cancelled { return .cancelled }
        let over = Booking.isOver(date: booking.date, time: booking.time, duration: booking.duration, now: now)

        // 1. A decision addressed to this specific occurrence id (one-off, or a single skipped/accepted
        //    week of a series). Highest precedence.
        if let decision = decisions[booking.id] {
            guard decision.confirmed else { return .cancelled }
            return over ? .completed : .confirmed
        }

        // A series occurrence with no per-week decision resolves against the series-level decisions.
        if let sid = Booking.seriesID(fromRecordName: booking.id) {
            // 2. Instructor ended the series: future weeks (start ≥ the end time) are cancelled WITHOUT
            //    touching the student-owned record, so no student fee is mis-flagged; past weeks fall
            //    through to the approval below and keep their approve→completed resolution.
            if let ended = decisions["seriesend-\(sid)"],
               let start = Booking.sessionStart(date: booking.date, time: booking.time, duration: booking.duration, now: now),
               start >= ended.respondedAt {
                return .cancelled
            }
            // 3. One-time series approval — covers weeks materialized after it too.
            if let approve = decisions["series-\(sid)"], approve.confirmed {
                return over ? .completed : .confirmed
            }
            return .pending
        }

        return .pending
    }

    /// "Thu Jul 10" → "Thu, Jul 10" to match the booking-card format.
    private static func formatDay(_ day: String) -> String {
        let parts = day.split(separator: " ")
        guard let first = parts.first else { return day }
        let rest = parts.dropFirst().joined(separator: " ")
        return rest.isEmpty ? String(first) : "\(first), \(rest)"
    }

    // MARK: - No-Show Shield

    /// The cancellation policy for a booking, resolved from the signed-in instructor's own lesson type
    /// whose name matches the booking's `type`. No matching type or no policy set → an inactive policy.
    func policy(for booking: Booking) -> CancellationPolicy {
        guard let me = currentInstructor else { return CancellationPolicy() }
        return ownedLessonTypes(for: me).first { $0.name == booking.type }?.cancellationPolicy
            ?? CancellationPolicy()
    }

    /// Whether the No-Show Shield is actually protecting anything — i.e., at least one of the
    /// instructor's own lesson types carries an active cancellation policy (a window + a fee). Drives
    /// the shield's "is it set up?" guidance so "You're covered" is never shown when nothing is.
    var hasActiveCancellationPolicy: Bool {
        guard let me = currentInstructor else { return false }
        return ownedLessonTypes(for: me).contains { $0.cancellationPolicy.isActive }
    }

    /// Price used to resolve a percentage fee — the matching lesson type's price, else the rate.
    private func sessionPrice(for booking: Booking) -> Int {
        guard let me = currentInstructor else { return 0 }
        return ownedLessonTypes(for: me).first { $0.name == booking.type }?.price ?? me.price
    }

    /// Sessions that have happened but the instructor hasn't judged yet — the "Did they show?" queue.
    var sessionsAwaitingAttendance: [Booking] {
        let now = Date()
        return incomingBookings
            .filter { $0.status == .completed && $0.attendance == .unknown }
            .sorted { ($0.sessionEnd(now: now) ?? .distantPast) > ($1.sessionEnd(now: now) ?? .distantPast) }
    }

    /// Mark whether a client showed. A no-show flags the policy fee as owed (for off-app collection);
    /// marking attended clears any fee tentatively owed for that session.
    func markAttendance(_ booking: Booking, attended: Bool) {
        booking.attendance = attended ? .attended : .noShow
        if attended {
            if booking.feeStatus == .owed { booking.feeStatus = .none; booking.feeAmount = 0 }
        } else {
            let fee = policy(for: booking).amount(sessionPrice: sessionPrice(for: booking))
            if fee > 0 { booking.feeAmount = fee; booking.feeStatus = .owed }
        }
        save()
    }

    /// Resolve an owed fee once the instructor has collected or waived it off-app.
    func resolveFee(_ booking: Booking, to status: FeeStatus) {
        guard booking.feeStatus == .owed, status == .collected || status == .waived else { return }
        booking.feeStatus = status
        save()
    }

    /// Fees currently owed to the instructor, newest session first.
    var owedFees: [Booking] {
        incomingBookings.filter { $0.feeStatus == .owed }
            .sorted { ($0.sessionEnd() ?? .distantPast) > ($1.sessionEnd() ?? .distantPast) }
    }

    /// Total currency owed across all outstanding fees.
    var totalOwed: Int { owedFees.reduce(0) { $0 + $1.feeAmount } }

    /// How many times this client has no-showed or been a fee-worthy late-cancel — the signal behind
    /// the risk flag on an upcoming booking.
    func noShowStrikes(forStudentID studentID: String) -> Int {
        incomingBookings
            .filter { $0.studentID == studentID }
            .filter { $0.attendance == .noShow || ($0.status == .cancelled && $0.feeStatus != .none) }
            .count
    }

    /// Whether an upcoming booking is worth a confirmation nudge — this client has prior strikes.
    func isRisky(_ booking: Booking) -> Bool {
        guard let sid = booking.studentID, booking.status.isUpcoming else { return false }
        return noShowStrikes(forStudentID: sid) > 0
    }

    // MARK: - Client notes (private clinical/safety notes)
    //
    // Instructor-authored PRIVATE notes about a client (injuries, pregnancy, conditions). Keyed by
    // studentID: one note per client. These live ONLY in the CloudKit private database (see
    // [[ClientNote]] + [[SwiftData-Container]]); there is deliberately NO service, NO upload path, NO
    // flushPendingWrites entry — identical private-mirror posture to [[BlockedUser]]. NEVER read a
    // ClientNote inside any *Service, and NEVER copy one onto a Booking (Booking is double-written to
    // the world-readable public SessionBooking record — that would leak health data).

    /// This instructor's single private note about a client, DECRYPTED, if one exists AND can be opened on
    /// this device. Returns nil for BOTH "no note" and "locked" (ciphertext present but the key hasn't
    /// synced here yet) — a locked note must NOT be presented as blank, or a save would overwrite it. Use
    /// `clientNoteIsLocked` to tell the two apart. Decryption happens on THIS device (the instructor holds
    /// the key); the CloudKit mirror only ever held ciphertext.
    func clientNote(forStudentID studentID: String) -> ClientNoteData? {
        guard let m = clientNotes.first(where: { $0.studentID == studentID }) else { return nil }
        switch noteCrypto.open(m.sealed, as: ClientNoteData.Sealed.self) {
        case .value(let payload): return ClientNoteData(studentID: m.studentID, updatedAt: m.updatedAt, sealed: payload)
        case .empty:              return ClientNoteData(studentID: m.studentID, updatedAt: m.updatedAt)
        case .locked:             return nil
        }
    }

    /// True when a note EXISTS but its ciphertext can't be opened on this device yet (the encryption key
    /// hasn't synced from iCloud Keychain). The editor uses this to refuse to seed-and-save over data it
    /// couldn't read — the fix for the new-device data-loss race.
    func clientNoteIsLocked(forStudentID studentID: String) -> Bool {
        guard let m = clientNotes.first(where: { $0.studentID == studentID }) else { return false }
        if case .locked = noteCrypto.open(m.sealed, as: ClientNoteData.Sealed.self) { return true }
        return false
    }

    /// Cheap glyph check — reads the opaque `flagged` hint WITHOUT decrypting (called per session row on
    /// the calendar). Reveals only that a safety note exists, never which condition.
    func clientNoteHasFlags(forStudentID studentID: String) -> Bool {
        clientNotes.first(where: { $0.studentID == studentID })?.flagged ?? false
    }

    /// Create-or-update the instructor's private note for a client (find-first-by-studentID upsert;
    /// uniqueness enforced here, not by a DB constraint). The health-sensitive fields are ENCRYPTED into
    /// `sealed` — only the opaque `flagged` hint + metadata are stored in the clear (App Store Guideline
    /// 5.1.3 — no readable health data in iCloud). Saves to the private store only.
    func saveClientNote(studentID: String, hasInjury: Bool, injuryNote: String,
                        isPregnant: Bool, pregnancyNote: String, conditions: String,
                        notes: String, emergencyContact: String, goals: String) {
        guard !studentID.isEmpty else { return }
        let note = clientNotes.first { $0.studentID == studentID }
            ?? {
                let n = ClientNote(studentID: studentID)
                context.insert(n)
                return n
            }()
        let payload = ClientNoteData.Sealed(
            hasInjury: hasInjury, injuryNote: injuryNote,
            isPregnant: isPregnant, pregnancyNote: pregnancyNote,
            conditions: conditions, notes: notes,
            emergencyContact: emergencyContact, goals: goals
        )
        note.sealed = noteCrypto.seal(payload)
        note.flagged = hasInjury || isPregnant
            || !conditions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        note.updatedAt = Date()
        save()   // context.save() + refresh() → glyphs re-render reactively
    }

    /// Flag a late cancellation for a fee. Called during the instructor's booking sync: a booking is a
    /// late-cancel when it was cancelled inside the policy's notice window before the session start.
    /// The cancel time is the record's last modification (cancel is the last write it ever receives).
    /// Idempotent — once flagged, collected or waived, it is never re-flagged.
    private func flagLateCancelIfNeeded(_ booking: Booking, entry: RemoteBooking) {
        // Only a STUDENT cancellation (SessionBooking.cancelled=1) can carry a late-cancel fee. An
        // instructor decline / series-skip / series-end resolves to `.cancelled` via a decision without
        // flipping this flag, so it correctly never incurs a fee.
        guard entry.cancelled,
              booking.status == .cancelled, booking.feeStatus == .none, booking.attendance == .unknown,
              let cancelledAt = entry.modifiedAt, let start = booking.sessionStart() else { return }
        let policy = policy(for: booking)
        guard policy.isActive else { return }
        let windowStart = start.addingTimeInterval(TimeInterval(-policy.windowHours * 3600))
        guard cancelledAt >= windowStart else { return }   // cancelled on time → no fee
        let fee = policy.amount(sessionPrice: sessionPrice(for: booking))
        guard fee > 0 else { return }
        booking.feeAmount = fee
        booking.feeStatus = .owed
    }

    // MARK: - Messaging

    /// The inbox: one row per counterpart, most recent first.
    var conversations: [ConversationSummary] {
        guard let me = currentUserID else { return [] }
        let hidden = blockedIDs
        let mine = messages.filter {
            ($0.senderID == me || $0.recipientID == me)
            && !hidden.contains($0.senderID) && !hidden.contains($0.recipientID)
        }
        let grouped = Dictionary(grouping: mine, by: \.conversationID)

        return grouped.compactMap { _, thread -> ConversationSummary? in
            guard let latest = thread.max(by: { $0.sentAt < $1.sentAt }) else { return nil }
            var counterpart = latest.counterpart(for: me)
            // Instructors carry a listing (Unsplash `img` for seeds, uploaded `photo` for real ones);
            // students carry their published StudentProfile photo. Forward the id + photo, and PREFER
            // the instructor's live listing name over the message-stored one — the message's senderName
            // is a denormalised snapshot that can be stale or a sign-in fallback ("Member"), while the
            // listing name is the authoritative identity the student already sees in Discover.
            if let listing = instructors.first(where: { $0.ownerID == counterpart.id }) {
                counterpart = Counterpart(
                    id: counterpart.id,
                    name: listing.name.isEmpty ? counterpart.name : listing.name,
                    avatarID: listing.img,
                    photo: listing.photo
                )
            } else if let sp = studentProfile(forOwnerID: counterpart.id) {
                // Mirror the instructor branch for a STUDENT counterpart: prefer the LIVE StudentProfile
                // name + photo over the message-stored snapshot (which can be stale or a "Member" sign-in
                // fallback). syncMessages warms these, so the profile is cached.
                counterpart = Counterpart(
                    id: counterpart.id,
                    name: sp.name.isEmpty ? counterpart.name : sp.name,
                    avatarID: counterpart.avatarID,
                    photo: sp.photo
                )
            } else {
                counterpart.photo = studentPhoto(forOwnerID: counterpart.id)
            }
            return ConversationSummary(
                counterpart: counterpart,
                lastMessage: latest.displayText,
                lastSentAt: latest.sentAt,
                unreadCount: thread.filter { $0.recipientID == me && !$0.isRead }.count
            )
        }
        .sorted { $0.lastSentAt > $1.lastSentAt }
    }

    /// Total unread messages, for a tab badge.
    var unreadMessageCount: Int {
        conversations.reduce(0) { $0 + $1.unreadCount }
    }

    /// Messages in one thread, oldest first.
    func thread(with counterpartID: String) -> [Message] {
        guard let me = currentUserID, !isBlocked(counterpartID) else { return [] }
        let id = Message.conversationID(me, counterpartID)
        return messages.filter { $0.conversationID == id }.sorted { $0.sentAt < $1.sentAt }
    }

    /// Append a message to a thread and publish it.
    func sendMessage(to counterpart: Counterpart, text: String) {
        guard let me = currentUserID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let message = Message(
            conversationID: Message.conversationID(me, counterpart.id),
            senderID: me,
            senderName: currentUserName,
            recipientID: counterpart.id,
            recipientName: counterpart.name,
            text: trimmed,
            sentAt: Date(),
            isRead: true,            // my own message needs no unread state
            pendingUpload: true      // cleared once it reaches the server
        )
        context.insert(message)
        save()
        guard !isPreview else { return }
        Task { await upload(message) }
    }

    private func upload(_ message: Message) async {
        // Encrypt the text end-to-end before it touches the world-readable public database. The local
        // `message.text` stays plaintext (this cache is on-device only); only the wire value is sealed.
        // If the recipient hasn't published a key yet, fall back to plaintext for this one message.
        let wireText = await messageCrypto.encrypt(
            message.text,
            conversationID: message.conversationID,
            counterpartID: message.recipientID
        ) ?? message.text
        let remoteID = await messagingService.send(
            recordName: message.recordName,          // deterministic → idempotent, never a duplicate
            conversationID: message.conversationID,
            senderID: message.senderID,
            senderName: message.senderName,
            recipientID: message.recipientID,
            recipientName: message.recipientName,
            text: wireText,
            sentAt: message.sentAt
        )
        message.remoteID = remoteID
        message.pendingUpload = remoteID == nil
        save()
    }

    /// Remove a message from the conversation. Deleting it locally isn't enough — `merge` would
    /// re-insert it on the next sync — so its id is tombstoned (persisted) to stay gone. If the
    /// message is the signed-in user's OWN, its shared-store record is deleted too (creator-write),
    /// so it stops being the source of truth; a received message isn't the reader's to delete from
    /// the store, so that one is only removed from this device's view.
    private let deletedMessagesKey = "flowe.deletedMessages"

    private func markMessageDeleted(_ id: String) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: deletedMessagesKey) ?? [])
        ids.insert(id)
        UserDefaults.standard.set(Array(ids), forKey: deletedMessagesKey)
    }

    /// Tombstones for feed posts the user deleted — so a `syncCommunity` whose fetch still returns the
    /// just-deleted post (CloudKit delete→query-index lag) can't re-insert it. Without this, a deleted
    /// post reappears in the feed on the next refresh. Mirrors `deletedMessagesKey`.
    private let deletedPostsKey = "flowe.deletedPosts"

    private func markPostDeleted(_ id: String) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: deletedPostsKey) ?? [])
        ids.insert(id)
        UserDefaults.standard.set(Array(ids), forKey: deletedPostsKey)
    }

    /// Closed block windows per sender: `[senderID: [[startEpoch, endEpoch]]]`. A message from a sender
    /// sent inside one of their windows was sent WHILE this user had them blocked, so it must stay hidden
    /// even after unblock — the merge-time `isBlocked` check alone misses messages that only sync IN after
    /// the unblock (the sender was no longer blocked by then). JSON so the nested arrays round-trip cleanly.
    private let blockWindowsKey = "flowe.blockWindows"

    private func loadBlockWindows() -> [String: [[Double]]] {
        guard let data = UserDefaults.standard.data(forKey: blockWindowsKey),
              let dict = try? JSONDecoder().decode([String: [[Double]]].self, from: data) else { return [:] }
        return dict
    }

    private func recordBlockWindow(sender: String, from: Date, to: Date) {
        var all = loadBlockWindows()
        all[sender, default: []].append([from.timeIntervalSince1970, to.timeIntervalSince1970])
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: blockWindowsKey) }
    }

    /// Whether a message from `sender` sent at `at` falls inside a past block window (sent while blocked).
    private func wasBlockedWhenSent(_ sender: String, at: Date) -> Bool {
        let t = at.timeIntervalSince1970
        return (loadBlockWindows()[sender] ?? []).contains { $0.count == 2 && t >= $0[0] && t <= $0[1] }
    }

    /// "Delete for me" — hide the message on THIS device only; the counterpart keeps their copy. The id
    /// is tombstoned so a later sync can't resurrect it. No server write.
    func deleteForMe(_ message: Message) {
        if let remoteID = message.remoteID { markMessageDeleted(remoteID) }
        context.delete(message)
        save()
    }

    /// "Delete for everyone" — sender-only, within 24h. KEEP the row but flip it to a tombstone (both
    /// sides show "deleted") and soft-delete the shared record so the counterpart's sync picks it up.
    /// Guarded, so a stale menu can't delete an out-of-window or not-mine message.
    func deleteForEveryone(_ message: Message) {
        guard message.canDeleteForEveryone(currentUserID: currentUserID),
              let remoteID = message.remoteID else { return }
        message.deleted = true
        message.text = ""
        save()
        guard !isPreview else { return }
        Task { await messagingService.deleteForEveryone(remoteID: remoteID) }
    }

    /// Delete a whole conversation from this device's inbox. Each message is tombstoned so a later
    /// sync can't resurrect the thread, then removed locally; the user's OWN messages are deleted
    /// from the shared store too (creator-write). The counterpart's copy is untouched — this is a
    /// hide-for-me, and a new incoming message re-forms the thread, matching how messaging apps
    /// behave. Mirrors `deleteMessage`, applied to the full thread.
    func deleteConversation(with counterpartID: String) {
        guard let me = currentUserID else { return }
        let id = Message.conversationID(me, counterpartID)
        let thread = messages.filter { $0.conversationID == id }
        var minesRemoteIDs: [String] = []
        for message in thread {
            if let remoteID = message.remoteID {
                markMessageDeleted(remoteID)
                if message.senderID == me { minesRemoteIDs.append(remoteID) }
            }
            context.delete(message)
        }
        save()
        guard !isPreview, !minesRemoteIDs.isEmpty else { return }
        Task {
            for remoteID in minesRemoteIDs {
                await messagingService.delete(remoteID: remoteID)
            }
        }
    }

    /// Counterparts' fetched read markers (the "Seen" indicator). In-memory only — a remote signal, not
    /// a persisted model — keyed by (conversationID, readerID). `@Observable` tracks it, so a fetched
    /// receipt re-renders the open thread.
    private var readReceipts: [RemoteReadReceipt] = []

    private func cacheReadReceipt(_ receipt: RemoteReadReceipt) {
        if let i = readReceipts.firstIndex(where: {
            $0.conversationID == receipt.conversationID && $0.readerID == receipt.readerID
        }) {
            readReceipts[i] = receipt
        } else {
            readReceipts.append(receipt)
        }
    }

    /// When `readerID` last read `conversationID`, if we've fetched their receipt — drives "Seen".
    func lastReadAt(conversationID: String, by readerID: String) -> Date? {
        readReceipts.first { $0.conversationID == conversationID && $0.readerID == readerID }?.lastReadAt
    }

    // MARK: - Presence ("last seen")

    /// Conversation partners' fetched last-seen — in-memory (a transient remote signal, not a @Model),
    /// keyed by ownerID. `@Observable` tracks it so a fetched value re-renders the open thread / inbox.
    private var presence: [String: Date] = [:]

    /// Events already registered as organizer with the backend this session — a register-once guard so
    /// reconcile doesn't re-POST /events every cycle (waste + the per-user write rate limit).
    private var registeredEventOwners: Set<String> = []

    /// When `ownerID` was last active — only while I am myself publishing presence (client reciprocity:
    /// hide mine → I see none). nil = unknown / hidden / opted-out.
    func lastSeen(ownerID: String) -> Date? {
        guard presenceVisiblePref else { return nil }
        return presence[ownerID]
    }

    /// Whether this user shows their "last seen" — OPT-IN (off until enabled). Local mirror of the server
    /// flag; also gates the client display + fetch so a failed sync can't leave the two diverged.
    private var presenceVisiblePref: Bool { UserDefaults.standard.object(forKey: "notif.presence") as? Bool ?? false }

    /// Heartbeat MY last-seen (server-stamped) on foreground / sign-in / thread-open. Skipped unless
    /// opted in, so nothing about the user is stored server-side while hidden.
    func heartbeatPresence() async {
        guard !isPreview, currentUserID != nil, presenceVisiblePref else { return }
        await FloweBackendClient.shared.heartbeatPresence()
    }

    /// Fetch last-seen for the given partners, and EVICT any the server withheld (a partner who opted out
    /// is dropped, not left stale). Skipped entirely when I've hidden my own presence.
    func refreshPresence(for ownerIDs: [String]) async {
        guard !isPreview, currentUserID != nil, presenceVisiblePref, !ownerIDs.isEmpty else { return }
        let fetched = await FloweBackendClient.shared.fetchPresence(ownerIDs: ownerIDs)
        for id in ownerIDs { presence[id] = fetched[id] }   // nil assignment removes → honours opt-out
    }

    /// Opt in/out of showing "last seen" — server-enforced (hiding yours also hides everyone else's from
    /// you). Clears the cache immediately so nothing stale keeps rendering after opt-out.
    func setPresenceVisible(_ on: Bool) {
        if !on { presence.removeAll() }
        Task { await FloweBackendClient.shared.setPresenceVisible(on) }
    }

    /// Mark everything received in a thread as read (called when the thread is opened), and — so the
    /// SENDER can show "Seen" — publish our own read marker for the conversation, stamped to the newest
    /// message we hold (a value in the sender's own clock domain, so their `sentAt <= lastReadAt`
    /// comparison is skew-proof for the messages they sent).
    func markThreadRead(with counterpartID: String) {
        guard let me = currentUserID else { return }
        let id = Message.conversationID(me, counterpartID)
        var changed = false
        for message in messages where message.conversationID == id
            && message.recipientID == me && !message.isRead {
            message.isRead = true
            changed = true
        }
        if changed { save() }
        guard !isPreview, changed else { return }   // only acknowledge when we newly read something
        let readUpTo = messages.filter { $0.conversationID == id }.map(\.sentAt).max() ?? Date()
        Task { await messagingService.publishReadReceipt(conversationID: id, readerID: me, lastReadAt: readUpTo) }
    }

    /// Pull all messages involving this user and cache anything new.
    func syncMessages() async {
        guard !isPreview, let me = currentUserID else { return }
        for message in messages where message.pendingUpload && message.remoteID == nil {
            await upload(message)
        }
        let remote = await messagingService.fetchMessages(for: me)
        await merge(remote, me: me)
        await heartbeatPresence()
        await refreshPresence(for: conversations.map { $0.counterpart.id })
        // Warm counterpart profile photos so a DM from a non-booker student (uncached post-launch) shows a
        // face, not initials — syncStudentProfiles only warms counterparts at launch.
        await fetchAuthorProfiles(Set(conversations.map { $0.counterpart.id }))
    }

    /// Refresh a single thread — cheaper than a full sync while a conversation is open.
    func syncThread(with counterpartID: String) async {
        guard !isPreview, let me = currentUserID else { return }
        let convo = Message.conversationID(me, counterpartID)
        let remote = await messagingService.fetchThread(conversationID: convo)
        await merge(remote, me: me)
        // Pull the counterpart's read marker so our own outgoing bubbles can show "Seen".
        if let receipt = await messagingService.fetchReadReceipt(conversationID: convo, readerID: counterpartID) {
            cacheReadReceipt(receipt)
        }
        // Heartbeat me + pull the partner's last-seen while the thread is open (highest-signal moment).
        await heartbeatPresence()
        await refreshPresence(for: [counterpartID])
    }

    /// Ensure my end-to-end messaging keypair exists and my public key is published, so others can
    /// send me encrypted messages. Cheap to call on every sign-in — the publish no-ops when unchanged.
    func activateMessaging() async {
        guard !isPreview, let me = currentUserID else { return }
        // Reconcile the presence opt-out to the backend on every sign-in/launch, so a toggle that failed
        // to sync (offline) is re-pushed and the server flag converges to the user's actual choice.
        await FloweBackendClient.shared.setPresenceVisible(presenceVisiblePref)
        await messageCrypto.activate(ownerID: me)
    }

    private func merge(_ remote: [RemoteMessage], me: String) async {
        guard !remote.isEmpty else { return }
        // Tombstoned ids the user deleted — never re-insert them, or a sync would resurrect a
        // message they removed from the conversation.
        let deleted = Set(UserDefaults.standard.stringArray(forKey: deletedMessagesKey) ?? [])

        // Decrypt EVERYTHING first. Decryption is the only suspension point in this function, so
        // doing it up front lets the known-check + insert pass below run with no `await` in between
        // — which is what makes it safe against a second `merge` (two feeds sync at once) slipping
        // the same record past the check before either has inserted it. Without this the pre-await
        // `known` snapshot is stale by insert time and the same message lands twice.
        var decrypted: [(RemoteMessage, String)] = []
        for entry in remote where !deleted.contains(entry.id) {
            let counterpartID = entry.senderID == me ? entry.recipientID : entry.senderID
            // Keep the SEALED wire value when the key isn't readable yet (propagation lag / a flaky read /
            // the sender rotated keys) instead of freezing a lost placeholder — `retryStuckMessages`
            // re-decrypts it once the key lands, and `Message.displayText` shows a placeholder meanwhile.
            let plaintext = await messageCrypto.decrypt(
                entry.text, conversationID: entry.conversationID, counterpartID: counterpartID
            ) ?? entry.text
            decrypted.append((entry, plaintext))
        }

        // Read `known` AFTER the awaits (so a sibling merge's just-saved rows are visible), and shield
        // a message I sent that is still uploading: its deterministic recordName is known before the
        // upload finishes, so the copy fetched back from the server can't land as a second row.
        var known = Set(messages.compactMap {
            $0.remoteID ?? ($0.senderID == me ? $0.recordName : nil)
        })
        var changed = false
        for (entry, plaintext) in decrypted {
            if known.contains(entry.id) {
                // Existing row: pick up a "delete for everyone" flip the counterpart just made — the
                // merge otherwise only INSERTS, so without this the recipient never sees the tombstone.
                if entry.deleted, let local = messages.first(where: { $0.remoteID == entry.id }), !local.deleted {
                    local.deleted = true
                    local.text = ""
                    changed = true
                }
                continue
            }
            known.insert(entry.id)   // also dedup an id that appears twice within this one batch
            // A message from someone this user has BLOCKED — or sent DURING a past block window, even if
            // it only syncs in now that they're unblocked — must never be STORED, or it surfaces the
            // moment it lands. Tombstone it. Messages sent BEFORE the block (outside every window) were
            // legitimately delivered and are unaffected.
            if isBlocked(entry.senderID) || wasBlockedWhenSent(entry.senderID, at: entry.sentAt) {
                markMessageDeleted(entry.id)
                continue
            }
            let message = Message(
                remoteID: entry.id,
                conversationID: entry.conversationID,
                senderID: entry.senderID,
                senderName: entry.senderName,
                recipientID: entry.recipientID,
                recipientName: entry.recipientName,
                // A message deleted-for-everyone before we ever fetched it lands straight as a tombstone.
                text: entry.deleted ? "" : plaintext,
                sentAt: entry.sentAt,
                // Anything I sent is implicitly read; anything received starts unread.
                isRead: entry.senderID == me
            )
            message.deleted = entry.deleted
            context.insert(message)
            changed = true
        }
        if changed { save() }
        // Self-heal any message still holding sealed ciphertext now that we may have the key (a fresh
        // fetch this cycle, or the sender's key having propagated since it first synced). Runs after
        // EVERY merge so a stuck message resolves on the next sync instead of being lost forever.
        await retryStuckMessages(me: me)
    }

    /// Re-attempt decryption for any locally-cached message still holding sealed ciphertext. This is the
    /// counterpart to keeping the wire value in `merge` (rather than a placeholder): the moment the
    /// counterpart's key becomes readable, the frozen "🔒 Message unavailable" rows turn back into real
    /// text. `decrypt` drops a stale cached key on failure, so a sender key-rotation also recovers here.
    private func retryStuckMessages(me: String) async {
        let stuck = messages.filter { MessageCrypto.isSealed($0.text) }
        guard !stuck.isEmpty else { return }
        var healed = false
        for m in stuck {
            let counterpartID = m.senderID == me ? m.recipientID : m.senderID
            if let plain = await messageCrypto.decrypt(
                m.text, conversationID: m.conversationID, counterpartID: counterpartID
            ) {
                m.text = plain
                healed = true
            }
        }
        if healed { save() }
    }

    /// People this user can start a conversation with. A student writes to instructors they can
    /// see; an instructor writes to students who have booked them.
    func addressBook(asInstructor: Bool) -> [Counterpart] {
        if asInstructor {
            let students = incomingBookings.compactMap { booking -> Counterpart? in
                guard let id = booking.studentID, !isBlocked(id) else { return nil }
                return Counterpart(id: id, name: booking.studentName, photo: studentPhoto(forOwnerID: id))
            }
            return dedupe(students)
        }
        // Instructors in the feed, plus any already booked — a student must still be able to reach
        // an instructor who has since gone hidden (lapsed subscription).
        let bookedIDs = Set(myBookings.compactMap(\.instructorOwnerID))
        let reachable = instructors.filter { listing in
            guard let id = listing.ownerID, !isBlocked(id) else { return false }
            return bookedIDs.contains(id) || Self.isEligible(listing)
        }
        let listings = reachable.compactMap { listing -> Counterpart? in
            guard let id = listing.ownerID else { return nil }
            return Counterpart(id: id, name: listing.name, avatarID: listing.img, photo: listing.photo)
        }
        return dedupe(listings)
    }

    private func dedupe(_ people: [Counterpart]) -> [Counterpart] {
        var seen = Set<String>()
        return people.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Reviews

    /// Reviews written about an instructor, newest first. The block-filter still hides reviews whose
    /// author id is known, but a PUBLIC wall review carries no studentID (stripped server-side for
    /// privacy — see [[BookingBackend]]), so a blocked author's public review isn't hidden here. It stays
    /// reportable, and a report triages it for removal — the Guideline 1.2 obligation is met via reporting.
    func reviews(for instructorOwnerID: String) -> [Review] {
        reviews
            .filter { $0.instructorID == instructorOwnerID && !isBlocked($0.studentID) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Reviews of the signed-in instructor's own listing.
    var myReviews: [Review] {
        guard let me = currentUserID else { return [] }
        return reviews(for: me)
    }

    /// Average rating and count for an instructor, derived from real reviews.
    /// Returns nil when there are none — "no reviews yet" is a different thing from a 0.0 rating.
    func rating(for instructorOwnerID: String) -> (average: Double, count: Int)? {
        let scored = reviews(for: instructorOwnerID).filter { $0.rating > 0 }
        guard !scored.isEmpty else { return nil }
        let total = scored.reduce(0) { $0 + $1.rating }
        return (Double(total) / Double(scored.count), scored.count)
    }

    /// The student's own review of a booking, if they've written one.
    func myReview(for booking: Booking) -> Review? {
        guard let bookingID = booking.remoteID, let me = currentUserID else { return nil }
        return reviews.first { $0.bookingID == bookingID && $0.studentID == me }
    }

    /// Only a completed session the student actually booked can be reviewed. This is the whole point
    /// of anchoring a review to a booking rather than to an instructor.
    func canReview(_ booking: Booking) -> Bool {
        booking.status == .completed
            && booking.remoteID != nil          // never reached the shared store → not a real session
            && booking.instructorOwnerID != nil
            // A locally-cached booking with no student stamped on it is this user's own, by the
            // same rule `myBookings` applies.
            && (booking.studentID == nil || booking.studentID == currentUserID)
    }

    /// Write or replace the review for a booking, then publish it.
    @discardableResult
    func submitReview(for booking: Booking, rating: Int, text: String) -> Review? {
        guard canReview(booking),
              let bookingID = booking.remoteID,
              let instructorID = booking.instructorOwnerID,
              let me = currentUserID else { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let review = myReview(for: booking) ?? {
            let fresh = Review(bookingID: bookingID, instructorID: instructorID, studentID: me)
            context.insert(fresh)
            return fresh
        }()

        review.studentName = currentUserName
        review.rating = rating
        review.text = trimmed
        review.createdAt = Date()
        review.pendingUpload = true
        save()

        guard !isPreview else { return review }
        Task { await upload(review) }
        return review
    }

    private func upload(_ review: Review) async {
        switch await reviewService.submit(
            bookingID: review.bookingID,
            instructorID: review.instructorID,
            studentID: review.studentID,
            studentName: review.studentName,
            rating: review.rating,
            text: review.text,
            createdAt: review.createdAt
        ) {
        case .published(let id):
            review.remoteID = id
            review.pendingUpload = false
        case .notEarned:
            // The backend rejected it (no completed booking with this instructor) — drop the local review
            // so it isn't retried every sync forever. The client `canReview` gate should prevent reaching here.
            context.delete(review)
        case .failed:
            review.pendingUpload = true   // transient — retry on the next sync
        }
        save()
    }

    /// Pull reviews that matter to this user: the ones about them if they're an instructor, and the
    /// ones they've written either way (so "already reviewed" survives a reinstall).
    func syncReviews(asInstructor: Bool) async {
        guard !isPreview, let me = currentUserID else { return }

        for review in reviews where review.pendingUpload && review.remoteID == nil {
            await upload(review)
        }

        var remote = await reviewService.fetchForStudent(ownerID: me)
        if asInstructor {
            remote += await reviewService.fetchForInstructor(ownerID: me)
        }
        merge(remote)

        // An instructor's public rating is published with their listing so the student feed doesn't
        // have to fetch every review to sort the catalog.
        if asInstructor { refreshMyPublishedRating() }
    }

    /// Reviews ABOUT another instructor, for a student viewing their profile. Distinct from
    /// `syncReviews(asInstructor:)`, which only pulls the signed-in user's own reviews — a student
    /// browsing someone else's listing has none of those cached. Non-pruning: it reuses `merge`,
    /// which only inserts/updates, so it can never delete a `Review` the open profile is rendering
    /// (the deleted-SwiftData-model trap `EventDetailView` documents does not apply here).
    func syncReviews(forInstructor ownerID: String) async {
        guard !isPreview else { return }
        let remote = await reviewService.fetchForInstructor(ownerID: ownerID)
        merge(remote)
    }

    private func merge(_ remote: [RemoteReview]) {
        guard !remote.isEmpty else { return }
        var changed = false
        for entry in remote {
            // Match on the stable OPAQUE id (both reads carry it) OR — for a just-written local review not
            // yet assigned its remote id — on the real bookingID (only the author's own rows carry it).
            if let existing = reviews.first(where: {
                $0.remoteID == entry.id || (!entry.bookingID.isEmpty && $0.bookingID == entry.bookingID)
            }) {
                // The remote copy wins — it is the one other people see.
                let adoptBooking = !entry.bookingID.isEmpty && existing.bookingID != entry.bookingID
                let adoptStudent = !entry.studentID.isEmpty && existing.studentID != entry.studentID
                guard existing.remoteID != entry.id
                        || existing.rating != entry.rating
                        || existing.text != entry.text
                        || existing.studentName != entry.studentName
                        || adoptBooking || adoptStudent else { continue }
                existing.remoteID = entry.id
                existing.rating = entry.rating
                existing.text = entry.text
                existing.studentName = entry.studentName
                existing.createdAt = entry.createdAt
                existing.pendingUpload = false
                // Adopt the authoritative non-empty fields — the author's own fetch corrects a public row
                // that arrived with bookingID/studentID stripped for privacy.
                if adoptBooking { existing.bookingID = entry.bookingID }
                if adoptStudent { existing.studentID = entry.studentID }
            } else {
                context.insert(Review(
                    remoteID: entry.id,
                    bookingID: entry.bookingID,
                    instructorID: entry.instructorID,
                    studentID: entry.studentID,
                    studentName: entry.studentName,
                    rating: entry.rating,
                    text: entry.text,
                    createdAt: entry.createdAt
                ))
            }
            changed = true
        }
        if changed { save() }
    }

    /// Recompute the signed-in instructor's rating from real reviews and republish the listing.
    private func refreshMyPublishedRating() {
        guard let me = currentInstructor, let ownerID = currentUserID else { return }
        guard let summary = rating(for: ownerID) else { return }
        guard me.rating != summary.average || me.reviews != summary.count else { return }
        me.rating = summary.average
        me.reviews = summary.count
        commit()
    }

    // MARK: - Blocking & reporting (App Store Review Guideline 1.2)

    var blockedIDs: Set<String> { Set(blocked.map(\.blockedID)) }

    func isBlocked(_ ownerID: String?) -> Bool {
        guard let ownerID else { return false }
        return blockedIDs.contains(ownerID)
    }

    /// Block someone. Their messages, their listing and any route to start a new conversation with
    /// them disappear from this user's app. Idempotent.
    func block(id: String, name: String) {
        guard !id.isEmpty, !blockedIDs.contains(id) else { return }
        context.insert(BlockedUser(blockedID: id, blockedName: name))
        save()
        mirrorBlockedToAppGroup()
    }

    func unblock(_ ownerID: String) {
        let now = Date()
        for entry in blocked where entry.blockedID == ownerID {
            // Remember exactly when they were blocked, so their messages sent during the block stay hidden
            // even if they only sync in AFTER this unblock.
            recordBlockWindow(sender: ownerID, from: entry.createdAt, to: now)
            context.delete(entry)
        }
        // Purge (and tombstone) any of their during-block messages that already landed locally.
        for m in messages where m.senderID == ownerID && wasBlockedWhenSent(ownerID, at: m.sentAt) {
            if let id = m.remoteID { markMessageDeleted(id) }
            context.delete(m)
        }
        save()
        mirrorBlockedToAppGroup()
    }

    /// Share the current block list with the Notification Service Extension (App Group) so a blocked
    /// user's DM push never reveals its content. Call whenever `blocked` changes or is loaded.
    func mirrorBlockedToAppGroup() {
        AvatarCache.writeBlocked(Array(blockedIDs))
    }

    /// File a report. Returns whether it reached the server so the UI doesn't thank the user for a
    /// report that never sent.
    func report(reportedID: String,
                reportedName: String,
                content: ReportedContent,
                contentID: String,
                reason: ReportReason,
                snapshot: String,
                details: String) async -> Bool {
        guard !isPreview, let me = currentUserID else { return true }
        return await reportService.submit(
            reporterID: me,
            reportedID: reportedID,
            reportedName: reportedName,
            content: content,
            contentID: contentID,
            reason: reason,
            snapshot: snapshot,
            details: details
        )
    }

    // MARK: - Account deletion

    /// Erase this account: every record the user created in the shared store, then the local cache.
    ///
    /// Returns false if the shared store could not be cleared (offline, signed out of iCloud), and
    /// in that case wipes nothing locally either. Keeping the account intact so the user can retry
    /// is far better than signing them out while their records stay world-readable — a half-deleted
    /// account is exactly what Guideline 5.1.1(v) is meant to prevent.
    func deleteAccount() async -> Bool {
        // A missing ownerID must FAIL, never silently skip. This was `if let me = currentUserID { … }`,
        // so a nil id (session not yet hydrated, a transient sign-in state) skipped the ENTIRE public
        // sweep and still went on to report a successful deletion — leaving the InstructorListing and
        // every public LessonType alive in the shared store. To the user that reads exactly as "delete
        // didn't remove my session types", and a same-Apple-ID re-signup then shows students the old
        // profile, because the public records were never touched. You cannot delete an account whose
        // identity you don't know: bail so the caller surfaces the failure and the user can retry.
        if !isPreview {
            guard let me = currentUserID, !me.isEmpty else { return false }
            guard await deletionService.deleteAllRecords(ownerID: me) else { return false }
        }
        // Release the user's public seat mutexes BEFORE the local Bookings are wiped: a booking's
        // `holdRecordName` is the ONLY handle to its `SlotHold`, and only the hold's creator may delete
        // it. Skip this and every active hold is orphaned in the public DB, freezing a cap-1 private
        // slot as "Full" forever. Must run while the local Bookings still exist.
        await releaseMyHolds()
        // Series-decision stopgap: `decision-series-<id>` / `decision-seriesend-<id>` records live in a
        // synthetic bookingID namespace the public sweep can't reach (it derives decision names from real
        // SessionBookings). Collect the user's own series IDs from local bookings and delete those decision
        // records directly. Best-effort; only the creating instructor's own records actually delete.
        let seriesIDs = Array(Set(bookings.compactMap(\.seriesID)))
        if !seriesIDs.isEmpty { await bookingService.deleteSeriesDecisions(seriesIDs: seriesIDs) }
        // Erase the local SwiftData store (both configs). For the private-mirrored types this alone is
        // NOT enough — SwiftData's batch delete may not tombstone to CloudKit — so the private mirror is
        // wiped server-side next.
        // Gate on the wipe actually committing — see `deleteAll`. If local rows survive, the zone delete
        // below is undone the moment SwiftData next syncs them back up.
        guard Self.deleteAll(context) else {
            refresh()
            return false
        }
        // Wipe the PRIVATE CloudKit mirror zone so nothing re-syncs DOWN on a same-Apple-ID re-signin
        // (the real "delete everything" guarantee for private data — bookings, lesson types, and the
        // private-only ClientNotes that have no public backstop). Gate deletion success on it: a real
        // failure (network drop, rate-limit) must NOT be reported as a completed deletion, or the user's
        // own private data comes back. The account stays signed in so they can retry; the flow is
        // idempotent (public+local are already empty, the zone delete simply re-runs).
        guard await deletePrivateMirrorZone() else {
            refresh()
            return false
        }
        // DM identity: drop the iCloud-Keychain private key + derived caches so a re-created account
        // regenerates a FRESH keypair instead of resurrecting the old cryptographic identity.
        messageCrypto.wipeIdentity()
        // ClientNote encryption key — drop it too so a re-created account can't resurrect old notes.
        noteCrypto.wipe()
        // Device-global (NOT owner-scoped) local state that would otherwise leak to the next account
        // on this device — a saved-instructor wishlist, block-time windows, and delete/end tombstones.
        let d = UserDefaults.standard
        d.removeObject(forKey: Self.savedInstructorsKey)
        d.removeObject(forKey: blockWindowsKey)
        d.removeObject(forKey: deletedMessagesKey)
        d.removeObject(forKey: deletedPostsKey)
        d.removeObject(forKey: endedSeriesKey)
        savedInstructorIDs = []
        currentUserID = nil
        currentUserName = ""
        refresh()
        // App-Group residue the record sweep never touches: cached counterpart avatars + block mirror.
        // Runs AFTER refresh — refresh re-mirrors an (empty) block list to the App Group, so purging
        // first would just be overwritten; purging last leaves the key truly absent.
        AvatarCache.purgeAll()
        return true
    }

    /// Delete every `SlotHold` this user created, via the local Bookings that hold the only reference.
    private func releaseMyHolds() async {
        for booking in bookings {
            guard let hold = booking.holdRecordName else { continue }
            _ = await bookingService.releaseSeat(recordName: hold)
        }
    }

    /// Remove the NSPersistentCloudKitContainer private mirror zone, deleting ALL mirrored private
    /// records server-side in one op. Necessary because SwiftData's `delete(model:)` is batch-backed and
    /// may not propagate tombstones to CloudKit — without this the private DB re-hydrates the local store
    /// on the next sign-in with the same Apple ID. (Local store is already emptied by `deleteAll`, so
    /// nothing re-pushes to recreate the zone.)
    ///
    /// Returns whether the private mirror is now known-gone. A missing zone (never synced / already
    /// deleted) is SUCCESS — there was nothing to erase. A real failure (network, rate-limit, auth) is
    /// NOT success: the caller must not report a completed deletion, or the private data survives.
    private func deletePrivateMirrorZone() async -> Bool {
        #if CLOUDKIT_ENABLED
        guard !isPreview else { return true }
        let db = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone")
        do {
            _ = try await db.deleteRecordZone(withID: zoneID)
            return true
        } catch let ck as CKError {
            // The zone never existed (brand-new account that never synced private data) or is already
            // gone — nothing to wipe, so the private mirror IS empty. Everything else (network drop,
            // requestRateLimited, serverRejectedRequest, notAuthenticated, …) is a genuine failure.
            if ck.code == .zoneNotFound { return true }
            if ck.code == .partialFailure,
               let byZone = ck.partialErrorsByItemID as? [CKRecordZone.ID: Error],
               byZone.values.allSatisfy({ ($0 as? CKError)?.code == .zoneNotFound }) {
                return true
            }
            return false
        } catch {
            return false
        }
        #else
        return true
        #endif
    }

    // MARK: - Community feed

    /// The feed as this reader should see it: blocked authors gone (Guideline 1.2 — a block has to
    /// cover posts, not just messages), and posts on their way out already hidden.
    var visiblePosts: [FeedPost] {
        posts.filter { !isBlocked($0.ownerID) && !$0.pendingDelete }
    }

    /// Whether the signed-in user wrote this post — the only person allowed to delete it, and the
    /// one person who shouldn't be offered a Report button for it.
    func isMine(_ post: FeedPost) -> Bool {
        guard let currentUserID, let author = post.ownerID else { return false }
        return author == currentUserID
    }

    func isMine(_ comment: PostComment) -> Bool {
        guard let currentUserID else { return false }
        return comment.authorID == currentUserID
    }

    /// Instructors this user has actually had a session with. A shout-out or a check-in names an
    /// instructor, and letting anyone name anyone would make the feed a place to fabricate
    /// endorsements — the same failure the booking-anchored review system exists to avoid.
    var postableInstructors: [Counterpart] {
        // Completed only, matching `canReview`. Any-booking would include requests the instructor
        // *declined*, which is precisely the fabricated endorsement this is meant to prevent: a
        // student could be turned down and still publish a post naming that instructor.
        let booked = Set(
            myBookings
                .filter { $0.status == .completed }
                .compactMap(\.instructorOwnerID)
        )
        let people = instructors.compactMap { listing -> Counterpart? in
            guard let id = listing.ownerID, booked.contains(id), !isBlocked(id) else { return nil }
            return Counterpart(id: id, name: listing.name, avatarID: listing.img)
        }
        return dedupe(people)
    }

    /// Post types this user can currently write. Without a session behind them, only a tip.
    var availablePostTypes: [PostType] {
        postableInstructors.isEmpty ? [.tip] : [.tip, .checkin, .review]
    }

    /// Resolve who to SHOW as the author of a record, LIVE, from their current profile — never the
    /// frozen name/photo denormalised onto the record when it was written. The single shared resolver
    /// behind every author render site (community posts + comments, reviews, booking rows, event
    /// organizers), so a student who completes their profile after posting is recognised everywhere.
    ///
    /// Precedence, cache-first (no `await`, no fetch on the render path — reads only the in-memory
    /// `@Observable` arrays, so a profile that lands via `fetchAuthorProfiles` re-renders the row):
    ///   1. SELF — the signed-in user's own identity is always locally current, so their own
    ///      posts/comments reflect an edit with no round-trip. Instructor session → own listing;
    ///      student session → own `StudentProfile`; either falls back to the live session name.
    ///   2. INSTRUCTOR cache — a listing gives an Unsplash `img` avatar even with no uploaded photo,
    ///      and the catalog is warm (syncCatalog runs before syncCommunity). Tried before students.
    ///   3. STUDENT profile cache — the changeable public source of truth, fetched by exact ownerID.
    ///   4. SNAPSHOT — the record's denormalised name, so it degrades to exactly today's behaviour
    ///      and never renders blank when the snapshot held something.
    func displayIdentity(ownerID: String?, fallbackName: String) -> AuthorIdentity {
        let fb = AuthorIdentity(name: fallbackName, img: "", photo: nil)
        guard let id = ownerID, !id.isEmpty else { return fb }
        // 1) Own identity — always locally current.
        if id == currentUserID {
            if let ins = currentInstructor {
                let n = ins.name.isEmpty ? (currentUserName.isEmpty ? fallbackName : currentUserName) : ins.name
                return AuthorIdentity(name: n, img: ins.img, photo: ins.photo)
            }
            let p = currentStudentProfile
            let n = (p?.name.isEmpty == false) ? p!.name : (currentUserName.isEmpty ? fallbackName : currentUserName)
            return AuthorIdentity(name: n, img: "", photo: p?.photo)
        }
        // 2) Instructor catalog cache (Unsplash img avatar even without an uploaded photo).
        if let ins = instructors.first(where: { $0.ownerID == id }) {
            return AuthorIdentity(name: ins.name.isEmpty ? fallbackName : ins.name, img: ins.img, photo: ins.photo)
        }
        // 3) Student profile cache (fetched by exact ownerID via fetchAuthorProfiles).
        if let sp = studentProfiles.first(where: { $0.ownerID == id }), !sp.name.isEmpty {
            return AuthorIdentity(name: sp.name, img: "", photo: sp.photo)
        }
        // 4) Frozen snapshot — never worse than today.
        return fb
    }

    /// Pre-warm the resolver's cache for a batch of authors seen in the feed / a comment thread.
    ///
    /// Idempotent, and NON-ENUMERABLE-SAFE: it only ever fetches ownerIDs already harvested from
    /// posts/comments (i.e. ids we already know), never a broad `StudentProfile` query — students stay
    /// undiscoverable. Instructors are skipped (they resolve from the catalog cache), as are self and
    /// blocked authors. Upserts into `studentProfiles`; the `@Observable` write re-renders open rows.
    /// Warm student profiles by ownerID. Set `refreshVisibility` on COMMUNITY-ROSTER surfaces (event
    /// "who's going", class-mates, instructor circle): a roster filters by `communityVisible`, and a peer
    /// cached BEFORE they opted in would keep reading `false` and be wrongly hidden — the reported
    /// "participating people not visible for others" bug. It re-fetches a cached-but-not-visible peer
    /// (they may have opted in since) while still skipping already-visible ones, so it stays cheap.
    func fetchAuthorProfiles(_ ownerIDs: Set<String>, refreshVisibility: Bool = false) async {
        guard !isPreview else { return }
        let wanted = ownerIDs
            .subtracting([currentUserID].compactMap { $0 })
            .subtracting(blockedIDs)
            .filter { id in !instructors.contains(where: { $0.ownerID == id }) }
            // Not cached → fetch. Cached → normally skip (the feed path — re-downloading every author's
            // full StudentProfile + photo on each sync is wasteful; a profile edit rides the owner's own
            // republish). For a roster, ALSO re-fetch a cached peer whose cached copy reads not-visible.
            .filter { id in
                guard let cached = studentProfiles.first(where: { $0.ownerID == id }) else { return true }
                return refreshVisibility && !cached.communityVisible
            }
        guard !wanted.isEmpty else { return }
        let listings = await studentDirectory.fetch(ownerIDs: Array(wanted))
        guard !listings.isEmpty else { return }
        upsert(listings)
        save()
    }

    /// Replies on a post, oldest first, minus blocked authors.
    func comments(for post: FeedPost) -> [PostComment] {
        guard let remoteID = post.remoteID else { return [] }
        return postComments
            .filter { $0.postID == remoteID && !isBlocked($0.authorID) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Write a post and publish it. `instructorName` is required for the types that name one.
    ///
    /// A post needs a caption **or** a photo, not both: an image on its own is a complete post, and
    /// requiring words under it would be a rule the feed doesn't need.
    func addPost(type: PostType, instructorName: String?, text: String, image: Data? = nil) {
        guard let me = currentUserID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || image != nil else { return }
        let named = type.needsInstructor ? instructorName : nil

        let post = FeedPost(
            legacyId: (posts.map(\.legacyId).max() ?? 0) + 1,
            type: type,
            user: currentUserName,
            instructor: named,
            text: trimmed,
            image: image,
            hasImage: image != nil,
            ownerID: me,
            // Marked pending up front: if the app dies before the upload finishes, the next sync
            // retries it rather than losing what the user wrote.
            pendingUpload: true
        )
        context.insert(post)

        guard !isPreview else {
            // Previews and UI tests have no shared store to reach, so the write is already as
            // delivered as it will ever get. Leaving the flag set would strand every post under a
            // permanent "Posting…", which reads as a stuck upload rather than as offline mode.
            post.pendingUpload = false
            save()
            return
        }
        save()
        Task { await upload(post) }
    }

    private func upload(_ post: FeedPost) async {
        guard let authorID = post.ownerID else { return }
        let remoteID = await communityService.publish(
            authorID: authorID,
            authorName: post.user,
            type: post.type.rawValue,
            instructorName: post.instructor ?? "",
            text: post.text,
            image: post.image,
            createdAt: post.createdAt
        )
        post.remoteID = remoteID
        post.pendingUpload = remoteID == nil
        save()

        // The user may have deleted this post while the publish was in flight. Withdraw it now
        // rather than leaving it world-readable until the next sync.
        if post.pendingDelete, let remoteID {
            if await communityService.deletePost(id: remoteID) { deleteLocally(post) }
            save()
        }
    }

    /// Delete the user's own post. Permitted because they are the record's `_creator`; the public
    /// database enforces that, so there is no client-side check to bypass.
    func deletePost(_ post: FeedPost) {
        guard isMine(post) else { return }
        guard !isPreview else { return deleteLocally(post) }

        // A nil remoteID does NOT mean "never published": it is also nil for the whole duration of
        // the publish round-trip, which is longest offline. Deleting locally in that window would
        // destroy the row while `upload` is still suspended, the record would land on the server
        // anyway, and the next sync would re-insert a post the user was told had been withdrawn.
        // Mark it and let the flush retry once an id exists.
        post.pendingDelete = true
        save()
        guard let remoteID = post.remoteID else { return }
        Task {
            if await communityService.deletePost(id: remoteID) { deleteLocally(post) }
            save()
        }
    }

    private func deleteLocally(_ post: FeedPost) {
        if let remoteID = post.remoteID {
            markPostDeleted(remoteID)   // so a lagging sync fetch can't re-insert it
            for comment in postComments where comment.postID == remoteID { context.delete(comment) }
        }
        context.delete(post)
        save()
    }

    /// Toggle this reader's like.
    ///
    /// The count is not a field anyone shares write access to — it is the number of `CommunityLike`
    /// records the post has, and this user only ever creates or deletes their own (see
    /// `CommunityService`). The local numbers move immediately so the tap feels answered, and the
    /// next sync replaces them with what the server actually holds.
    /// One person who liked a post, resolved for the "Liked by" list.
    struct PostLiker: Identifiable, Equatable {
        let id: String          // ownerID
        let name: String
        let img: String         // instructor listing avatar id, if any
        let photo: Data?        // uploaded photo, if any
    }

    /// Liker ownerIDs per post remoteID. The feed itself only needs the COUNT, but the "Liked by"
    /// list needs identities — `RemoteLike` carries the liker's `authorID`, which `refreshEngagement`
    /// otherwise collapses into a bare count, so we stash the ids here to name them on demand.
    private(set) var likeAuthorsByPost: [String: [String]] = [:]

    /// Everyone who liked a post, as displayable rows — the data behind the Instagram-style "Liked by"
    /// sheet, open to any viewer. Blocked likers are hidden. The signed-in user's OWN like is folded in
    /// from `post.liked` so the list always agrees with the heart and the count even before a like
    /// (or unlike) has round-tripped to the server.
    func likers(for post: FeedPost) -> [PostLiker] {
        var ids = post.remoteID.map { likeAuthorsByPost[$0] ?? [] } ?? []
        if let me = currentUserID {
            if post.liked && !ids.contains(me) { ids.insert(me, at: 0) }
            if !post.liked { ids.removeAll { $0 == me } }
        }
        return ids
            .filter { !isBlocked($0) }
            .map { id in
                let ident = displayIdentity(ownerID: id, fallbackName: "")
                return PostLiker(id: id, name: ident.name, img: ident.img, photo: ident.photo)
            }
    }

    /// Refresh the liker list for a single post (called when the "Liked by" sheet opens), so it reflects
    /// likes that landed since the last full engagement sweep and warms the likers' profiles for names
    /// and avatars. Targeted — one post's likes, not the whole feed's.
    func refreshLikers(for post: FeedPost) async {
        guard !isPreview, let remoteID = post.remoteID else { return }
        guard let likes = await communityService.fetchLikes(postIDs: [remoteID]) else { return }
        likeAuthorsByPost[remoteID] = likes.map(\.authorID)
        await fetchAuthorProfiles(Set(likes.map(\.authorID)))   // saves + refreshes
    }

    func toggleLike(_ post: FeedPost) {
        post.liked.toggle()
        post.likes = max(0, post.likes + (post.liked ? 1 : -1))
        post.pendingLike = true
        save()

        guard !isPreview else {
            post.pendingLike = false   // seeded/preview post — there is nothing to deliver
            save()
            return
        }
        // A real post has no remoteID while it is still uploading or was written offline. Leaving
        // `pendingLike` set keeps it in the flush queue; clearing it here would drop the like
        // silently and the next engagement refresh would reset the heart.
        guard let remoteID = post.remoteID, let me = currentUserID else { return }
        Task {
            let delivered = await communityService.setLike(post.liked, postID: remoteID, authorID: me)
            post.pendingLike = !delivered
            save()
        }
    }

    /// A bookmark is one reader's private shelf — it stays local by design and is never published.
    func toggleSave(_ post: FeedPost) {
        post.saved.toggle()
        save()
    }

    /// Reply to a post.
    func addComment(to post: FeedPost, text: String) {
        guard let me = currentUserID, let postID = post.remoteID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let comment = PostComment(
            postID: postID,
            authorID: me,
            authorName: currentUserName,
            text: trimmed,
            pendingUpload: true
        )
        context.insert(comment)
        recountComments(postID: postID)

        guard !isPreview else { return }
        Task { await upload(comment) }
    }

    private func upload(_ comment: PostComment) async {
        let remoteID = await communityService.addComment(
            postID: comment.postID,
            authorID: comment.authorID,
            authorName: comment.authorName,
            text: comment.text,
            createdAt: comment.createdAt
        )
        comment.remoteID = remoteID
        comment.pendingUpload = remoteID == nil
        save()

        if comment.pendingDelete, let remoteID {
            if await communityService.deleteComment(id: remoteID) {
                let postID = comment.postID
                context.delete(comment)
                recountComments(postID: postID)
            }
        }
    }

    /// Delete the user's own reply.
    func deleteComment(_ comment: PostComment) {
        guard isMine(comment) else { return }
        let postID = comment.postID
        guard !isPreview else {
            context.delete(comment)
            recountComments(postID: postID)
            return
        }
        // Same in-flight window as `deletePost`: a nil remoteID may just mean the publish hasn't
        // returned yet, so mark rather than destroy and let the flush withdraw it.
        comment.pendingDelete = true
        save()
        guard let remoteID = comment.remoteID else { return }
        Task {
            guard await communityService.deleteComment(id: remoteID) else { return }
            context.delete(comment)
            recountComments(postID: postID)
        }
    }

    private func recountComments(postID: String) {
        save()
        if let post = posts.first(where: { $0.remoteID == postID }) {
            post.comments = comments(for: post).count
            save()
        }
    }

    // MARK: - Community sync

    /// Pull the shared feed, cache it locally so the tab works offline, then refresh the engagement
    /// counts that live in their own records.
    func syncCommunity() async {
        guard !isPreview else { return }
        if communityPhase != .loaded { communityPhase = .loading }
        await flushPendingCommunityWrites()
        guard let posts = await communityService.fetchRecentPosts() else {
            if communityPhase != .loaded { communityPhase = .failed }
            return
        }
        communityPhase = .loaded
        mergePosts(posts)
        // Warm the resolver so posts by students who have since completed their profile show the
        // current name/photo, not the snapshot frozen at post time. By known ownerID only.
        await fetchAuthorProfiles(Set(self.posts.compactMap(\.ownerID)))
        await refreshEngagement()
        await fetchMissingPostImages()
    }

    /// Download the photos of posts that have one but haven't got it yet.
    ///
    /// Separate from `mergePosts` because the feed query deliberately doesn't carry assets (see
    /// `CommunityService.postMetadataKeys`). Newest first and capped per pass, so opening the tab
    /// costs a bounded amount of data no matter how much of the feed has photos; the rest arrive on
    /// later syncs. A photo already cached is never fetched twice.
    private func fetchMissingPostImages() async {
        let wanted = posts
            .filter { $0.hasImage && $0.image == nil && !$0.pendingDelete }
            .compactMap(\.remoteID)
        guard !wanted.isEmpty else { return }

        let images = await communityService.fetchImages(postIDs: wanted)
        guard !images.isEmpty else { return }
        for post in posts {
            guard let remoteID = post.remoteID, let data = images[remoteID] else { continue }
            post.image = data
        }
        save()
    }

    /// Refresh one post's replies without touching the post list.
    ///
    /// The comments sheet cannot call `syncCommunity`: that prunes cached posts, including the very
    /// post the sheet is displaying, and reading a deleted SwiftData model traps at runtime.
    func syncComments(for post: FeedPost) async {
        guard !isPreview, let remoteID = post.remoteID else { return }
        await flushPendingCommunityWrites()
        guard let remote = await communityService.fetchComments(postIDs: [remoteID]) else { return }
        mergeComments(remote, for: [remoteID])
        // Same as the feed: resolve commenters' current identity by their known ownerIDs.
        await fetchAuthorProfiles(Set(comments(for: post).map(\.authorID)))
    }

    /// Re-send anything that never reached the server: a post written offline, a like taken while
    /// the network was down, a deletion the server never confirmed.
    private func flushPendingCommunityWrites() async {
        for post in posts where post.pendingUpload && post.remoteID == nil {
            await upload(post)
        }
        for post in posts where post.pendingDelete {
            guard let remoteID = post.remoteID else { continue }
            if await communityService.deletePost(id: remoteID) { deleteLocally(post) }
        }
        save()
        for post in posts where post.pendingLike {
            guard let remoteID = post.remoteID, let me = currentUserID else { continue }
            post.pendingLike = !(await communityService.setLike(
                post.liked, postID: remoteID, authorID: me
            ))
        }
        for comment in postComments where comment.pendingUpload && comment.remoteID == nil {
            await upload(comment)
        }
        for comment in postComments where comment.pendingDelete {
            guard let remoteID = comment.remoteID else { continue }
            if await communityService.deleteComment(id: remoteID) {
                let postID = comment.postID
                context.delete(comment)
                recountComments(postID: postID)
            }
        }
        save()
    }

    private func mergePosts(_ remote: [RemotePost]) {
        guard !remote.isEmpty else { return }
        let known = Set(posts.compactMap(\.remoteID))
        // Never re-insert a post the user deleted: CloudKit's delete may not have propagated to the
        // query index yet, so the fetch can still return the ghost — without this it reappears.
        let tombstoned = Set(UserDefaults.standard.stringArray(forKey: deletedPostsKey) ?? [])
        var nextId = posts.map(\.legacyId).max() ?? 0

        for entry in remote where !known.contains(entry.id) && !tombstoned.contains(entry.id) {
            nextId += 1
            context.insert(FeedPost(
                legacyId: nextId,
                type: PostType(rawValue: entry.type) ?? .tip,
                user: entry.authorName,
                instructor: entry.instructorName.isEmpty ? nil : entry.instructorName,
                text: entry.text,
                // The photo itself arrives in a later pass — this only records that there is one.
                hasImage: entry.hasImage,
                ownerID: entry.authorID,
                remoteID: entry.id,
                createdAt: entry.createdAt
            ))
        }
        prunePosts(against: remote)
        save()
    }

    /// Drop cached posts their authors have since deleted.
    ///
    /// The fetch is capped, so only prune inside the window it actually covers — anything older
    /// than the oldest row returned simply wasn't looked at. Very recent posts are spared too:
    /// CloudKit is eventually consistent, and a post that hasn't propagated to the query index yet
    /// is not a deleted post.
    private func prunePosts(against remote: [RemotePost]) {
        guard let oldest = remote.map(\.createdAt).min() else { return }
        let live = Set(remote.map(\.id))
        // A post cached locally but missing from the fetch is either DELETED or just NOT-YET-INDEXED
        // (CloudKit's query index lags a fresh write by seconds). We hold a short settle window so a
        // brand-new post that hasn't hit the index yet — most often the author's own, just-uploaded —
        // isn't mistaken for a deletion and pruned right after posting. 60s comfortably covers real
        // index lag while letting a peer's delete disappear on the next refresh, not 5 minutes later.
        // (The reliable, refresh-fast fix is a soft-delete tombstone — a deletion that travels as DATA,
        // not as absence — which removes this guesswork entirely. Tracked as a follow-up.)
        let settled = Date(timeIntervalSinceNow: -60)
        for post in posts {
            guard let remoteID = post.remoteID, !live.contains(remoteID),
                  post.createdAt >= oldest, post.createdAt < settled else { continue }
            deleteLocally(post)
        }
    }

    /// Replace the cached like counts and comments with what the shared store holds.
    private func refreshEngagement() async {
        let ids = posts.compactMap(\.remoteID)
        guard !ids.isEmpty, let me = currentUserID else { return }

        // A nil here means the query failed, which is not the same as "nobody liked anything" —
        // treating them alike would zero every count the moment the user went offline.
        if let likes = await communityService.fetchLikes(postIDs: ids) {
            let byPost = Dictionary(grouping: likes, by: \.postID)
            // Keep the liker ids (not just the count) so the "Liked by" list can name them, and warm
            // their profiles so the names/avatars resolve without a per-open round-trip.
            await fetchAuthorProfiles(Set(likes.map(\.authorID)))
            for post in posts {
                guard let remoteID = post.remoteID else { continue }
                let rows = byPost[remoteID] ?? []
                likeAuthorsByPost[remoteID] = rows.map(\.authorID)
                let mine = rows.contains { $0.authorID == me }
                if post.pendingLike {
                    // An undelivered tap: keep the user's own state, and keep the count consistent
                    // with it. Overwriting the count unconditionally showed a filled heart beside a
                    // total that excluded the very like it represents.
                    post.likes = rows.count + (post.liked && !mine ? 1 : 0) - (!post.liked && mine ? 1 : 0)
                } else {
                    post.likes = rows.count
                    post.liked = mine
                }
            }
        }

        if let remote = await communityService.fetchComments(postIDs: ids) {
            mergeComments(remote, for: ids)
        }
        save()
    }

    private func mergeComments(_ remote: [RemoteComment], for postIDs: [String]) {
        let known = Set(postComments.compactMap(\.remoteID))
        for entry in remote where !known.contains(entry.id) {
            context.insert(PostComment(
                remoteID: entry.id,
                postID: entry.postID,
                authorID: entry.authorID,
                authorName: entry.authorName,
                text: entry.text,
                createdAt: entry.createdAt
            ))
        }
        // The fetch is the complete set for these posts, so a cached reply that isn't in it was
        // deleted by its author and must stop being visible here. Anything still queued for upload
        // is ours and was never in the fetch to begin with.
        //
        // The `settled` window matters as much as the membership test: CloudKit's public query
        // index is eventually consistent, so a reply saved seconds ago routinely does not come back
        // yet. Without it, sending a reply and pulling to refresh makes your own reply vanish.
        // Same reasoning — and same window — as `prunePosts`.
        let live = Set(remote.map(\.id))
        let covered = Set(postIDs)
        let settled = Date(timeIntervalSinceNow: -300)
        for comment in postComments where covered.contains(comment.postID) && !comment.pendingUpload {
            guard let remoteID = comment.remoteID, !live.contains(remoteID),
                  comment.createdAt < settled else { continue }
            context.delete(comment)
        }
        save()

        for post in posts where post.remoteID != nil {
            let count = comments(for: post).count
            if post.comments != count { post.comments = count }
        }
    }

    // MARK: - Events

    /// The outcome of the most recent join attempt, surfaced by the events list / detail as an alert
    /// and cleared once shown. `.missedOut` is a lost race; `.notSent` is a failed write.
    enum JoinOutcome: Equatable {
        case missedOut(title: String)
        case notSent(title: String)
    }

    /// Set by `join` and by the sync reconciliation, consumed + cleared by `EventsListView` /
    /// `EventDetailView`.
    var lastJoinOutcome: JoinOutcome?

    // MARK: - Event approval (organizer accepts join requests, like lesson bookings)

    /// A student's standing with one event.
    enum EventRequestState: Equatable { case notRequested, requested, accepted, declined }

    /// Registration rows per event id — kept so an ORGANIZER can list who's requested. Populated by
    /// `reconcileAttendance` from the public store.
    private(set) var eventRegistrationRows: [String: [RemoteRegistration]] = [:]
    /// Organizer decisions per event: `[eventID: [studentID: accepted]]`. Absence of a key = still
    /// pending (undecided). Populated by `reconcileAttendance`.
    private(set) var eventDecisions: [String: [String: Bool]] = [:]

    /// The signed-in student's standing with an event: not requested → requested (awaiting the
    /// organizer) → accepted / declined.
    func requestState(for event: CommunityEvent) -> EventRequestState {
        guard let me = currentUserID, let remoteID = event.remoteID else {
            return event.joined ? .requested : .notRequested
        }
        // A student who has LEFT (or never joined) has no live registration → `joined == false`, and is
        // NOT going — even though the organizer's `accepted` EventDecision persists server-side (a student
        // can't delete the organizer's record). Check this BEFORE the decision, or "Leave this event"
        // leaves them still showing as accepted while their registration (and the spot) is already gone.
        guard event.joined else { return .notRequested }
        if let accepted = eventDecisions[remoteID]?[me] { return accepted ? .accepted : .declined }
        return .requested
    }

    /// Pending join requests for an event I organize — registrations with no decision yet, oldest first.
    func pendingRequests(for event: CommunityEvent) -> [RemoteRegistration] {
        guard let remoteID = event.remoteID else { return [] }
        let decided = eventDecisions[remoteID] ?? [:]
        return (eventRegistrationRows[remoteID] ?? [])
            .filter { decided[$0.studentID] == nil }
            .sorted { $0.joinedAt < $1.joinedAt }
    }

    /// Students I've accepted into an event I organize.
    func acceptedGuests(for event: CommunityEvent) -> [RemoteRegistration] {
        guard let remoteID = event.remoteID else { return [] }
        let decided = eventDecisions[remoteID] ?? [:]
        return (eventRegistrationRows[remoteID] ?? [])
            .filter { decided[$0.studentID] == true }
            .sorted { $0.joinedAt < $1.joinedAt }
    }

    /// Total undecided requests across every event I organize — a dashboard/badge signal.
    var myEventsPendingRequestCount: Int {
        myEvents.reduce(0) { $0 + pendingRequests(for: $1).count }
    }

    /// Organizer accepts or declines one request. Writes an `EventDecision` (I'm the creator — I can't
    /// edit the student's own registration), optimistically caches it, then reconciles.
    func respondToEventRequest(_ registration: RemoteRegistration, accepted: Bool) {
        guard let me = currentUserID,
              let event = events.first(where: { $0.remoteID == registration.eventID }) else { return }
        // Don't oversubscribe: an accept that would push accepted attendees past a set capacity is refused
        // (the student-side join pre-checks capacity, but the organizer's accept path had no ceiling).
        if accepted, event.capacity > 0 {
            let current = eventDecisions[registration.eventID] ?? [:]
            let acceptedCount = current.values.filter { $0 }.count
            let alreadyAcceptedThis = current[registration.studentID] == true
            if !alreadyAcceptedThis, acceptedCount >= event.capacity { return }
        }
        eventDecisions[registration.eventID, default: [:]][registration.studentID] = accepted   // optimistic
        save()
        guard !isPreview else { return }
        Task {
            _ = await eventService.setEventDecision(
                accepted: accepted, eventID: registration.eventID,
                studentID: registration.studentID, organizerID: me
            )
            await refreshAttendance(for: event)
        }
    }

    /// The events a student should see: blocked organizers gone, deletions already hidden, and a
    /// cancelled event hidden from everyone *except* someone who joined it — they keep seeing it wear
    /// a "Cancelled" badge, which is the only way they learn of the cancellation (there is no push).
    var visibleEvents: [CommunityEvent] {
        events.filter { !isBlocked($0.organizerID) && !$0.pendingDelete && (!$0.cancelled || $0.joined) }
    }

    // MARK: - Opportunities (Flowe Pro career marketplace)

    /// Open opportunities the signed-in instructor can browse — excludes their OWN posts, closed/filled
    /// ones, and blocked posters. Newest first. Distance ranking + eligibility gating land with the
    /// full browse screen; this is the cold-start feed. See [[FlowePro]].
    var openOpportunities: [Opportunity] {
        opportunities
            .filter { $0.status == .open && $0.posterID != currentUserID && !isBlocked($0.posterID) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// The signed-in instructor's OWN posted opportunities (any status), for the manage screen.
    var myOpportunities: [Opportunity] {
        guard let me = currentUserID else { return [] }
        return opportunities.filter { $0.posterID == me }.sorted { $0.createdAt > $1.createdAt }
    }

    /// The browse feed for a STUDENT: open opportunities they can actually act on. A student has no
    /// instructor listing, so the eligibility gate blocks them on `certifiedOnly` posts — surfacing those
    /// would be a wall of "you can't apply". So the student browse is the `openToAll` slice (apprentice /
    /// assistant / front-desk / space), which is exactly the student-facing half of [[FlowePro]].
    var studentBrowsableOpportunities: [Opportunity] {
        Self.studentBrowsable(openOpportunities)
    }

    /// Opportunities the signed-in user has an ACTIVE (non-withdrawn) application to — the "Applied" tab
    /// of the student browse, where they track each application's pipeline stage. Newest post first.
    var myAppliedOpportunities: [Opportunity] {
        guard let me = currentUserID else { return [] }
        return Self.appliedOpportunities(opportunities, applications: opportunityApplications, applicantID: me)
    }

    // Pure filters behind the two properties above — extracted so they're unit-testable without a live
    // store / SwiftData container (see FloweUnitTests/OpportunityBrowseTests). Behaviour lives here; the
    // properties just supply the current inputs.

    /// The `openToAll` slice a student may apply to. Input is expected already status/poster/blocked-filtered.
    /// `nonisolated` — pure over its inputs, touches no actor state, so it's callable off the main actor.
    nonisolated static func studentBrowsable(_ open: [Opportunity]) -> [Opportunity] {
        open.filter { $0.eligibility == .openToAll }
    }

    /// Opportunities `applicantID` has a live (non-withdrawn) application to, matched by the opportunity
    /// `key` the application stored, newest post first. Withdrawn applications drop out so a withdrawn
    /// gig leaves the Applied tab.
    nonisolated static func appliedOpportunities(_ opportunities: [Opportunity],
                                                 applications: [OpportunityApplication],
                                                 applicantID: String) -> [Opportunity] {
        let appliedKeys = Set(
            applications
                .filter { $0.applicantID == applicantID && !$0.withdrawn }
                .map(\.opportunityID)
        )
        return opportunities
            .filter { appliedKeys.contains($0.key) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Post a new opportunity: create it locally (poster = me, location from my studio listing), then
    /// publish it to the public catalog. Offline/preview leaves it local with its deterministic name,
    /// so it still shows on the manage screen and uploads on the next flush path.
    func addOpportunity(kind: OpportunityKind, eligibility: OpportunityEligibility,
                        title: String, about: String, payText: String, commitment: String) {
        guard let me = currentUserID else { return }
        let ins = currentInstructor
        let posterName = (ins?.name.isEmpty == false) ? ins!.name : currentUserName
        let opp = Opportunity(
            posterID: me, posterName: posterName, kind: kind, eligibility: eligibility, status: .open,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            about: about.trimmingCharacters(in: .whitespacesAndNewlines),
            location: ins?.address ?? "",
            payText: payText.trimmingCharacters(in: .whitespacesAndNewlines),
            commitment: commitment.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date()
        )
        opp.latitude = ins?.latitude
        opp.longitude = ins?.longitude
        opp.remoteID = opp.recordName   // deterministic up front — the poster owns/edits this record
        context.insert(opp)
        save()
        guard !isPreview else { return }
        Task { await uploadOpportunity(opp) }
    }

    private func uploadOpportunity(_ opp: Opportunity) async {
        let saved = await opportunityService.publish(
            recordName: opp.recordName,
            posterID: opp.posterID, posterName: opp.posterName,
            kind: opp.kindRaw, eligibility: opp.eligibilityRaw, status: opp.statusRaw,
            title: opp.title, about: opp.about, location: opp.location,
            latitude: opp.latitude, longitude: opp.longitude,
            payText: opp.payText, commitment: opp.commitment,
            startsAt: opp.startsAt, createdAt: opp.createdAt
        )
        opp.remoteID = saved ?? opp.recordName
        save()
    }

    /// Close an opportunity (no longer accepting) — flips status locally + on the server.
    func closeOpportunity(_ opp: Opportunity) {
        opp.statusRaw = OpportunityStatus.closed.rawValue
        save()
        guard !isPreview, let rid = opp.remoteID else { return }
        Task { await opportunityService.setStatus(recordName: rid, status: opp.statusRaw) }
    }

    /// Delete an opportunity — removes it locally and from the shared store (creator-write).
    func deleteOpportunity(_ opp: Opportunity) {
        let rid = opp.remoteID
        context.delete(opp)
        save()
        guard !isPreview, let rid else { return }
        Task { await opportunityService.delete(recordName: rid) }
    }

    // MARK: - Opportunity applications (Flowe Pro Phase 4)

    /// The signed-in user's own application to an opportunity (to resolve the applied/withdrawn state).
    func myApplication(for opportunity: Opportunity) -> OpportunityApplication? {
        guard let me = currentUserID else { return nil }
        return opportunityApplications.first { $0.opportunityID == opportunity.key && $0.applicantID == me }
    }

    /// Active applications to an opportunity I posted — the poster's inbox for that opp (withdrawn hidden,
    /// blocked applicants dropped). Oldest first, so the earliest applicant leads.
    func applications(for opportunity: Opportunity) -> [OpportunityApplication] {
        opportunityApplications
            .filter { $0.opportunityID == opportunity.key && !$0.withdrawn && !isBlocked($0.applicantID) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Apply to an opportunity (idempotent — re-applying updates the note / un-withdraws). Creates the
    /// applicant-owned record locally + publishes it, addressed to the poster.
    func apply(to opportunity: Opportunity, note: String) {
        guard let me = currentUserID, me != opportunity.posterID else { return }
        // A user with their own instructor listing is applying as an instructor; otherwise as a student.
        let role: ApplicantRole = (currentInstructor != nil) ? .instructor : .student
        let app = myApplication(for: opportunity) ?? {
            let fresh = OpportunityApplication(
                opportunityID: opportunity.key, posterID: opportunity.posterID,
                applicantID: me, applicantName: currentUserName, role: role)
            context.insert(fresh)
            return fresh
        }()
        app.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        app.withdrawn = false
        app.remoteID = app.recordName
        app.pendingUpload = true
        save()
        guard !isPreview else { return }
        Task { await uploadApplication(app) }
    }

    /// Withdraw my application — flips the flag locally + on the server (kept, not deleted, so the poster
    /// sees it disappear rather than a dangling record).
    func withdrawApplication(for opportunity: Opportunity) {
        guard let app = myApplication(for: opportunity) else { return }
        app.withdrawn = true
        app.pendingUpload = true
        save()
        guard !isPreview else { return }
        Task { await uploadApplication(app) }
    }

    private func uploadApplication(_ app: OpportunityApplication) async {
        let saved = await opportunityService.applyToOpportunity(
            recordName: app.recordName, opportunityID: app.opportunityID, posterID: app.posterID,
            applicantID: app.applicantID, applicantName: app.applicantName,
            applicantRole: app.applicantRoleRaw, note: app.note, withdrawn: app.withdrawn,
            createdAt: app.createdAt)
        app.remoteID = saved ?? app.recordName
        app.pendingUpload = false   // upload confirmed — sync may adopt server truth again
        save()
    }

    // MARK: - Application pipeline stage (Phase 4b)

    /// The current pipeline stage of one application — the poster's decision if any, else `.applied`.
    func stage(for application: OpportunityApplication) -> ApplicationStage {
        applicationDecisions.first {
            $0.opportunityID == application.opportunityID && $0.applicantID == application.applicantID
        }?.stage ?? .applied
    }

    /// The signed-in APPLICANT's stage on an opportunity they applied to (drives "Shortlisted" / "Hired"
    /// / "Not selected" in the apply bar). `.applied` until the poster decides.
    func myApplicationStage(for opportunity: Opportunity) -> ApplicationStage {
        guard let me = currentUserID else { return .applied }
        return applicationDecisions.first {
            $0.opportunityID == opportunity.key && $0.applicantID == me
        }?.stage ?? .applied
    }

    /// Poster moves an applicant to a stage: upsert the decision (they're the creator → can edit it),
    /// then publish it addressed to the applicant.
    func setStage(for application: OpportunityApplication, to stage: ApplicationStage) {
        guard let me = currentUserID, me == application.posterID else { return }
        let decision = applicationDecisions.first {
            $0.opportunityID == application.opportunityID && $0.applicantID == application.applicantID
        } ?? {
            let fresh = ApplicationDecision(opportunityID: application.opportunityID,
                                            applicantID: application.applicantID, posterID: me)
            context.insert(fresh)
            return fresh
        }()
        decision.stageRaw = stage.rawValue
        decision.updatedAt = Date()
        decision.remoteID = decision.recordName
        save()
        guard !isPreview else { return }
        Task {
            let saved = await opportunityService.setDecision(
                recordName: decision.recordName, opportunityID: decision.opportunityID,
                applicantID: decision.applicantID, posterID: me, stage: stage.rawValue,
                updatedAt: decision.updatedAt)
            decision.remoteID = saved ?? decision.recordName
            save()
        }
    }

    /// Pull open opportunities (the browse feed) + my own from the public catalog and merge them into
    /// the local cache. Insert-by-remoteID with a status refresh for ones already held. Offline / preview
    /// no-ops. This is what makes a poster's opportunity reach OTHER instructors in production.
    func syncOpportunities() async {
        guard !isPreview, let me = currentUserID else { return }
        async let openRemote = opportunityService.fetchOpen()
        async let mineRemote = opportunityService.fetchMine(posterID: me)
        let remotes = ((await openRemote) ?? []) + ((await mineRemote) ?? [])
        guard !remotes.isEmpty else { return }

        let known = Set(opportunities.compactMap(\.remoteID))
        var changed = false
        for r in remotes {
            if let existing = opportunities.first(where: { $0.remoteID == r.id }) {
                // A poster may have closed/filled it since we last saw it.
                if existing.statusRaw != r.status { existing.statusRaw = r.status; changed = true }
            } else if !known.contains(r.id) {
                let o = Opportunity(
                    remoteID: r.id, posterID: r.posterID, posterName: r.posterName,
                    kind: OpportunityKind(rawValue: r.kind) ?? .cover,
                    eligibility: OpportunityEligibility(rawValue: r.eligibility) ?? .openToAll,
                    status: OpportunityStatus(rawValue: r.status) ?? .open,
                    title: r.title, about: r.about, location: r.location,
                    payText: r.payText, commitment: r.commitment,
                    startsAt: r.startsAt, createdAt: r.createdAt)
                o.latitude = r.latitude; o.longitude = r.longitude
                context.insert(o)
                changed = true
            }
        }

        // Applications: the poster's inbox (addressed to me) + my own (as an applicant). Merge by
        // recordName, updating note/withdrawn on ones already held.
        async let inbox = opportunityService.fetchApplications(posterID: me)
        async let mineApps = opportunityService.fetchMyApplications(applicantID: me)
        let remoteApps = ((await inbox) ?? []) + ((await mineApps) ?? [])
        for r in remoteApps {
            if let existing = opportunityApplications.first(where: { $0.recordName == r.id || $0.remoteID == r.id }) {
                // Don't clobber a local edit still uploading — a query-index lag returns the pre-edit copy
                // and would revert a just-made withdrawal. Adopt server truth only once the upload confirms.
                if !existing.pendingUpload, existing.note != r.note || existing.withdrawn != r.withdrawn {
                    existing.note = r.note; existing.withdrawn = r.withdrawn; changed = true
                }
            } else {
                let a = OpportunityApplication(
                    opportunityID: r.opportunityID, posterID: r.posterID,
                    applicantID: r.applicantID, applicantName: r.applicantName,
                    role: ApplicantRole(rawValue: r.applicantRole) ?? .instructor,
                    note: r.note, withdrawn: r.withdrawn, createdAt: r.createdAt)
                a.remoteID = r.id
                context.insert(a)
                changed = true
            }
        }

        // Pipeline decisions: mine-as-poster + mine-as-applicant. Upsert the stage by recordName.
        async let posterDec = opportunityService.fetchDecisions(posterID: me)
        async let myDec = opportunityService.fetchMyDecisions(applicantID: me)
        let remoteDecisions = ((await posterDec) ?? []) + ((await myDec) ?? [])
        for r in remoteDecisions {
            if let existing = applicationDecisions.first(where: { $0.recordName == r.id || $0.remoteID == r.id }) {
                if existing.stageRaw != r.stage { existing.stageRaw = r.stage; existing.updatedAt = r.updatedAt; changed = true }
            } else {
                let d = ApplicationDecision(opportunityID: r.opportunityID, applicantID: r.applicantID,
                                           posterID: r.posterID,
                                           stage: ApplicationStage(rawValue: r.stage) ?? .applied,
                                           updatedAt: r.updatedAt)
                d.remoteID = r.id
                context.insert(d)
                changed = true
            }
        }
        if changed { save() }
    }

    // MARK: - Peer recommendations (Flowe Pro Phase 5)

    /// Recommendations addressed to an instructor — their profile's peer endorsements. Newest first;
    /// a blocked author's endorsement is hidden, like a blocked student's review.
    func recommendations(for ownerID: String) -> [InstructorRecommendation] {
        Self.recommendations(recommendations, for: ownerID, blocked: blockedIDs)
    }

    /// Pure filter behind `recommendations(for:)` — extracted `nonisolated static` so it's unit-testable
    /// without a live store (see FloweUnitTests/RecommendationTests), like the opportunity-browse filters.
    nonisolated static func recommendations(_ all: [InstructorRecommendation],
                                            for ownerID: String,
                                            blocked: Set<String>) -> [InstructorRecommendation] {
        all
            .filter { $0.toID == ownerID && !blocked.contains($0.fromID) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Peer recommendations of the signed-in instructor's own profile — the endorsements shown on it.
    var myRecommendations: [InstructorRecommendation] {
        guard let me = currentUserID else { return [] }
        return recommendations(for: me)
    }

    /// Refresh the recommendations on the signed-in instructor's own profile.
    func syncMyRecommendations() async {
        guard let me = currentUserID else { return }
        await syncRecommendations(forInstructor: me)
    }

    /// The signed-in instructor's recommendation of `ownerID`, if they've written one — toggles the
    /// compose sheet between "Recommend" and "Edit / Remove".
    func myRecommendation(for ownerID: String) -> InstructorRecommendation? {
        guard let me = currentUserID else { return nil }
        return recommendations.first { $0.fromID == me && $0.toID == ownerID }
    }

    /// Write (or edit) a peer recommendation of another instructor. Idempotent — re-writing upserts the
    /// same `rec-<me>-<them>` record. Guarded: no self-recommendation, and only an instructor may author one.
    func writeRecommendation(to ownerID: String, text: String) {
        guard let me = currentUserID, me != ownerID, currentInstructor != nil else { return }
        let rec = myRecommendation(for: ownerID) ?? {
            let fresh = InstructorRecommendation(fromID: me, fromName: currentUserName, toID: ownerID)
            context.insert(fresh)
            return fresh
        }()
        rec.fromName = currentUserName
        rec.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        rec.createdAt = Date()
        rec.remoteID = rec.recordName
        save()
        guard !isPreview else { return }
        Task { await uploadRecommendation(rec) }
    }

    /// Remove my recommendation of an instructor — local + shared store (`_creator`-write lets me delete
    /// my own).
    func deleteRecommendation(to ownerID: String) {
        guard let rec = myRecommendation(for: ownerID) else { return }
        let rid = rec.remoteID
        context.delete(rec)
        save()
        guard !isPreview, let rid else { return }
        Task { await recommendationService.delete(recordName: rid) }
    }

    private func uploadRecommendation(_ rec: InstructorRecommendation) async {
        let saved = await recommendationService.publish(
            recordName: rec.recordName, fromID: rec.fromID, fromName: rec.fromName,
            toID: rec.toID, text: rec.text, createdAt: rec.createdAt)
        rec.remoteID = saved ?? rec.recordName
        save()
    }

    /// Pull the peer recommendations shown on `ownerID`'s profile + the signed-in instructor's own
    /// authored ones. Merge by recordName, updating text/name on ones already held. Offline / preview no-ops.
    func syncRecommendations(forInstructor ownerID: String) async {
        guard !isPreview, let me = currentUserID else { return }
        async let forProfile = recommendationService.fetchFor(toID: ownerID)
        async let mineRemote = recommendationService.fetchMine(fromID: me)
        let remotes = ((await forProfile) ?? []) + ((await mineRemote) ?? [])
        guard !remotes.isEmpty else { return }
        var changed = false
        for r in remotes {
            if let existing = recommendations.first(where: { $0.recordName == r.id || $0.remoteID == r.id }) {
                if existing.text != r.text || existing.fromName != r.fromName {
                    existing.text = r.text; existing.fromName = r.fromName; changed = true
                }
            } else {
                let rec = InstructorRecommendation(fromID: r.fromID, fromName: r.fromName,
                                                   toID: r.toID, text: r.text, createdAt: r.createdAt)
                rec.remoteID = r.id
                context.insert(rec)
                changed = true
            }
        }
        if changed { save() }
    }

    /// The signed-in organizer's own events. Upcoming first (soonest-first), then past
    /// (most-recent-first) — an organizer manages what's next before what's already happened.
    var myEvents: [CommunityEvent] {
        guard let me = currentUserID else { return [] }
        let now = Date()
        return events.filter { $0.organizerID == me }.sorted {
            let lUpcoming = $0.endsAt >= now
            let rUpcoming = $1.endsAt >= now
            if lUpcoming != rUpcoming { return lUpcoming }
            return lUpcoming ? $0.startsAt < $1.startsAt : $0.startsAt > $1.startsAt
        }
    }

    /// Whether the signed-in user organized this event — the only person allowed to edit, cancel or
    /// delete it, and the one who sees the attendee roster.
    func isMine(_ event: CommunityEvent) -> Bool {
        guard let currentUserID, let organizer = event.organizerID else { return false }
        return organizer == currentUserID
    }

    /// The organizer's cached public listing, if they have one — the source for their avatar and, in
    /// the detail sheet, a tappable route to their profile. A lapsed or student organizer has none.
    func organizerListing(for event: CommunityEvent) -> Instructor? {
        guard let organizerID = event.organizerID else { return nil }
        return instructors.first { $0.ownerID == organizerID }
    }

    /// The organizer's uploaded profile photo, if they have a listing — otherwise the card falls back
    /// to the gradient avatar. The event record itself carries no organizer image.
    func organizerPhoto(for event: CommunityEvent) -> Data? {
        organizerListing(for: event)?.photo
    }

    /// Create an event. Instructor-only in the UI; the store just needs a signed-in owner.
    func addEvent(title: String,
                  about: String,
                  location: String,
                  startsAt: Date,
                  durationMinutes: Int,
                  capacity: Int,
                  price: Int?,
                  image: Data?) {
        guard let me = currentUserID else { return }

        let event = CommunityEvent(
            legacyId: (events.map(\.legacyId).max() ?? 0) + 1,
            organizerID: me,
            organizerName: currentUserName,
            title: title,
            about: about,
            location: location,
            startsAt: startsAt,
            durationMinutes: durationMinutes,
            capacity: capacity,
            price: price,
            highlight: image,
            // Set true only once the asset actually stages, in `uploadEvent` — never from `image`.
            hasHighlight: false,
            // Marked pending up front: if the app dies before the upload finishes, the next sync
            // retries it rather than losing the event.
            pendingUpload: true
        )
        context.insert(event)

        guard !isPreview else {
            // No shared store to reach in previews/tests; leaving the flag set would strand the row
            // under a permanent "not sent yet".
            event.pendingUpload = false
            save()
            return
        }
        save()
        Task { await uploadEvent(event) }
    }

    /// Edit an event's organizer-written fields. The deterministic `localID` makes the re-publish an
    /// upsert onto the same record.
    func updateEvent(_ event: CommunityEvent,
                     title: String,
                     about: String,
                     location: String,
                     startsAt: Date,
                     durationMinutes: Int,
                     capacity: Int,
                     price: Int?,
                     image: Data?) {
        guard isMine(event) else { return }
        event.title = title
        event.about = about
        event.location = location
        event.startsAt = startsAt
        event.durationMinutes = durationMinutes
        event.capacity = capacity
        event.price = price
        event.highlight = image
        event.updatedAt = Date()
        event.pendingUpload = true

        guard !isPreview else {
            event.pendingUpload = false
            save()
            return
        }
        save()
        Task { await uploadEvent(event) }
    }

    /// Cancel an event: mark it, and let the next upsert carry `cancelled` to everyone. A typo'd date
    /// is an edit; this is the deliberate "call it off" path, and it stays visible to joiners.
    func cancelEvent(_ event: CommunityEvent) {
        guard isMine(event) else { return }
        event.cancelled = true
        event.updatedAt = Date()
        event.pendingUpload = true

        guard !isPreview else {
            event.pendingUpload = false
            save()
            return
        }
        save()
        Task { await uploadEvent(event) }
    }

    /// Delete the organizer's own event. Registrations other students left on it stay owned by their
    /// creators in the public DB (the orphan class documented in `BOOKING-SYSTEM.md`).
    func deleteEvent(_ event: CommunityEvent) {
        guard isMine(event) else { return }
        guard !isPreview else { return deleteEventLocally(event) }

        // A nil remoteID does NOT mean "never published": it is also nil for the whole publish
        // round-trip. Deleting locally in that window would destroy the row while `uploadEvent` is
        // still suspended, the record would land on the server anyway, and the next sync would
        // re-insert an event the organizer was told had been withdrawn. Mark it and let the flush
        // (or the in-flight upload) withdraw it once an id exists.
        event.pendingDelete = true
        save()
        guard let remoteID = event.remoteID else { return }
        Task {
            if await eventService.deleteEvent(id: remoteID) { deleteEventLocally(event) }
            save()
        }
    }

    private func deleteEventLocally(_ event: CommunityEvent) {
        context.delete(event)
        save()
    }

    /// Push a locally-created/edited/cancelled event to the shared store, flagging it for retry if it
    /// fails. Doubles as create, edit and cancel because `upsert` is deterministic on `localID`.
    private func uploadEvent(_ event: CommunityEvent) async {
        guard let organizerID = event.organizerID else { return }
        let remoteID = await eventService.upsert(
            localID: event.localID,
            organizerID: organizerID,
            organizerName: event.organizerName,
            title: event.title,
            about: event.about,
            location: event.location,
            startsAt: event.startsAt,
            durationMinutes: event.durationMinutes,
            capacity: event.capacity,
            price: event.price,
            cancelled: event.cancelled,
            createdAt: event.createdAt,
            highlight: event.highlight
        )
        event.remoteID = remoteID
        // Derive `hasHighlight` from the delivered result, not `highlight != nil`: a delivered event
        // that carried bytes staged its asset, and one that never reached the server carries nothing
        // anyone else can see yet.
        event.hasHighlight = remoteID != nil && event.highlight != nil
        event.pendingUpload = remoteID == nil
        save()

        // The organizer may have deleted the event while the publish was in flight. Withdraw it now
        // rather than leaving it world-readable until the next sync.
        if event.pendingDelete, let remoteID {
            if await eventService.deleteEvent(id: remoteID) { deleteEventLocally(event) }
            save()
        }
    }

    /// Join an event. The capacity check here is a client pre-check, explicitly *not* trusted — two
    /// students can both pass it and both write, which the post-write re-check resolves.
    func join(_ event: CommunityEvent) {
        guard let me = currentUserID, let remoteID = event.remoteID else { return }
        // A nil remoteID is the in-flight publish window; only the organizer sees such an event and
        // the rail shows "not sent yet", so there is nothing to join yet.
        guard case .open = event.status else { return }

        // Optimistic local move so the tap feels answered. `joined` now means "I've REQUESTED to
        // join"; the organizer still has to accept (see `requestState`). The attendee count is the
        // number ACCEPTED, so a pending request must NOT bump it — reconcile recomputes it.
        event.joined = true
        event.pendingJoin = true
        save()

        guard !isPreview else {
            event.pendingJoin = false
            save()
            return
        }
        Task {
            let delivered = await eventService.setRegistration(
                true, eventID: remoteID, studentID: me, studentName: currentUserName,
                eventTitle: event.title, organizerID: event.organizerID ?? ""
            )
            event.pendingJoin = !delivered
            if delivered {
                // Post-write re-check over this one id: the same reconciliation the sync uses, which
                // withdraws my own record and tells me if I lost the race for the last spot.
                await refreshAttendance(for: event)
            } else {
                // Not a lost race — the write itself didn't land. It stays queued (pendingJoin) and
                // the flush retries; tell the user plainly rather than showing a false success.
                lastJoinOutcome = .notSent(title: event.title)
                save()
            }
        }
    }

    /// Leave an event, withdrawing this student's own registration record.
    func leave(_ event: CommunityEvent) {
        guard let me = currentUserID, let remoteID = event.remoteID else { return }
        // Withdraw my request. `attendees` is the accepted count now, so don't decrement it here —
        // reconcile recomputes it after the registration is removed.
        event.joined = false
        event.pendingJoin = true
        save()

        guard !isPreview else {
            event.pendingJoin = false
            save()
            return
        }
        Task {
            // `setRegistration(false, …)` tolerates a record that is already gone.
            event.pendingJoin = !(await eventService.setRegistration(
                false, eventID: remoteID, studentID: me, studentName: currentUserName,
                eventTitle: event.title, organizerID: event.organizerID ?? ""
            ))
            save()
        }
    }

    // MARK: - Event sync

    /// Pull the shared events, cache them so the tab works offline, reconcile attendance from the
    /// registration records, then fetch any missing highlight photos.
    func syncEvents(asOrganizer: Bool) async {
        guard !isPreview, let me = currentUserID else { return }
        if eventsPhase != .loaded { eventsPhase = .loading }
        await flushPendingEventWrites()

        // The 6-hour grace keeps a class that started an hour ago from vanishing while people are in
        // it. Only this (whole-window) merge prunes — see `mergeEvents(_:prune:)`.
        guard let upcoming = await eventService.fetchUpcoming(since: Date(timeIntervalSinceNow: -6 * 3600)) else {
            if eventsPhase != .loaded { eventsPhase = .failed }
            return
        }
        eventsPhase = .loaded
        mergeEvents(upcoming)
        if asOrganizer {
            // An organizer also keeps their past events, which the upcoming window excludes. Merge
            // without pruning: pruning against this narrow (mine-only) set would wipe every other
            // instructor's events from the cache.
            mergeEvents(await eventService.fetchMine(organizerID: me), prune: false)
        }

        await refreshAttendance()
        await fetchMissingHighlights()
    }

    /// Refresh one event's attendance without touching the event list.
    ///
    /// The detail sheet cannot call `syncEvents`: that prunes cached events, including the very event
    /// the sheet is displaying, and reading a deleted SwiftData model traps at runtime (the same trap
    /// `syncComments` avoids for the comments sheet).
    func syncAttendance(for event: CommunityEvent) async {
        guard !isPreview, event.remoteID != nil else { return }
        await refreshAttendance(for: event)
    }

    /// Re-send anything that never reached the server: an event created offline, a join taken while
    /// the network was down, a deletion the server never confirmed.
    private func flushPendingEventWrites() async {
        for event in events where event.pendingUpload && event.remoteID == nil {
            await uploadEvent(event)
        }
        for event in events where event.pendingDelete {
            guard let remoteID = event.remoteID else { continue }
            if await eventService.deleteEvent(id: remoteID) { deleteEventLocally(event) }
        }
        save()
        for event in events where event.pendingJoin {
            guard let remoteID = event.remoteID, let me = currentUserID else { continue }
            // The desired state is `joined`, so re-send exactly that — a queued join or a queued
            // leave, whichever the user last chose.
            event.pendingJoin = !(await eventService.setRegistration(
                event.joined, eventID: remoteID, studentID: me, studentName: currentUserName,
                eventTitle: event.title, organizerID: event.organizerID ?? ""
            ))
        }
        save()
    }

    private func mergeEvents(_ remote: [RemoteEvent], prune: Bool = true) {
        guard !remote.isEmpty else { return }
        // An event can arrive both from the public fetch and from the private SwiftData mirror, keyed
        // differently there (a delivered remoteID vs the deterministic `event-<localID>`), so a row
        // is "known" under either name and is never inserted twice.
        let known = Set(events.compactMap(\.remoteID))
            .union(events.map { "event-\($0.localID.uuidString)" })
        var nextId = events.map(\.legacyId).max() ?? 0

        for entry in remote {
            if let existing = events.first(where: {
                $0.remoteID == entry.id || "event-\($0.localID.uuidString)" == entry.id
            }) {
                // A pending event is my own undelivered edit — the server copy is stale, so don't
                // clobber my fields with it. Reader state (joined/attendees/pendingJoin) is never
                // touched here; it comes from the registration query.
                if !existing.pendingUpload { apply(entry, to: existing) }
                if existing.remoteID == nil { existing.remoteID = entry.id }
            } else if !known.contains(entry.id) {
                nextId += 1
                let event = CommunityEvent(legacyId: nextId, remoteID: entry.id)
                apply(entry, to: event)
                context.insert(event)
            }
        }
        if prune { pruneEvents(against: remote) }
        save()
    }

    /// Copy a fetched event's organizer-written fields onto the cache. Deliberately does not touch
    /// `joined` / `attendees` / `pendingJoin` — those are this reader's own state, resolved by the
    /// registration query, not carried on the event record.
    private func apply(_ r: RemoteEvent, to event: CommunityEvent) {
        event.organizerID = r.organizerID
        event.organizerName = r.organizerName
        event.title = r.title
        event.about = r.about
        event.location = r.location
        event.startsAt = r.startsAt
        event.durationMinutes = r.durationMinutes
        event.capacity = r.capacity
        event.price = r.price
        event.cancelled = r.cancelled
        event.hasHighlight = r.hasHighlight
        event.createdAt = r.createdAt
        event.updatedAt = r.updatedAt
    }

    /// Drop cached events their organizers have since deleted.
    ///
    /// The fetch is capped and time-bounded, so only prune inside the window it actually covers —
    /// anything older than the oldest row returned simply wasn't looked at. Very recent events are
    /// spared (CloudKit's query index is eventually consistent), as is anything I've joined or that
    /// is still queued for a write of mine. Same reasoning and window as `prunePosts`.
    private func pruneEvents(against remote: [RemoteEvent]) {
        // A failed query returns []; pruning against it would wipe the whole cache.
        guard let oldest = remote.map(\.startsAt).min() else { return }
        let live = Set(remote.map(\.id))
        let settled = Date(timeIntervalSinceNow: -300)
        for event in events {
            guard let remoteID = event.remoteID, !live.contains(remoteID),
                  event.startsAt >= oldest, event.createdAt < settled,
                  !event.joined, !event.pendingUpload, !event.pendingJoin else { continue }
            deleteEventLocally(event)
        }
    }

    /// Reconcile attendance for every cached event from the registration records.
    private func refreshAttendance() async {
        await reconcileAttendance(eventIDs: events.compactMap(\.remoteID), subjects: events)
    }

    /// The narrow, non-pruning per-event refresh the detail sheet and the post-write join re-check
    /// call.
    private func refreshAttendance(for event: CommunityEvent) async {
        guard let remoteID = event.remoteID else { return }
        await reconcileAttendance(eventIDs: [remoteID], subjects: [event])
    }

    /// The shared reconciliation. For each subject: count its registrations, compute the deterministic
    /// admitted set, and settle this reader's own state. Because `admitted` is total over the
    /// server-assigned join time, every device computes the identical set, so exactly one racer
    /// withdraws — the outside student is told and their record removed.
    private func reconcileAttendance(eventIDs: [String], subjects: [CommunityEvent]) async {
        guard !eventIDs.isEmpty, let me = currentUserID else { return }
        // Keep the backend profile current so the server-side roster scoping (mutual community opt-in)
        // is accurate for this read, and register any events I organize so I can read/manage their rosters.
        await FloweBackendClient.shared.setCommunityVisible(isCommunityVisible, name: currentUserName)
        for subject in subjects where subject.organizerID == me {
            // Register each owned event with the backend ONCE per session (only on success), not on
            // every reconcile — avoids redundant writes and brushing the per-user write rate limit.
            if let rid = subject.remoteID, !registeredEventOwners.contains(rid),
               await eventService.ensureEventOwner(eventID: rid) {
                registeredEventOwners.insert(rid)
            }
        }
        // nil means the query failed — NOT "nobody joined". Conflating them would zero every count
        // offline and could withdraw a genuine registration on no evidence.
        guard let rows = await eventService.fetchRegistrations(eventIDs: eventIDs) else { return }
        // Decisions ride on top — best-effort. A nil (query failed) leaves the decision cache intact
        // rather than blanking accept/decline answers already shown.
        let decisionRows = await eventService.fetchEventDecisions(eventIDs: eventIDs)

        let regsByEvent = Dictionary(grouping: rows, by: \.eventID)
        let decByEvent = decisionRows.map { Dictionary(grouping: $0, by: \.eventID) }

        for event in subjects {
            guard let remoteID = event.remoteID else { continue }
            let mineRows = regsByEvent[remoteID] ?? []
            eventRegistrationRows[remoteID] = mineRows                 // keep rows for the organizer's queue
            if let decByEvent {
                var fresh = Dictionary(
                    (decByEvent[remoteID] ?? []).map { ($0.studentID, $0.accepted) },
                    uniquingKeysWith: { _, newest in newest }
                )
                // Preserve an OPTIMISTIC decision the server query hasn't indexed yet (CloudKit write→query
                // lag). Dropping it makes a just-accepted request reappear in the organizer's queue, so they
                // tap Accept a second time — the reported "accept twice" bug. Server truth still wins for
                // any student it DID return.
                // Only preserve an optimistic decision for a student who STILL has a live registration in
                // this fetch. Otherwise a student who LEFT after being accepted resurrects here and
                // permanently consumes a capacity slot (their backend row is deleted on leave).
                let liveIDs = Set(mineRows.map(\.studentID))
                for (studentID, accepted) in eventDecisions[remoteID] ?? [:]
                    where fresh[studentID] == nil && liveIDs.contains(studentID) {
                    fresh[studentID] = accepted
                }
                eventDecisions[remoteID] = fresh
            }
            let decided = eventDecisions[remoteID] ?? [:]

            // The count is how many the organizer has ACCEPTED — that's what "going" and `spotsLeft`
            // mean now that joining is request→accept. A pending request consumes no spot until accepted.
            let acceptedCount = mineRows.reduce(0) { $0 + (decided[$1.studentID] == true ? 1 : 0) }
            // Prefer the server-authoritative accepted count (correct even when co-attendee NAMES are
            // withheld by the scoped roster); fall back to the locally-derived count.
            event.attendees = eventService.acceptedCount(forEventID: remoteID) ?? acceptedCount

            if !event.pendingJoin {
                // `joined` = "I have a live registration" (pending OR accepted OR declined-but-not-yet-
                // withdrawn); `requestState` surfaces which. Keep the read-after-write guard: if my
                // just-written row isn't indexed yet, don't drop my optimistic request.
                let myRowPresent = mineRows.contains { $0.studentID == me }
                if myRowPresent { event.joined = true }
                else if !event.joined { event.joined = false }
            }
        }
        save()
    }

    /// Download the highlight photos of events that have one but haven't got it yet.
    ///
    /// Separate from `mergeEvents` because the list query deliberately doesn't carry assets (see
    /// `EventService.eventMetadataKeys`). Capped per pass; the rest arrive on later syncs, and a
    /// photo already cached is never fetched twice.
    private func fetchMissingHighlights() async {
        let wanted = events
            .filter { $0.hasHighlight && $0.highlight == nil && !$0.pendingDelete }
            .compactMap(\.remoteID)
        guard !wanted.isEmpty else { return }

        let images = await eventService.fetchHighlights(eventIDs: wanted)
        guard !images.isEmpty else { return }
        for event in events {
            guard let remoteID = event.remoteID, let data = images[remoteID] else { continue }
            event.highlight = data
        }
        save()
    }

    // MARK: - Lesson types

    /// The signed-in instructor's own lesson-type rows, in display order — what the editor lists and
    /// mutates. Read directly (not through the resolver) because the compose sheet edits a live
    /// `LessonType` and swipe-to-delete removes one.
    func ownedLessonTypes(for instructor: Instructor) -> [LessonType] {
        guard let owner = instructor.ownerID else { return [] }
        return lessonTypes.filter { $0.ownerID == owner }.sorted { $0.order < $1.order }
    }

    /// The single render currency both student surfaces consume. Owned rich rows when the instructor
    /// has authored any; otherwise the denormalised `sessionTypes` name cache mapped to name-only
    /// values — so an un-upgraded (or remote) instructor still shows plain-name offers, and a listing
    /// with genuinely no types resolves to an honest empty array rather than a backfilled default.
    func lessonTypes(for instructor: Instructor) -> [ResolvedLessonType] {
        let owned = ownedLessonTypes(for: instructor)
        if !owned.isEmpty {
            return owned.map {
                ResolvedLessonType(
                    legacyId: $0.legacyId, name: $0.name, details: $0.details,
                    durationMinutes: $0.durationMinutes, capacity: $0.capacity, price: $0.price,
                    cancellationPolicy: $0.cancellationPolicy,
                    hasPhoto: $0.hasHighlight, photo: $0.highlight
                )
            }
        }
        return instructor.sessionTypes.map { ResolvedLessonType(name: $0) }
    }

    /// Create a lesson type for the signed-in instructor. Marked pending up front so a kill mid-upload
    /// retries on the next sync rather than losing the row.
    func addLessonType(name: String,
                       details: String,
                       durationMinutes: Int,
                       capacity: Int,
                       price: Int?,
                       policy: CancellationPolicy = CancellationPolicy(),
                       image: Data?) {
        guard let owner = currentUserID, let me = currentInstructor else { return }
        let owned = ownedLessonTypes(for: me)
        let type = LessonType(
            legacyId: (lessonTypes.map(\.legacyId).max() ?? 0) + 1,
            ownerID: owner,
            name: name,
            details: details,
            durationMinutes: durationMinutes,
            capacity: capacity,
            price: price,
            order: (owned.map(\.order).max() ?? -1) + 1,
            cancelWindowHours: policy.windowHours,
            cancelFee: policy.fee,
            cancelFeeIsPercent: policy.feeIsPercent,
            highlight: image,
            // Set true only once the asset actually stages, in `uploadLessonType` — never from `image`.
            hasHighlight: false,
            pendingUpload: true
        )
        context.insert(type)
        // Keep the denormalised name cache and the public listing current even if the instructor never
        // taps profile Save — the resolver, InstructorCard and the catalog String List all read it.
        rederiveSessionTypeCache(for: me)

        guard !isPreview else {
            type.pendingUpload = false
            save()
            publishMyListing()
            return
        }
        save()
        publishMyListing()
        Task { await uploadLessonType(type) }
    }

    /// Edit a lesson type's fields. The deterministic `localID` makes the re-publish an upsert onto the
    /// same record.
    func updateLessonType(_ type: LessonType,
                          name: String,
                          details: String,
                          durationMinutes: Int,
                          capacity: Int,
                          price: Int?,
                          policy: CancellationPolicy = CancellationPolicy(),
                          image: Data?) {
        guard let me = currentInstructor, type.ownerID == me.ownerID else { return }
        type.name = name
        type.details = details
        type.durationMinutes = durationMinutes
        type.capacity = capacity
        type.price = price
        type.cancelWindowHours = policy.windowHours
        type.cancelFee = policy.fee
        type.cancelFeeIsPercent = policy.feeIsPercent
        type.highlight = image
        type.updatedAt = Date()
        type.pendingUpload = true
        rederiveSessionTypeCache(for: me)

        guard !isPreview else {
            type.pendingUpload = false
            save()
            publishMyListing()
            return
        }
        save()
        publishMyListing()
        Task { await uploadLessonType(type) }
    }

    /// Delete the instructor's own lesson type.
    func deleteLessonType(_ type: LessonType) {
        guard let me = currentInstructor, type.ownerID == me.ownerID else { return }
        guard !isPreview else {
            deleteLessonTypeLocally(type)
            rederiveSessionTypeCache(for: me)
            save()
            publishMyListing()
            return
        }

        // A nil remoteID does NOT mean "never published" — it is also nil for the whole publish
        // round-trip. Deleting locally in that window would drop the row while `uploadLessonType` is
        // still suspended, the record would land anyway, and the next sync would re-insert a type the
        // instructor was told had been removed. Mark it and let the flush withdraw it once an id exists.
        type.pendingDelete = true
        rederiveSessionTypeCache(for: me)
        save()
        publishMyListing()
        guard let remoteID = type.remoteID else { return }
        Task {
            if await lessonTypeService.delete(id: remoteID) { deleteLessonTypeLocally(type) }
            save()
        }
    }

    /// Reorder the instructor's lesson types after a drag in the editor, rewriting each row's `order`
    /// and republishing so students see the same sequence.
    func reorderLessonTypes(from source: IndexSet, to destination: Int) {
        guard let me = currentInstructor else { return }
        var owned = ownedLessonTypes(for: me)
        owned.move(fromOffsets: source, toOffset: destination)
        for (index, type) in owned.enumerated() where type.order != index {
            type.order = index
            type.updatedAt = Date()
            type.pendingUpload = true
        }
        rederiveSessionTypeCache(for: me)

        guard !isPreview else {
            for type in owned { type.pendingUpload = false }
            save()
            publishMyListing()
            return
        }
        save()
        publishMyListing()
        Task { for type in owned where type.pendingUpload { await uploadLessonType(type) } }
    }

    /// Recompute `Instructor.sessionTypes` from the owned rows, in display order. The one place the
    /// name cache is derived — never by a view — so the catalog String List, the resolver fallback and
    /// `InstructorCard` all stay consistent with the rich rows. Rows queued for deletion are excluded.
    private func rederiveSessionTypeCache(for instructor: Instructor) {
        guard let owner = instructor.ownerID else { return }
        // Read owned rows straight from the CONTEXT, not the `lessonTypes` cache: callers derive this
        // immediately after `context.insert(newType)` but BEFORE `save()→refresh()` repopulates the
        // cache, so the cache still lags by one — which left the just-added type (or the very first one)
        // out of the name cache, and thus out of the profile's OFFERS + the published catalog listing.
        // A context fetch reflects pending inserts, so it always sees the newest row.
        let owned = ((try? context.fetch(FetchDescriptor<LessonType>())) ?? [])
            .filter { $0.ownerID == owner && !$0.pendingDelete }
            .sorted { $0.order < $1.order }
        instructor.sessionTypes = owned.map(\.name)
    }

    /// One-time upgrade for the signed-in owner: materialise a minimal `LessonType` per existing
    /// `sessionTypes` name, preserving order, so a legacy instructor's flat chips become editable rich
    /// rows the first time they open the editor. Only ever runs for the signed-in owner (whose
    /// credential can write the records) and only when they have names but no rows yet.
    func migrateLessonTypesIfNeeded() {
        guard let me = currentInstructor, let owner = me.ownerID else { return }
        guard ownedLessonTypes(for: me).isEmpty, !me.sessionTypes.isEmpty else { return }

        var nextId = lessonTypes.map(\.legacyId).max() ?? 0
        var created: [LessonType] = []
        for (index, name) in me.sessionTypes.enumerated() {
            nextId += 1
            let type = LessonType(
                legacyId: nextId, ownerID: owner, name: name,
                order: index, pendingUpload: !isPreview
            )
            context.insert(type)
            created.append(type)
        }
        save()
        // These materialized rows are unpriced (price nil → derived floor 0), so a legacy record's
        // stale human-entered `Instructor.price` (e.g. 120) would keep advertising a "from 120" with no
        // bookable priced type. Re-derive + republish through the single seam, exactly like every other
        // lesson-type mutation, so the price drops to 0 immediately and the "add pricing" nudge fires.
        publishMyListing()
        guard !isPreview else {
            for type in created { type.pendingUpload = false }
            save()
            return
        }
        Task { for type in created { await uploadLessonType(type) } }
    }

    private func deleteLessonTypeLocally(_ type: LessonType) {
        context.delete(type)
        save()
    }

    /// Push a locally created/edited/reordered lesson type to the shared store, flagging it for retry
    /// if it fails. Doubles as create, edit and reorder because `upsert` is deterministic on `localID`.
    private func uploadLessonType(_ type: LessonType) async {
        guard let owner = type.ownerID else { return }
        let remoteID = await lessonTypeService.upsert(
            localID: type.localID,
            ownerID: owner,
            name: type.name,
            details: type.details,
            durationMinutes: type.durationMinutes,
            capacity: type.capacity,
            price: type.price,
            order: type.order,
            policy: type.cancellationPolicy,
            createdAt: type.createdAt,
            highlight: type.highlight
        )
        type.remoteID = remoteID
        // Derive `hasHighlight` from the delivered result, not `highlight != nil`: a delivered type
        // that carried bytes staged its asset; one that never reached the server carries nothing
        // anyone else can see yet.
        type.hasHighlight = remoteID != nil && type.highlight != nil
        type.pendingUpload = remoteID == nil
        save()

        // The instructor may have deleted the type while the publish was in flight. Withdraw it now
        // rather than leaving it world-readable until the next sync.
        if type.pendingDelete, let remoteID {
            if await lessonTypeService.delete(id: remoteID) { deleteLessonTypeLocally(type) }
            save()
        }
    }

    // MARK: - Lesson-type sync

    /// Pull one instructor's lesson types from the shared store, cache them so both student surfaces
    /// work offline, then fetch any missing highlight photos. Called for the instructor a student is
    /// viewing and for the signed-in owner's own device.
    func syncLessonTypes(for instructor: Instructor) async {
        guard !isPreview, let owner = instructor.ownerID else { return }
        // Flush the owner's own queued writes first so a fetch never clobbers an undelivered edit.
        if owner == currentUserID { await flushPendingLessonTypeWrites() }
        mergeLessonTypes(await lessonTypeService.fetch(ownerID: owner))
        await fetchMissingLessonPhotos()
    }

    /// Re-send anything that never reached the server: a type created offline, an edit taken while the
    /// network was down, a deletion the server never confirmed.
    private func flushPendingLessonTypeWrites() async {
        for type in lessonTypes where type.pendingUpload && type.remoteID == nil && !type.pendingDelete {
            await uploadLessonType(type)
        }
        for type in lessonTypes where type.pendingDelete {
            guard let remoteID = type.remoteID else { continue }
            if await lessonTypeService.delete(id: remoteID) { deleteLessonTypeLocally(type) }
        }
        save()
    }

    private func mergeLessonTypes(_ remote: [RemoteLessonType]) {
        guard !remote.isEmpty else { return }
        // A type can arrive both from the public fetch and from the private SwiftData mirror, keyed
        // differently there (a delivered remoteID vs the deterministic `lessontype-<localID>`), so a
        // row is "known" under either name and is never inserted twice.
        let known = Set(lessonTypes.compactMap(\.remoteID))
            .union(lessonTypes.map { "lessontype-\($0.localID.uuidString)" })
        var nextId = lessonTypes.map(\.legacyId).max() ?? 0

        for entry in remote {
            if let existing = lessonTypes.first(where: {
                $0.remoteID == entry.id || "lessontype-\($0.localID.uuidString)" == entry.id
            }) {
                // A pending row is my own undelivered edit — the server copy is stale, so don't clobber
                // my fields with it.
                if !existing.pendingUpload { apply(entry, to: existing) }
                if existing.remoteID == nil { existing.remoteID = entry.id }
            } else if !known.contains(entry.id) {
                nextId += 1
                let type = LessonType(legacyId: nextId, remoteID: entry.id)
                apply(entry, to: type)
                context.insert(type)
            }
        }
        save()
    }

    /// Copy a fetched lesson type's fields onto the cache. Unlike an event there is no reader-only
    /// state to protect — a lesson type is 100% descriptive, so every field is copied.
    private func apply(_ r: RemoteLessonType, to type: LessonType) {
        type.ownerID = r.ownerID
        type.name = r.name
        type.details = r.details
        type.durationMinutes = r.durationMinutes
        type.capacity = r.capacity
        type.price = r.price
        type.order = r.order
        type.cancelWindowHours = r.cancelWindowHours
        type.cancelFee = r.cancelFee
        type.cancelFeeIsPercent = r.cancelFeeIsPercent
        type.hasHighlight = r.hasHighlight
        type.createdAt = r.createdAt
        type.updatedAt = r.updatedAt
    }

    /// Download the highlight photos of lesson types that have one but haven't got it yet. Separate
    /// from `mergeLessonTypes` because the list query deliberately doesn't carry assets (see
    /// `LessonTypeService.lessonTypeMetadataKeys`). Capped per pass; a cached photo is never re-fetched.
    private func fetchMissingLessonPhotos() async {
        let wanted = lessonTypes
            .filter { $0.hasHighlight && $0.highlight == nil && !$0.pendingDelete }
            .compactMap(\.remoteID)
        guard !wanted.isEmpty else { return }

        let images = await lessonTypeService.fetchPhotos(ids: wanted)
        guard !images.isEmpty else { return }
        for type in lessonTypes {
            guard let remoteID = type.remoteID, let data = images[remoteID] else { continue }
            type.highlight = data
        }
        save()
    }

    // MARK: - Flowe Education (programs + video exercises)
    //
    // Same lifecycle as lesson types (pending-up-front, deterministic upsert, last-writer-wins merge,
    // asset-fetch split), for TWO public record types. The only twist: an exercise's video is NOT held on
    // the @Model (a non-asset field on the private mirror is capped at 1MB), so the picked clip rides the
    // one-shot upload transiently and students fetch it on demand. Education does NOT feed the catalog
    // listing, so there is no `rederiveSessionTypeCache`/`publishMyListing` here.

    /// The signed-in instructor's own programs, in display order.
    func ownedPrograms(for instructor: Instructor) -> [Program] {
        guard let owner = instructor.ownerID else { return [] }
        return programs.filter { $0.ownerID == owner && !$0.pendingDelete }.sorted { $0.order < $1.order }
    }

    /// The signed-in instructor's own exercises under one program, in display order.
    func ownedExercises(for instructor: Instructor, programID: String) -> [VideoExercise] {
        guard let owner = instructor.ownerID else { return [] }
        return videoExercises.filter { $0.ownerID == owner && $0.programID == programID && !$0.pendingDelete }
            .sorted { $0.order < $1.order }
    }

    // MARK: Programs

    func addProgram(title: String, summary: String, cover: Data?) {
        guard let owner = currentUserID, let me = currentInstructor else { return }
        let program = Program(
            ownerID: owner, title: title, summary: summary,
            order: (ownedPrograms(for: me).map(\.order).max() ?? -1) + 1,
            cover: cover, hasCover: false, pendingUpload: true
        )
        context.insert(program)
        guard !isPreview else { program.pendingUpload = false; save(); return }
        save()
        Task { await uploadProgram(program) }
    }

    func updateProgram(_ program: Program, title: String, summary: String, cover: Data?) {
        guard program.ownerID == currentUserID else { return }
        program.title = title
        program.summary = summary
        program.cover = cover
        program.updatedAt = Date()
        program.pendingUpload = true
        guard !isPreview else { program.pendingUpload = false; save(); return }
        save()
        Task { await uploadProgram(program) }
    }

    /// Delete a program AND its exercises, locally and from the shared store.
    func deleteProgram(_ program: Program) {
        guard program.ownerID == currentUserID, let me = currentInstructor else { return }
        let children = ownedExercises(for: me, programID: program.recordKey)
        guard !isPreview else {
            for child in children { context.delete(child) }
            context.delete(program)
            save()
            return
        }
        program.pendingDelete = true
        for child in children { child.pendingDelete = true }
        save()
        Task {
            for child in children where child.remoteID != nil {
                if await exerciseService.delete(id: child.remoteID!) { context.delete(child) }
            }
            if let remoteID = program.remoteID, await programService.delete(id: remoteID) { context.delete(program) }
            save()
        }
    }

    private func uploadProgram(_ program: Program) async {
        guard let owner = program.ownerID else { return }
        let remoteID = await programService.upsert(
            localID: program.localID, ownerID: owner, title: program.title,
            summary: program.summary, order: program.order, createdAt: program.createdAt, cover: program.cover
        )
        program.remoteID = remoteID
        program.hasCover = remoteID != nil && program.cover != nil
        program.pendingUpload = remoteID == nil
        save()
        if program.pendingDelete, let remoteID {
            if await programService.delete(id: remoteID) { context.delete(program) }
            save()
        }
    }

    // MARK: Exercises

    func addExercise(programID: String, title: String, coachingNotes: String, prescription: String,
                     focus: String, level: String, durationSeconds: Int, thumbnail: Data?, video: Data?) {
        guard let owner = currentUserID, let me = currentInstructor else { return }
        let exercise = VideoExercise(
            ownerID: owner, programID: programID, title: title, coachingNotes: coachingNotes,
            prescription: prescription, focus: focus, level: level,
            order: (ownedExercises(for: me, programID: programID).map(\.order).max() ?? -1) + 1,
            durationSeconds: durationSeconds, thumbnail: thumbnail, hasThumbnail: false, hasVideo: false, pendingUpload: true
        )
        context.insert(exercise)
        guard !isPreview else { exercise.pendingUpload = false; save(); return }
        save()
        // The picked clip isn't retained on the @Model — carry it into the one-shot upload only.
        Task { await uploadExercise(exercise, video: video) }
    }

    func updateExercise(_ exercise: VideoExercise, title: String, coachingNotes: String, prescription: String,
                        focus: String, level: String, durationSeconds: Int, thumbnail: Data?, video: Data?) {
        guard exercise.ownerID == currentUserID else { return }
        exercise.title = title
        exercise.coachingNotes = coachingNotes
        exercise.prescription = prescription
        exercise.focus = focus
        exercise.level = level
        exercise.durationSeconds = durationSeconds
        exercise.thumbnail = thumbnail
        exercise.updatedAt = Date()
        exercise.pendingUpload = true
        guard !isPreview else { exercise.pendingUpload = false; save(); return }
        save()
        Task { await uploadExercise(exercise, video: video) }
    }

    func deleteExercise(_ exercise: VideoExercise) {
        guard exercise.ownerID == currentUserID else { return }
        guard !isPreview else { context.delete(exercise); save(); return }
        exercise.pendingDelete = true
        save()
        guard let remoteID = exercise.remoteID else { return }
        Task {
            if await exerciseService.delete(id: remoteID) { context.delete(exercise) }
            save()
        }
    }

    /// `video` is a freshly picked clip, or nil on a metadata-only edit / retry: it isn't stored on the
    /// @Model (1MB private-DB cap), so it rides this one-shot upload only. A retry with no fresh clip keeps
    /// the existing public asset (the service is preserve-if-nil for video).
    private func uploadExercise(_ exercise: VideoExercise, video: Data? = nil) async {
        guard let owner = exercise.ownerID else { return }
        let remoteID = await exerciseService.upsert(
            localID: exercise.localID, ownerID: owner, programID: exercise.programID,
            title: exercise.title, coachingNotes: exercise.coachingNotes, prescription: exercise.prescription,
            focus: exercise.focus, level: exercise.level, order: exercise.order,
            durationSeconds: exercise.durationSeconds, createdAt: exercise.createdAt,
            thumbnail: exercise.thumbnail, video: video
        )
        exercise.remoteID = remoteID
        exercise.hasThumbnail = remoteID != nil && exercise.thumbnail != nil
        if remoteID != nil, video != nil { exercise.hasVideo = true }
        exercise.pendingUpload = remoteID == nil
        save()
        if exercise.pendingDelete, let remoteID {
            if await exerciseService.delete(id: remoteID) { context.delete(exercise) }
            save()
        }
    }

    /// Fetch one exercise's clip for playback — a temp file URL for `AVPlayer` (see `ExerciseService`).
    func exerciseVideoURL(_ exercise: VideoExercise) async -> URL? {
        guard let remoteID = exercise.remoteID else { return nil }
        return await exerciseService.fetchVideoURL(id: remoteID)
    }

    // MARK: Education sync

    /// Pull one instructor's programs + exercises from the shared store (student view or the owner's own
    /// device), flushing the owner's queued writes first, then any missing cover/thumbnail assets.
    func syncEducation(for instructor: Instructor) async {
        guard !isPreview, let owner = instructor.ownerID else { return }
        if owner == currentUserID { await flushPendingEducationWrites() }
        mergePrograms(await programService.fetch(ownerID: owner))
        mergeExercises(await exerciseService.fetch(ownerID: owner))
        await fetchMissingEducationAssets()
    }

    private func flushPendingEducationWrites() async {
        for p in programs where p.pendingUpload && p.remoteID == nil && !p.pendingDelete { await uploadProgram(p) }
        for e in videoExercises where e.pendingUpload && e.remoteID == nil && !e.pendingDelete { await uploadExercise(e) }
        for p in programs where p.pendingDelete {
            if let remoteID = p.remoteID, await programService.delete(id: remoteID) { context.delete(p) }
        }
        for e in videoExercises where e.pendingDelete {
            if let remoteID = e.remoteID, await exerciseService.delete(id: remoteID) { context.delete(e) }
        }
        save()
    }

    private func mergePrograms(_ remote: [RemoteProgram]) {
        guard !remote.isEmpty else { return }
        let known = Set(programs.compactMap(\.remoteID)).union(programs.map { "program-\($0.localID.uuidString)" })
        for entry in remote {
            if let existing = programs.first(where: { $0.remoteID == entry.id || "program-\($0.localID.uuidString)" == entry.id }) {
                if !existing.pendingUpload { applyProgram(entry, to: existing) }
                if existing.remoteID == nil { existing.remoteID = entry.id }
            } else if !known.contains(entry.id) {
                let p = Program(remoteID: entry.id)
                applyProgram(entry, to: p)
                context.insert(p)
            }
        }
        save()
    }

    private func applyProgram(_ r: RemoteProgram, to p: Program) {
        p.ownerID = r.ownerID
        p.title = r.title
        p.summary = r.summary
        p.order = r.order
        p.hasCover = r.hasCover
        p.createdAt = r.createdAt
        p.updatedAt = r.updatedAt
    }

    private func mergeExercises(_ remote: [RemoteVideoExercise]) {
        guard !remote.isEmpty else { return }
        let known = Set(videoExercises.compactMap(\.remoteID)).union(videoExercises.map { "exercise-\($0.localID.uuidString)" })
        for entry in remote {
            if let existing = videoExercises.first(where: { $0.remoteID == entry.id || "exercise-\($0.localID.uuidString)" == entry.id }) {
                if !existing.pendingUpload { applyExercise(entry, to: existing) }
                if existing.remoteID == nil { existing.remoteID = entry.id }
            } else if !known.contains(entry.id) {
                let e = VideoExercise(remoteID: entry.id)
                applyExercise(entry, to: e)
                context.insert(e)
            }
        }
        save()
    }

    private func applyExercise(_ r: RemoteVideoExercise, to e: VideoExercise) {
        e.ownerID = r.ownerID
        e.programID = r.programID
        e.title = r.title
        e.coachingNotes = r.coachingNotes
        e.prescription = r.prescription
        e.focus = r.focus
        e.level = r.level
        e.order = r.order
        e.durationSeconds = r.durationSeconds
        e.hasThumbnail = r.hasThumbnail
        e.hasVideo = r.hasVideo
        e.createdAt = r.createdAt
        e.updatedAt = r.updatedAt
    }

    /// Download program covers + exercise thumbnails that exist but aren't cached yet (the list queries
    /// deliberately omit assets). The video is never bulk-fetched — it loads on demand at playback.
    private func fetchMissingEducationAssets() async {
        let wantCovers = programs.filter { $0.hasCover && $0.cover == nil && !$0.pendingDelete }.compactMap(\.remoteID)
        let covers = wantCovers.isEmpty ? [:] : await programService.fetchCovers(ids: wantCovers)
        for p in programs { if let remoteID = p.remoteID, let data = covers[remoteID] { p.cover = data } }

        let wantThumbs = videoExercises.filter { $0.hasThumbnail && $0.thumbnail == nil && !$0.pendingDelete }.compactMap(\.remoteID)
        let thumbs = wantThumbs.isEmpty ? [:] : await exerciseService.fetchThumbnails(ids: wantThumbs)
        for e in videoExercises { if let remoteID = e.remoteID, let data = thumbs[remoteID] { e.thumbnail = data } }

        if !covers.isEmpty || !thumbs.isEmpty { save() }
    }

    // MARK: - Instructor identity & editing

    /// Owner id of the signed-in user (set from AppSession); scopes "my" instructor listing.
    var currentUserID: String?

    /// Display name of the signed-in user, denormalised onto bookings they create so the
    /// instructor can show who booked without a second lookup.
    var currentUserName: String = ""

    /// Persist edits made directly to a managed `Instructor` (bio, price, specialties, availability),
    /// and publish the owner's listing to the public catalog.
    func commit() {
        save()
        publishMyListing()
    }

    private func publishMyListing() {
        guard let me = currentInstructor else { return }
        // SINGLE re-derivation seam. `Instructor.price` is no longer human-entered — it is the cheapest
        // priced lesson type, recomputed here so CatalogService, `isEligible`, MatchEngine and every
        // remote-feed reader keep working with ZERO CloudKit schema change. Every mutation path funnels
        // through here: `commit()` (Edit Profile / Availability save) and all lesson-type CRUD ops.
        me.price = Instructor.startingPrice(from: ownedLessonTypes(for: me))
        // Marked before the attempt so a crash or a kill mid-publish still retries.
        me.pendingPublish = true
        save()
        guard !isPreview else { return }
        Task {
            if let ts = await catalog.publish(me) {
                me.lastSyncedAt = ts
                me.pendingPublish = false
                save()
            }
        }
    }

    /// Re-publish a listing whose last save never landed. Called from the instructor's own syncs,
    /// because `syncCatalog` is student-side only and would never reach this.
    func flushPendingListing() async {
        guard !isPreview, let me = currentInstructor, me.pendingPublish else { return }
        if let ts = await catalog.publish(me) {
            me.lastSyncedAt = ts
            me.pendingPublish = false
            save()
        }
    }

    // MARK: - Public catalog sync (cross-device instructor discovery)

    /// Fetch visible listings from the public catalog and cache them into the local store the feed reads.
    func syncCatalog() async {
        guard !isPreview else { return }
        if catalogPhase != .loaded { catalogPhase = .loading }
        // nil means the fetch FAILED (offline / visibility index not deployed) — leave the cached feed
        // exactly as it is rather than hiding every instructor on the strength of a failed query. An
        // empty array is a real "no visible listings" answer and is allowed to prune below.
        guard let listings = await catalog.fetchVisibleListings() else {
            if catalogPhase != .loaded { catalogPhase = .failed }
            return
        }
        catalogPhase = .loaded
        var nextId = instructors.map(\.legacyId).max() ?? 0
        var nextOrder = instructors.map(\.order).max() ?? 0
        let owners = Set(listings.map(\.ownerID))

        for listing in listings {
            // NEVER apply the signed-in user's OWN listing from the catalog. Their listing is
            // locally authoritative — they edit it here (availability, bio, rate…) and publish it
            // OUTWARD via `publishMyListing`. Pulling the public copy back in overwrites unsynced or
            // just-made local edits with a staler catalog snapshot. This is what wiped an
            // instructor's availability after they signed in as a student on the same device (same
            // Apple id → same ownerID → their own listing came back in the visible set and clobbered
            // the local hours). The hide-loop below already excludes `currentUserID`; this matches it.
            guard listing.ownerID != currentUserID else { continue }
            if let existing = instructors.first(where: { $0.ownerID == listing.ownerID }) {
                apply(listing, to: existing)
            } else {
                nextId += 1; nextOrder += 1
                let ins = Instructor(ownerID: listing.ownerID)
                ins.legacyId = nextId
                ins.order = nextOrder
                apply(listing, to: ins)
                context.insert(ins)
            }
        }
        // Hide cached listings (not mine) that are no longer visible.
        for ins in instructors where ins.ownerID != nil && ins.ownerID != currentUserID {
            #if DEBUG
            // Keep local dev fixtures visible in Discover even though the public catalog fetch never
            // returns them (they were never published). Compiled out of release. See seedDevDataIfRequested.
            if ins.ownerID!.hasPrefix(Self.devSeedPrefix) { continue }
            #endif
            if !owners.contains(ins.ownerID!) { ins.visibilityRaw = 0 }
        }
        save()
    }

    /// Pre-warm a STUDENT's cache of the instructors they message or booked, so those instructors'
    /// name + photo are present in Messages and Bookings without first opening Discover. Targeted
    /// fetch by ownerID (works even for instructors who have since gone hidden); prunes nothing.
    /// The counterpart of `syncStudentProfiles`.
    func syncBookedInstructors() async {
        guard !isPreview else { return }
        let wanted = Set(myBookings.compactMap(\.instructorOwnerID))
            .union(conversations.map { $0.counterpart.id })
            .subtracting([currentUserID].compactMap { $0 })
            .subtracting(blockedIDs)
        guard !wanted.isEmpty else { return }
        let listings = await catalog.fetch(ownerIDs: Array(wanted))
        var nextId = instructors.map(\.legacyId).max() ?? 0
        var nextOrder = instructors.map(\.order).max() ?? 0
        for listing in listings {
            guard listing.ownerID != currentUserID else { continue }
            if let existing = instructors.first(where: { $0.ownerID == listing.ownerID }) {
                apply(listing, to: existing)
            } else {
                nextId += 1; nextOrder += 1
                let ins = Instructor(ownerID: listing.ownerID)
                ins.legacyId = nextId
                ins.order = nextOrder
                apply(listing, to: ins)
                context.insert(ins)
            }
        }
        save()
    }

    /// Resolve one instructor by ownerID for a share/deep link. Direct catalog fetch by recordName
    /// (works even for a hidden listing); returns the persisted `Instructor` the profile sheet needs,
    /// or `nil` for our own id, a blocked id, preview/offline with no cache, or an empty fetch
    /// (bad link OR offline — indistinguishable, see `catalog.fetch`).
    @discardableResult
    func loadInstructor(ownerID: String) async -> Instructor? {
        guard !ownerID.isEmpty, ownerID != currentUserID, !isBlocked(ownerID) else { return nil }
        if let existing = instructors.first(where: { $0.ownerID == ownerID }) {
            if !isPreview, let l = await catalog.fetch(ownerIDs: [ownerID]).first { apply(l, to: existing); save() }
            return existing
        }
        guard !isPreview else { return nil }
        let listings = await catalog.fetch(ownerIDs: [ownerID])
        guard let listing = listings.first, listing.ownerID != currentUserID else { return nil }
        let nextId = (instructors.map(\.legacyId).max() ?? 0) + 1
        let nextOrder = (instructors.map(\.order).max() ?? 0) + 1
        let ins = Instructor(ownerID: listing.ownerID)
        ins.legacyId = nextId
        ins.order = nextOrder
        apply(listing, to: ins)
        context.insert(ins)
        save()
        return ins
    }

    private func apply(_ l: CatalogListing, to ins: Instructor) {
        ins.name = l.name; ins.city = l.city; ins.bio = l.bio; ins.price = l.price
        ins.yearsExp = l.yearsExp
        ins.specialties = l.specialties; ins.sessionTypes = l.sessionTypes
        ins.available = l.available; ins.hours = l.hours
        ins.rating = l.rating; ins.reviews = l.reviews; ins.img = l.img; ins.cert = l.cert
        ins.paymentMethods = l.paymentMethods
        // Flowe Pro career layer — the fetched listing carries these, so another user sees the
        // instructor's headline/story/experience. See [[FlowePro]].
        ins.headline = l.headline; ins.story = l.story; ins.experienceTokens = l.experience
        ins.brandColor = l.brandColor
        ins.visibilityRaw = l.visibility
        ins.communityVisible = l.communityVisible   // Flowe Community peer opt-in

        // Assigned unconditionally, nil included: an instructor who removed their studio location must
        // stop being placed on the map on everyone else's device. Stored EXACTLY (no snapping) — the
        // studio point is a published business location — alongside the studio `address`.
        ins.setStudioLocation(latitude: l.latitude, longitude: l.longitude, address: l.address)
        ins.visibilityVerifiedAt = Date()
        // Only overwrite a cached image when the server actually has one. A nil here usually means
        // "this listing has no upload", but for my own listing it can also mean my photo hasn't
        // reached the server yet — and clobbering it would lose the picture the user just chose.
        if let photo = l.photo {
            ins.photo = photo
            // Hand the avatar to the Notification Service Extension (keyed by ownerID) so an
            // incoming-DM Communication Notification can show this counterpart's photo. See [[AvatarCache]].
            if let owner = ins.ownerID { AvatarCache.write(senderID: owner, photo: photo) }
        }
        // Cache the display name too (even without a photo) so a DM notification shows this person's
        // CURRENT name, not the message's frozen/empty snapshot. See [[AvatarCache]].
        if let owner = ins.ownerID { AvatarCache.writeName(senderID: owner, name: l.name) }
        // Assigned unconditionally, unlike `photo` above: the nil-skip there protects the owner's
        // own not-yet-uploaded image, but for someone else's cached listing a nil means the
        // instructor removed the certificate — and a withdrawn credential must stop being shown.
        ins.certPhoto = l.certPhoto
        // Same rule for the brand cover — a removed cover must stop showing on other devices.
        ins.coverPhoto = l.coverPhoto
    }

    /// The signed-in instructor's own listing (resolved by owner), if it exists.
    var currentInstructor: Instructor? {
        guard let currentUserID else { return nil }
        return instructors.first { $0.ownerID == currentUserID }
    }

    /// Ensures the signed-in instructor has an (empty, editable) listing. Called on instructor login.
    @discardableResult
    func ensureInstructorProfile(ownerID: String, name: String, city: String = "") -> Instructor {
        let instructor: Instructor
        if let existing = instructors.first(where: { $0.ownerID == ownerID }) {
            instructor = existing
        } else {
            let nextId = (instructors.map(\.legacyId).max() ?? 0) + 1
            let nextOrder = (instructors.map(\.order).max() ?? 0) + 1
            // No backfilled session type: a new instructor starts with zero lesson types (an honest empty
            // state the editor prompts them to fill), rather than a fake default "Private" nobody authored.
            instructor = Instructor(
                legacyId: nextId, name: name, city: city,
                order: nextOrder, ownerID: ownerID
            )
            context.insert(instructor)
        }
        #if DEBUG
        // Two-party test harness: `-flowe.debugForceVisible 1` (or the broader `-flowe.debugBypassStoreKit
        // 1`, which also opens every app-side subscription gate) grants discoverability WITHOUT a real
        // StoreKit purchase, so a test instructor appears in the student's Discover feed and is bookable.
        // Marks the listing for republish so `flushPendingListing` pushes visibility>0 (and the derived
        // price) to the public catalog — belt-and-suspenders alongside the tier→applyVisibility path, in
        // case `onChange` misses the launch-time transition. Never ships.
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "flowe.debugForceVisible") || defaults.bool(forKey: "flowe.debugBypassStoreKit") {
            instructor.visibility = .visible
            instructor.visibilityVerifiedAt = Date()
            instructor.pendingPublish = true
        }
        #endif
        save()
        return instructor
    }

    // Throttle chatty foreground re-syncs + prevent the login Task and a near-simultaneous
    // scenePhase Task from running two concurrent fetch+apply passes over the own row.
    private var lastOwnListingResyncAt: Date?
    private var isResyncingOwnListing = false

    private func isBlankProfile(_ ins: Instructor) -> Bool {
        ins.photo == nil && (ins.bio?.isEmpty ?? true) && ins.specialties.isEmpty
    }

    /// Sync the signed-in instructor's OWN profile from their public listing across devices
    /// (last-writer-wins). `Instructor` lives in the Reference `.none` config (LOCAL-ONLY, never
    /// CloudKit-mirrored), so an instructor's own row does NOT sync device→device via the private DB;
    /// their public `InstructorListing` is the only cross-device channel. `ensureInstructorProfile`
    /// creates a blank row on a fresh device; this pulls the listing back and `apply`s it (photo + bio
    /// + specialties + price + city + availability together). Called on login AND on foreground.
    ///
    /// Anti-self-clobber (a stale pull once wiped a just-closed availability — see `syncCatalog`):
    /// apply ONLY when there are no unpublished local edits (`!pendingPublish`) AND the row is either
    /// blank OR the server copy is STRICTLY newer than our baseline (`lastSyncedAt`, always a server
    /// `modificationDate`, never a device clock). `pendingPublish` is re-read AFTER the fetch so an
    /// edit begun mid-fetch wins. Still the ONLY sanctioned path that applies the current user's own
    /// listing — the three catalog syncs keep excluding `currentUserID`.
    func hydrateOwnListingIfNeeded() async {
        guard !isPreview, !isResyncingOwnListing,
              let me = currentInstructor, let ownerID = me.ownerID else { return }
        let blank = isBlankProfile(me)
        // Never throttle a genuine fresh (blank) hydrate; only throttle chatty foreground re-pulls.
        if !blank, Date().timeIntervalSince(lastOwnListingResyncAt ?? .distantPast) < 45 { return }
        guard !me.pendingPublish else { return }

        isResyncingOwnListing = true
        lastOwnListingResyncAt = Date()
        defer { isResyncingOwnListing = false }

        guard let listing = await catalog.fetch(ownerIDs: [ownerID]).first,
              listing.ownerID == ownerID else { return }
        // Re-read after the await: a local edit begun while the fetch was in flight must win.
        guard !me.pendingPublish,
              isBlankProfile(me) || (listing.modifiedAt ?? .distantPast) > (me.lastSyncedAt ?? .distantPast)
        else { return }
        apply(listing, to: me)
        me.lastSyncedAt = listing.modifiedAt   // baseline = server timestamp we just applied
        save()
    }

    // MARK: - Student profiles (public directory, mirror of the instructor listing pipeline)

    /// A cached student's public profile, by owner (counterpart to `organizerListing`).
    func studentProfile(forOwnerID id: String) -> StudentProfile? {
        studentProfiles.first { $0.ownerID == id }
    }

    /// A cached student's published photo, if any — used to render their avatar to an instructor.
    func studentPhoto(forOwnerID id: String) -> Data? {
        studentProfile(forOwnerID: id)?.photo
    }

    /// The signed-in student's own profile row (resolved by owner), if it exists.
    var currentStudentProfile: StudentProfile? {
        guard let currentUserID else { return nil }
        return studentProfiles.first { $0.ownerID == currentUserID }
    }

    /// Ensures the signed-in student has a local profile row. Called on student login (mirror of
    /// `ensureInstructorProfile`).
    @discardableResult
    func ensureStudentProfile(ownerID: String, name: String, memberSince: Date = Date()) -> StudentProfile {
        if let existing = studentProfiles.first(where: { $0.ownerID == ownerID }) { return existing }
        let nextId = (studentProfiles.map(\.legacyId).max() ?? 0) + 1
        let nextOrder = (studentProfiles.map(\.order).max() ?? 0) + 1
        let profile = StudentProfile(
            legacyId: nextId, ownerID: ownerID, name: name,
            memberSince: memberSince, order: nextOrder
        )
        context.insert(profile)
        save()
        return profile
    }

    /// Pull the signed-in STUDENT's OWN name/photo/bio back from their public profile — the exact
    /// `StudentProfile` record an instructor already sees on their bookings. A signed-out→signed-in
    /// student (or a fresh device on the same Apple id) has a blank local row from `ensureStudentProfile`
    /// and a `currentUser` rebuilt from Apple (no name after the first authorization, never a photo), so
    /// "My Profile" reads blank while the public record is intact. Mirror of `hydrateOwnListingIfNeeded`.
    /// Fills only EMPTY local fields (never clobbers a fresh edit) and returns the listing so `AppSession`
    /// can refill `currentUser`. nil when nothing is published (e.g. after account deletion), so a
    /// re-signup can never resurrect a deleted profile.
    @discardableResult
    func hydrateOwnStudentProfileIfNeeded() async -> StudentListing? {
        guard !isPreview, let ownerID = currentUserID else { return nil }
        guard let listing = await studentDirectory.fetch(ownerID: ownerID) else { return nil }
        // Refresh the local cache row so the student's own avatar resolves everywhere it's shown by id.
        let me = currentStudentProfile ?? ensureStudentProfile(
            ownerID: ownerID, name: listing.name, memberSince: listing.memberSince
        )
        if AppSession.isPlaceholderName(me.name) { me.name = listing.name }
        if me.photo == nil { me.photo = listing.photo }
        if (me.bio ?? "").isEmpty { me.bio = listing.bio }
        if me.memberSince == .distantPast { me.memberSince = listing.memberSince }
        save()
        return listing
    }

    /// Apply the student's edits to their own profile and publish it (mirror of `commit`).
    func saveStudentProfile(name: String, bio: String?, photo: Data?, memberSince: Date) {
        let me = currentStudentProfile ?? ensureStudentProfile(
            ownerID: currentUserID ?? FloweConstants.localOwnerID, name: name, memberSince: memberSince
        )
        me.name = name
        me.bio = bio
        me.photo = photo
        me.memberSince = memberSince
        me.updatedAt = Date()
        publishMyStudentProfile()
    }

    private func publishMyStudentProfile() {
        guard let me = currentStudentProfile else { return }
        me.pendingPublish = true
        save()
        guard !isPreview else { return }
        Task {
            if await studentDirectory.publish(me) {
                me.pendingPublish = false
                save()
            }
        }
    }

    // MARK: - Flowe Community opt-in (see + be seen — symmetric for students AND instructors)

    /// Whether the SIGNED-IN user has opted into the Flowe Community peer layer — resolved from whichever
    /// public record they own (an instructor opts in on their listing, a student on their profile), so
    /// both roles participate symmetrically.
    var isCommunityVisible: Bool {
        (currentInstructor?.communityVisible ?? false) || (currentStudentProfile?.communityVisible ?? false)
    }

    /// Whether a PEER (by ownerID) has opted in — checks whichever public record they own (instructor
    /// listing OR student profile). Every roster filters through this so instructors and students appear
    /// to each other symmetrically.
    func peerCommunityVisible(_ ownerID: String) -> Bool {
        instructor(ownerID: ownerID)?.communityVisible == true
            || studentProfile(forOwnerID: ownerID)?.communityVisible == true
    }

    /// A community peer's avatar photo — resolves an INSTRUCTOR's or a STUDENT's uploaded photo (via the
    /// shared `displayIdentity` resolver), so a roster chip shows the right face for either role.
    func peerPhoto(forOwnerID ownerID: String) -> Data? {
        displayIdentity(ownerID: ownerID, fallbackName: "").photo
    }

    /// The single community opt-in. Role-aware: an instructor flips it on their LISTING (published via
    /// `publishMyListing`), a student on their PROFILE. Reciprocity: opting in is what lets you both see
    /// other members AND appear to them. See [[Flowe-Community]].
    func setCommunityVisible(_ on: Bool) {
        // Enforce the opt-in server-side too — this is what makes the event "who's going" roster secure
        // (the backend returns a name only when both viewer and attendee have opted in).
        Task { await FloweBackendClient.shared.setCommunityVisible(on, name: currentUserName) }
        if let ins = currentInstructor {
            ins.communityVisible = on
            publishMyListing()   // marks pendingPublish + publishes the listing with the new flag
            return
        }
        let me = currentStudentProfile ?? ensureStudentProfile(
            ownerID: currentUserID ?? FloweConstants.localOwnerID, name: currentUserName
        )
        me.communityVisible = on
        // Capture where they stand NOW so joining with existing history doesn't retro-post every past
        // milestone at once — only thresholds crossed AFTER opting in are celebrated. Re-baselined on
        // each opt-in. See `checkMilestones` and [[Flowe-Community]].
        if on { me.communityBaselineSessions = completedSessionCount }
        me.updatedAt = Date()
        publishMyStudentProfile()
    }

    /// Completed sessions for the signed-in student — the basis for both the community opt-in baseline
    /// and milestone detection (kept in one place so the two never drift).
    private var completedSessionCount: Int { myBookings.filter { $0.status == .completed }.count }

    /// Warm a roster's peers — BOTH student profiles and instructor listings — so their identity and
    /// current community opt-in resolve. Re-fetches a peer whose cached copy reads not-visible (they may
    /// have opted in since); skips already-visible ones, so it stays cheap. Bounded by roster size.
    func warmRosterPeers(_ ownerIDs: Set<String>) async {
        await fetchAuthorProfiles(ownerIDs, refreshVisibility: true)   // students
        for id in ownerIDs where !peerCommunityVisible(id) {
            _ = await loadInstructor(ownerID: id)                     // no-ops for a non-instructor id
        }
    }

    /// Accepted event guests who have opted into Flowe Community — the ONLY attendees shown to peers on
    /// the "who's going" list. Warmed via `warmRosterPeers`; any not yet cached are omitted until they
    /// load. Resolves BOTH students and instructors. Newest-joined last (roster order).
    func communityAttendees(for event: CommunityEvent) -> [RemoteRegistration] {
        acceptedGuests(for: event).filter { peerCommunityVisible($0.studentID) }
    }

    // MARK: - Event discussion (Flowe Community slice 2)
    //
    // Reuses the [[PostComment]] + [[CommunityService]] comment machinery keyed on the EVENT's recordName
    // as the parent id — so an event thread needs NO new record type and NO Production deploy. Event ids
    // (`event-<uuid>`) never collide with post ids, and `recountComments` no-ops when no FeedPost matches.

    /// The event's discussion, oldest-first; blocked authors and not-yet-withdrawn deletes hidden.
    func eventComments(for event: CommunityEvent) -> [PostComment] {
        guard let id = event.remoteID else { return [] }
        return postComments
            .filter { $0.postID == id && !$0.pendingDelete && !isBlocked($0.authorID) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Whether the signed-in student may take part in an event's discussion: opted into the community AND
    /// either going (accepted) or hosting. Keeps the conversation to the people actually in the room.
    func canDiscuss(_ event: CommunityEvent) -> Bool {
        guard isCommunityVisible else { return false }
        return requestState(for: event) == .accepted || event.organizerID == currentUserID
    }

    /// Post to an event's discussion. Gated by `canDiscuss`; the caller screens the text (ContentFilter).
    func addEventComment(to event: CommunityEvent, text: String) {
        guard let me = currentUserID, let id = event.remoteID, canDiscuss(event) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let comment = PostComment(postID: id, authorID: me, authorName: currentUserName,
                                  text: trimmed, pendingUpload: true)
        context.insert(comment)
        save()
        guard !isPreview else { return }
        Task { await upload(comment) }
    }

    /// Pull an event's discussion + warm the commenters' current identities.
    func syncEventComments(for event: CommunityEvent) async {
        guard !isPreview, let id = event.remoteID else { return }
        await flushPendingCommunityWrites()
        guard let remote = await communityService.fetchComments(postIDs: [id]) else { return }
        mergeComments(remote, for: [id])
        await fetchAuthorProfiles(Set(eventComments(for: event).map(\.authorID)))
    }

    // MARK: - Class-mates presence (Flowe Community slice 3)

    /// Whether a booking is a group class (capacity ≥ 2) — resolved from the live lesson type, falling
    /// back to the frozen `bookedCapacity`. Drives the "who's in this class" affordance.
    func isGroupBooking(_ booking: Booking) -> Bool {
        (bookingCapacity(booking) ?? booking.bookedCapacity) >= 2
    }

    /// The signed-in student's community class-mates for a group booking: the OTHER community-visible
    /// students in the SAME slot (instructor + date + time + type), active, not me, not blocked. Async —
    /// a student doesn't cache others' bookings, so it fetches the public slot roster, warms each peer's
    /// profile, and keeps only those opted into the community. Empty unless the viewer is opted in too.
    func fetchClassmates(for booking: Booking) async -> [(id: String, name: String)] {
        guard !isPreview, isCommunityVisible, isGroupBooking(booking),
              let instructorID = booking.instructorOwnerID, let me = currentUserID,
              let roster = await bookingService.fetchSlotRoster(instructorID: instructorID, date: booking.date)
        else { return [] }
        let peers = roster.filter {
            $0.time == booking.time && $0.type == booking.type && !$0.cancelled
                && $0.studentID != me && !isBlocked($0.studentID)
        }
        await warmRosterPeers(Set(peers.map(\.studentID)))
        var seen = Set<String>()
        var out: [(id: String, name: String)] = []
        for p in peers where !seen.contains(p.studentID) {
            seen.insert(p.studentID)
            // Community-visibility is now enforced SERVER-side (/roster returns only community-visible
            // peers, from the authoritative backend `profiles` table) — so we no longer consult the
            // divergent CloudKit `peerCommunityVisible` flag, which read false while the backend read true
            // and silently emptied the roster. warmRosterPeers above still resolves display name/photo.
            let n = displayIdentity(ownerID: p.studentID, fallbackName: p.studentName).name
            out.append((p.studentID, n.isEmpty ? p.studentName : n))
        }
        return out
    }

    // MARK: - Instructor community circle (Flowe Community slice 4)

    /// The signed-in student's view of an instructor's community CIRCLE: the community-visible students who
    /// train with `ownerID` (≥1 active booking with them), excluding me and blocked users. This is the
    /// instructor-anchored hub that seeds each circle — every instructor arrives with existing students, so
    /// there's an instant small community without any global density. Async — fetches the instructor's
    /// public bookings, warms profiles, keeps only community opt-ins. Empty unless the viewer is opted in
    /// too. See [[Flowe-Community]].
    func fetchInstructorCircle(ownerID: String) async -> [(id: String, name: String)] {
        // DISABLED under the booking-backend privacy model. This previously fetched a FOREIGN
        // instructor's ENTIRE student roster (`fetchForInstructor(ownerID: X)`) and showed it to any
        // profile viewer — exactly the who-trains-with-whom relationship-graph exposure the backend
        // exists to stop. The backend only ever returns the CALLER's own inbox, never a stranger's, so
        // this can't be satisfied without re-opening the leak. Re-enabling needs a consent-enforced,
        // backend-scoped design (see flowe-booking-privacy-deferred / [[BookingBackend]]).
        // `fetchClassmates` stays: it is party-scoped to a slot the viewer is actually booked into.
        return []
    }

    // MARK: - Circle discussion (Flowe Community slice 4b)
    //
    // The instructor's students actually talk. Reuses the community-comment machinery keyed on a
    // namespaced circle id (`circle-<ownerID>`, collision-proof vs post/event ids) — no new record type.

    private static func circleThreadID(_ ownerID: String) -> String { "circle-\(ownerID)" }

    /// The circle chat for an instructor, oldest-first; blocked authors + pending deletes hidden.
    func circleComments(for ownerID: String) -> [PostComment] {
        let id = Self.circleThreadID(ownerID)
        return postComments
            .filter { $0.postID == id && !$0.pendingDelete && !isBlocked($0.authorID) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Whether the signed-in user may take part in an instructor's circle chat: opted into the community
    /// AND either training with them (an active booking) or being the instructor themselves.
    func canDiscussCircle(ownerID: String) -> Bool {
        guard isCommunityVisible, let me = currentUserID else { return false }
        return me == ownerID
            || myBookings.contains { $0.instructorOwnerID == ownerID && $0.status != .cancelled }
    }

    /// Post to an instructor's circle chat. Gated by `canDiscussCircle`; caller screens the text.
    func addCircleComment(to ownerID: String, text: String) {
        guard let me = currentUserID, canDiscussCircle(ownerID: ownerID) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let comment = PostComment(postID: Self.circleThreadID(ownerID), authorID: me,
                                  authorName: currentUserName, text: trimmed, pendingUpload: true)
        context.insert(comment)
        save()
        guard !isPreview else { return }
        Task { await upload(comment) }
    }

    /// Pull a circle chat + warm the participants' current identities.
    func syncCircleComments(for ownerID: String) async {
        guard !isPreview else { return }
        let id = Self.circleThreadID(ownerID)
        await flushPendingCommunityWrites()
        guard let remote = await communityService.fetchComments(postIDs: [id]) else { return }
        mergeComments(remote, for: [id])
        await fetchAuthorProfiles(Set(circleComments(for: ownerID).map(\.authorID)))
    }

    // MARK: - Practice milestones (Flowe Community slice 5)
    //
    // When a community-opted-in student crosses a session-count threshold, auto-post a celebratory
    // milestone to the feed so peers can cheer (a like on a milestone = a cheer). Idempotent via a
    // deterministic recordName `milestone-<studentID>-<N>` (one celebration per threshold, ever). Only
    // notable counts — never the noisy first session. No schema change (`type` is a free string field).

    /// The session counts worth celebrating publicly (skips 1/5 — too noisy for the shared feed).
    private static let sessionMilestones = [10, 25, 50, 100]

    /// Detect and post any newly-crossed practice milestones for the signed-in student. Gated on the
    /// community opt-in (auto-posting is a public act → only for those who joined the community). Cheap +
    /// idempotent; safe to call whenever bookings or the feed refresh.
    func checkMilestones() {
        // Only post once the community feed has actually LOADED this session — otherwise, right after a
        // reinstall (when `posts` is still empty and the local baseline reset to 0) the dedup check below
        // can't see already-celebrated milestones and would re-post every past threshold to the author's
        // own feed. Gating on `.loaded` means `posts` reflects the server, so the dedup holds.
        guard !isPreview, isCommunityVisible, communityPhase == .loaded, let me = currentUserID else { return }
        let completed = completedSessionCount
        // Only celebrate thresholds crossed AFTER opting in — the baseline captured at opt-in suppresses
        // a first-run flood for students who join with existing history (deterministic recordName still
        // dedupes everything else). See `setCommunityVisible`.
        let baseline = currentStudentProfile?.communityBaselineSessions ?? 0
        for n in Self.sessionMilestones where n > baseline && completed >= n {
            let recordName = "milestone-\(me)-\(n)"
            if let existing = posts.first(where: { $0.remoteID == recordName }) {
                // Already celebrated — but retry an upload that never landed (offline first time).
                if existing.pendingUpload { Task { await uploadMilestone(existing, recordName: recordName) } }
                continue
            }
            let post = FeedPost(
                legacyId: (posts.map(\.legacyId).max() ?? 0) + 1,
                type: .milestone,
                user: currentUserName,
                text: String(localized: "Completed \(n) Pilates sessions."),
                ownerID: me,
                remoteID: recordName,   // deterministic up front — dedupes local + server
                pendingUpload: true
            )
            context.insert(post)
            save()
            Task { await uploadMilestone(post, recordName: recordName) }
        }
    }

    private func uploadMilestone(_ post: FeedPost, recordName: String) async {
        guard let authorID = post.ownerID else { return }
        let saved = await communityService.publishMilestone(
            recordName: recordName, authorID: authorID, authorName: post.user,
            text: post.text, createdAt: post.createdAt)
        if let saved { post.remoteID = saved }
        post.pendingUpload = (saved == nil)
        save()
    }

    // MARK: - Practice friends (Flowe Community slice 6)

    /// The follow edges the signed-in student authored — who they follow. In-memory (re-fetched); a
    /// social graph is cheap to refresh and doesn't need offline persistence.
    private(set) var follows: [RemoteFollow] = []

    /// Whether the signed-in student follows `studentID`.
    func isFollowing(_ studentID: String) -> Bool { follows.contains { $0.followeeID == studentID } }

    /// The signed-in student's practice friends (who they follow), newest first.
    var practiceFriends: [(id: String, name: String)] {
        follows.sorted { $0.createdAt > $1.createdAt }.map { ($0.followeeID, $0.followeeName) }
    }

    /// Follow a practice-friend (someone met via a shared context). Optimistic + published.
    func follow(_ studentID: String, name: String) {
        guard let me = currentUserID, me != studentID, !isFollowing(studentID) else { return }
        follows.append(RemoteFollow(
            id: CommunityService.followRecordName(follower: me, followee: studentID),
            followerID: me, followeeID: studentID, followeeName: name, createdAt: Date()))
        guard !isPreview else { return }
        Task { await communityService.follow(followerID: me, followeeID: studentID, followeeName: name) }
    }

    /// Unfollow — optimistic local removal + server delete.
    func unfollow(_ studentID: String) {
        guard let me = currentUserID else { return }
        follows.removeAll { $0.followeeID == studentID }
        guard !isPreview else { return }
        Task { await communityService.unfollow(followerID: me, followeeID: studentID) }
    }

    /// Pull the signed-in student's follow list. Nil fetch keeps the cache (mirrors the other syncs).
    func syncFollows() async {
        guard !isPreview, let me = currentUserID else { return }
        if let fetched = await communityService.fetchFollows(followerID: me) { follows = fetched }
    }

    /// Re-publish a student profile whose last save never landed (mirror of `flushPendingListing`).
    func flushPendingStudentProfile() async {
        guard !isPreview, let me = currentStudentProfile, me.pendingPublish else { return }
        if await studentDirectory.publish(me) {
            me.pendingPublish = false
            save()
        }
    }

    /// Pre-warm the instructor-side cache of the students they transact with. Targeted fetch by
    /// ownerID — students are never enumerable — and prunes nothing.
    func syncStudentProfiles() async {
        guard !isPreview else { return }
        let wanted = Set(incomingBookings.compactMap(\.studentID))
            .union(conversations.map { $0.counterpart.id })
            // Reviewers too, so an instructor's review wall resolves the reviewer's CURRENT name/photo
            // rather than the snapshot `Review.studentName` (re-stamped from the remote each sync).
            .union(reviews.map(\.studentID))
            .subtracting([currentUserID].compactMap { $0 })
            .subtracting(blockedIDs)
        guard !wanted.isEmpty else { return }
        let listings = await studentDirectory.fetch(ownerIDs: Array(wanted))
        upsert(listings)
        save()
    }

    /// Insert-or-update cached `StudentProfile` rows from fetched listings. Shared by
    /// `syncStudentProfiles` (bookers / DM partners / reviewers) and `fetchAuthorProfiles` (community
    /// authors) so both grow the same non-enumerable, by-ownerID-only cache.
    private func upsert(_ listings: [StudentListing]) {
        var nextId = studentProfiles.map(\.legacyId).max() ?? 0
        var nextOrder = studentProfiles.map(\.order).max() ?? 0
        for listing in listings {
            guard listing.ownerID != currentUserID else { continue }
            if let existing = studentProfiles.first(where: { $0.ownerID == listing.ownerID }) {
                apply(listing, to: existing)
            } else {
                nextId += 1; nextOrder += 1
                let p = StudentProfile(ownerID: listing.ownerID)
                p.legacyId = nextId
                p.order = nextOrder
                apply(listing, to: p)
                context.insert(p)
            }
        }
    }

    /// Single non-pruning fetch for one open profile view (mirror of `syncReviews(forInstructor:)`).
    func syncStudentProfile(ownerID: String) async {
        guard !isPreview, ownerID != currentUserID else { return }
        guard let listing = await studentDirectory.fetch(ownerID: ownerID) else { return }
        if let existing = studentProfiles.first(where: { $0.ownerID == ownerID }) {
            apply(listing, to: existing)
        } else {
            let nextId = (studentProfiles.map(\.legacyId).max() ?? 0) + 1
            let nextOrder = (studentProfiles.map(\.order).max() ?? 0) + 1
            let p = StudentProfile(ownerID: ownerID)
            p.legacyId = nextId
            p.order = nextOrder
            apply(listing, to: p)
            context.insert(p)
        }
        save()
    }

    private func apply(_ l: StudentListing, to p: StudentProfile) {
        p.name = l.name
        p.bio = l.bio
        p.memberSince = l.memberSince
        p.updatedAt = l.updatedAt
        p.communityVisible = l.communityVisible
        // Only overwrite a cached image when the server actually has one — protects the owner's own
        // not-yet-uploaded photo, exactly like the Instructor rule.
        if let photo = l.photo {
            p.photo = photo
            // Cache the avatar for the Notification Service Extension, keyed by ownerID. See [[AvatarCache]].
            if let owner = p.ownerID { AvatarCache.write(senderID: owner, photo: photo) }
        }
        // Cache the student's current name for the DM notification (see [[AvatarCache]]) — not just the photo.
        if let owner = p.ownerID { AvatarCache.writeName(senderID: owner, name: l.name) }
    }

    // MARK: - Out of Studio (coverage)
    //
    // Auto-fan matching with two-sided approval, cloned structurally from No-Show Shield and Bookings.
    // When an instructor reports OOS for a window, the app ranks eligible instructors on-device and
    // writes one addressed CoverageOffer per top candidate (K ≤ 10). A candidate *claims* (their
    // approval); the owner *awards* by flipping the request's `filledByID` (their approval). A swap is
    // confirmed only when both are true — then a 50% ledger materialises on each side (owner owes /
    // replacer is owed), tracked off-app exactly like the No-Show fee. The student's SessionBooking is
    // never mutated: the owner writes a CoverageSession addressed to the student, and their card just
    // reads "Covered by <name>".
    //
    // PILOT-ONLY PRIVACY NOTE. This deepens the world-readable booking exposure documented in
    // BOOKING-SYSTEM.md. No Coverage* record ever carries studentName/studentID or a coordinate — the
    // ONE exception is CoverageSession, which is addressed to the student it concerns (studentID is its
    // recipient key). Offers carry only bookingID + coarse-area-by-reference, so a replacer never learns
    // whose session they are covering (see the empty `studentName` on the cover shadow below).
    //
    // These caches are network-derived and in-memory (like `bookingsPhase`): a sync repopulates them,
    // and they drive the owner picker (`myCoverRequests` + `myClaims`) and the replacer inbox
    // (`myOffers`). The persisted state is only the per-booking ledger (`coverRole` / `coverAmount`
    // / `coverStatus`), which survives offline like the No-Show ledger it clones.

    // MARK: - Class packages / credits ([[ClassPackages]])
    //
    // Money-adjacent state ("6 classes left") lives ONLY on the backend behind per-request authz; these
    // are in-memory, network-derived caches (like the coverage caches below) repopulated by the sync
    // methods — NO SwiftData @Model, NO CloudKit (a persisted balance would go stale, and forging is the
    // whole thing we're preventing). See ClassPackages.md.

    /// The signed-in instructor's package menu (active + archived), for the package manager.
    private(set) var myOfferings: [RemoteOffering] = []
    /// Purchase requests addressed to the signed-in instructor (pending first) — the approval inbox.
    private(set) var incomingPurchases: [RemotePurchase] = []
    /// The signed-in student's own purchase requests (to show "awaiting approval" on a profile).
    private(set) var myPurchases: [RemotePurchase] = []
    /// The student's whole credit wallet — one entry per instructor they hold credits with.
    private(set) var wallet: [InstructorBalance] = []
    /// Per-instructor credit detail (balance + lots) the student has fetched, keyed by instructorID —
    /// drives the "6 of 10" ring on the profile and in the booking sheet.
    private(set) var creditDetail: [String: CreditBalance] = [:]
    /// The instructor's clients and the credits they still hold (remaining/granted/₪value/expiry).
    /// Powers Finance Center's credit-liability + per-student balances (Phase B); empty until the
    /// `/credits/clients` endpoint is deployed.
    private(set) var studentBalances: [InstructorClientBalance] = []

    /// remoteID → when the booking was actually REQUESTED, harvested from `RemoteBooking.createdAt`
    /// during `syncBookings`. The local `Booking` @Model deliberately does NOT persist this (adding a
    /// stored property would add `CD_createdAt` to the CD_Booking CloudKit mirror and force a schema
    /// deploy), and `booking.date`/`.time` are the SESSION's slot, not the request time. Without this
    /// the Activity feed had no real date for booking rows and fell back to [[ActivityLedger]]'s
    /// device-local first-seen stamp — so on a fresh install every pending request read as "now".
    /// Memory-only is sufficient: `syncBookings` runs on launch and repopulates it from the server.
    private(set) var bookingRequestedAt: [String: Date] = [:]

    /// remoteID → when the instructor CONFIRMED/DECLINED it (`RemoteDecision.respondedAt`), and → when
    /// it was CANCELLED (`RemoteBooking.modifiedAt`, i.e. the backend's `cancelled_at`). Kept apart from
    /// `bookingRequestedAt` because an Activity row must show the time of the event it ANNOUNCES: a
    /// "confirmed your session" row that renders the original request time is just as wrong as one that
    /// renders "now". Same memory-only rationale as `bookingRequestedAt`.
    private(set) var bookingDecidedAt: [String: Date] = [:]
    private(set) var bookingCancelledAt: [String: Date] = [:]

    /// Pending package-purchase requests — the instructor dashboard signal card + the approval inbox badge.
    var pendingPurchaseCards: [RemotePurchase] { incomingPurchases.filter { $0.status == .pending } }

    /// Credits the student currently holds with one instructor (0 when unknown / none). Cheap accessor
    /// for gating the redeem toggle; `refreshBalance(with:)` populates `creditDetail` first.
    func creditBalance(with instructorID: String) -> Int { creditDetail[instructorID]?.balance ?? 0 }

    // Instructor: offerings + purchase inbox -------------------------------------

    /// Refresh the instructor's own package menu AND their incoming purchase-request inbox in one pass.
    func syncOfferings() async {
        guard !isPreview, currentUserID != nil else { return }
        if packagesPhase != .loaded { packagesPhase = .loading }
        let offerings = await packageService.fetchMyOfferings()
        let purchases = await packageService.fetchIncomingPurchases()
        guard offerings != nil || purchases != nil else {
            if packagesPhase != .loaded { packagesPhase = .failed }
            return
        }
        if let offerings { myOfferings = offerings }
        if let purchases {
            incomingPurchases = purchases
            // Warm the buyers' profiles so their photo resolves on the request card — a pack can be bought
            // before any booking, so purchasers aren't warmed by syncBookings.
            await fetchAuthorProfiles(Set(purchases.map { $0.studentID }))
        }
        await syncStudentBalances()
        packagesPhase = .loaded
    }

    /// Refresh the instructor's per-student credit balances (Finance Center Phase B). A nil fetch keeps
    /// the cache; empty/undeployed just leaves credit-liability showing "—".
    func syncStudentBalances() async {
        guard !isPreview, currentUserID != nil else { return }
        if let balances = await packageService.fetchClientBalances() { studentBalances = balances }
    }

    @discardableResult
    func saveOffering(id: String?, title: String, credits: Int, price: Int, validityDays: Int?) async -> Bool {
        guard await packageService.saveOffering(id: id, title: title, credits: credits, price: price, validityDays: validityDays) != nil else { return false }
        await syncOfferings()
        return true
    }

    func setOfferingActive(_ offering: RemoteOffering, active: Bool) async {
        guard await packageService.setOfferingActive(id: offering.id, active: active) else { return }
        await syncOfferings()
    }

    /// Instructor approves (grants credits) or declines a purchase request, then refreshes the inbox.
    func decidePurchase(_ purchase: RemotePurchase, approved: Bool) async {
        guard await packageService.decidePurchase(id: purchase.id, approved: approved) else { return }
        await syncOfferings()
    }

    // Student: browse + request --------------------------------------------------

    /// Public browse of an instructor's active offerings (works pre-session, for a guest on a profile).
    func fetchOfferings(for instructorID: String) async -> [RemoteOffering] {
        await packageService.fetchOfferings(instructorID: instructorID) ?? []
    }

    /// Request to buy a package — payment is offline; this only files the request the instructor approves.
    func requestPackage(offeringID: String) async -> PurchaseRequestResult {
        let result = await packageService.requestPurchase(offeringID: offeringID, studentName: currentUserName)
        if result == .requested { await syncMyPurchases() }
        return result
    }

    func syncMyPurchases() async {
        guard !isPreview, currentUserID != nil else { return }
        if let purchases = await packageService.fetchMyPurchases() { myPurchases = purchases }
    }

    /// Whether the student already has a pending buy request for this offering (drives the profile card's
    /// "Requested — awaiting approval" pill).
    func hasPendingPurchase(offeringID: String) -> Bool {
        myPurchases.contains { $0.offeringID == offeringID && $0.status == .pending }
    }

    // Student: wallet + per-instructor balance -----------------------------------

    /// The whole credit wallet. `recoverSession` (pull-to-refresh only) heals a session-less user, like
    /// `syncBookings` — a non-interactive read otherwise shows an empty wallet forever after a pre-backend
    /// sign-in.
    func syncWallet(recoverSession: Bool = false) async {
        guard !isPreview, currentUserID != nil else { return }
        if recoverSession { await FloweBackendClient.shared.recoverSessionIfNeeded() }
        if walletPhase != .loaded { walletPhase = .loading }
        guard let balances = await packageService.fetchWallet() else {
            if walletPhase != .loaded { walletPhase = .failed }
            return
        }
        wallet = balances
        walletPhase = .loaded
    }

    /// Fetch (and cache) the student's full credit detail with one instructor — called when the booking
    /// sheet opens and after any credit movement, so "N left" and the ring are server-fresh.
    @discardableResult
    func refreshBalance(with instructorID: String) async -> CreditBalance? {
        guard !isPreview, currentUserID != nil else { return nil }
        let detail = await packageService.fetchBalance(instructorID: instructorID)
        if let detail { creditDetail[instructorID] = detail }
        return detail
    }

    /// The signed-in owner's own OOS requests (addressed by `requesterID`).
    private var coverRequests: [RemoteCoverageRequest] = []
    /// Candidate claims filed against my requests (addressed by `requesterID`).
    private var coverClaims: [RemoteCoverageClaim] = []
    /// Offers addressed to me as a candidate (`candidateID`).
    private var coverOffers: [RemoteCoverageOffer] = []
    /// Cover sessions concerning my own bookings, fetched student-side (addressed by `studentID`).
    private var coverSessions: [RemoteCoverageSession] = []

    /// Top ≤ 10 instructors who could cover this session, ranked exactly as Discover ranks the feed.
    ///
    /// Filtered to instructors whose published hours on the session's weekday actually contain its
    /// time, minus myself. `visibleInstructors` is already Boost → rating → order, so distance only
    /// reorders peers *within* a tier (and does nothing when there is no fix) — the same rule
    /// `DiscoverView.byDistance` applies, so a boosted instructor is never overtaken by a closer free one.
    /// Eligible cover candidates for one session, nearest-first.
    ///
    /// Distance is measured from the requesting instructor's own **studio location** (their published,
    /// EXACT studio coordinate — where the session actually happens) to each candidate's studio point.
    /// The studio point is the source of truth for both ranking and the `radiusKm` cutoff — NOT the
    /// device's live GPS fix, which is irrelevant to where a handed-off session takes place.
    ///
    /// `radiusKm` is the instructor's own "how far will I look for cover" setting (AppSettings). It's
    /// enforced only when we have a studio location to measure from — if the instructor never set one,
    /// every distance is nil and we fall back to the tier+rating ranking over the whole eligible set
    /// rather than dropping everyone to zero. Candidates with no studio location can't be confirmed
    /// inside the radius, so they're dropped once the radius is in force.
    func oosCandidates(for booking: Booking, radiusKm: Double? = nil) -> [Instructor] {
        guard let weekday = Self.weekday(from: booking.date) else { return [] }
        let eligible = visibleInstructors.filter { ins in
            ins.ownerID != currentUserID && ins.hours(on: weekday).contains(booking.time)
        }
        // Exact studio point → exact studio point (no coarsening). Great-circle metres via CLLocation.
        let origin = currentInstructor?.studioCoordinate
        var measured = eligible.map { ins -> (instructor: Instructor, distanceMetres: Double?) in
            let distance = origin.flatMap { o in
                ins.studioCoordinate.map { c in
                    CLLocation(latitude: o.latitude, longitude: o.longitude)
                        .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
                }
            }
            return (instructor: ins, distanceMetres: distance)
        }
        if let radiusKm, radiusKm > 0, origin != nil {
            let limitMetres = radiusKm * 1000
            measured = measured.filter { ($0.distanceMetres ?? .greatestFiniteMagnitude) <= limitMetres }
        }
        let ranked = measured.sorted(by: Self.byCoverageDistance).map(\.instructor)
        return Array(ranked.prefix(Self.maxCoverageCandidates))
    }

    /// Confirmed, still-upcoming incoming sessions whose start falls inside the OOS window — the
    /// sessions the instructor is asking to hand off. Soonest first.
    func sessionsToCoverInWindow(start: Date, end: Date) -> [Booking] {
        incomingBookings
            .filter { booking in
                guard booking.status == .confirmed, let sessionStart = booking.sessionStart() else { return false }
                return sessionStart >= start && sessionStart <= end
            }
            .sorted { ($0.sessionStart() ?? .distantPast) < ($1.sessionStart() ?? .distantPast) }
    }

    /// Report OOS for one session: publish the request, then fan out one addressed offer per candidate.
    ///
    /// Initiating OOS is gated behind `subscription.isVisible` at the call site (the store has no
    /// SubscriptionService) — here we only guard that this is my own incoming, published booking.
    func requestCoverage(for booking: Booking, windowStart: Date, windowEnd: Date, candidates: [Instructor]) {
        guard !isPreview, let me = currentUserID,
              booking.instructorOwnerID == me,
              let bookingID = booking.remoteID else { return }
        // Durable "sent" marker, stamped synchronously (before the async publish) so the OOS row still
        // reads "Cover requested" after an app re-open, independent of a live `fetchMyRequests` re-fetch.
        // Reconciled against server truth in `syncCoverage`; cleared by `cancelCoverage`.
        booking.coverRole = .requested
        save()
        let candidateIDs = candidates.compactMap(\.ownerID).filter { $0 != me }
        Task {
            guard await coverageService.publishRequest(
                bookingID: bookingID,
                requesterID: me,
                sessionDate: booking.date, sessionTime: booking.time,
                sessionDuration: booking.duration, sessionType: booking.type,
                windowStart: windowStart, windowEnd: windowEnd
            ) != nil else { return }
            await coverageService.fanOutOffers(
                bookingID: bookingID, requesterID: me, candidateIDs: candidateIDs,
                sessionType: booking.type, sessionDate: booking.date
            )
            await syncCoverage(asInstructor: true)
        }
    }

    /// Cancel an OOS coverage request the instructor sent: withdraw the offers fanned to the other
    /// instructors (the swap requests they'd see in their inbox), mark the request cancelled server-side,
    /// and revert the session locally so it flips straight back to requestable — e.g. to re-send under a
    /// new date. Persisted. Reached pre-award (the picker only shows open requests).
    func cancelCoverage(for booking: Booking) {
        guard let bookingID = booking.remoteID else { return }
        // Optimistic local teardown: drop the cached request + its offers and clear the cover role.
        coverRequests.removeAll { $0.bookingID == bookingID }
        coverOffers.removeAll { $0.bookingID == bookingID }
        if booking.coverRole == .requested || booking.coverRole == .handedOff { booking.coverRole = .none }
        save()
        guard !isPreview else { return }
        Task {
            await coverageService.cancelRequest(bookingID: bookingID)
            await coverageService.withdrawOffers(bookingID: bookingID)
            await syncCoverage(asInstructor: true)
        }
    }

    /// A candidate accepts (or declines) an offer to cover — their side of the two-sided approval.
    func claimCoverage(bookingID: String, requesterID: String, accept: Bool) {
        guard !isPreview, let me = currentUserID else { return }
        Task {
            _ = await coverageService.claim(
                bookingID: bookingID, replacerID: me, replacerName: currentUserName,
                requesterID: requesterID, accepted: accept
            )
            await syncCoverage(asInstructor: true)
        }
    }

    /// The owner picks a winner — their side of the approval. Flips the request's `filledByID`, tells
    /// the student who is covering (CoverageSession), and materialises the owner-side ledger: the
    /// session is handed off and the replacer is owed half, frozen now.
    func awardCoverage(bookingID: String, replacerID: String, replacerName: String, studentID: String) {
        guard let me = currentUserID else { return }
        let booking = bookings.first(where: { $0.remoteID == bookingID })
        // Snapshot the cover fields BEFORE the optimistic ledger write, so a failed award (offline / no
        // iCloud) can be rolled back instead of leaving a phantom "owed" cover balance. Unlike bookings/
        // messages/posts this path has no pending-upload flush, so it must self-correct here.
        let prior = booking.map { (role: $0.coverRole, status: $0.coverStatus, amount: $0.coverAmount) }
        if let booking {
            materializeCover(booking, role: .handedOff, instructorID: me, sessionType: booking.type)
        }
        save()
        guard !isPreview else { return }
        Task {
            guard await coverageService.award(bookingID: bookingID, replacerID: replacerID) else {
                // The swap never landed server-side — undo the optimistic ledger.
                if let booking, let prior {
                    booking.coverRole = prior.role
                    booking.coverStatus = prior.status
                    booking.coverAmount = prior.amount
                    save()
                }
                return
            }
            _ = await coverageService.publishCoverSession(
                bookingID: bookingID, studentID: studentID,
                coveringInstructorID: replacerID, coveringInstructorName: replacerName, requesterID: me
            )
            await syncCoverage(asInstructor: true)
        }
    }

    /// Pull whichever side the user is on, resolve confirmed swaps, and cache what the surfaces read.
    /// Mirrors `syncBookings`: a nil fetch is a *failed* query, so the cache is kept rather than wiped.
    func syncCoverage(asInstructor: Bool) async {
        guard !isPreview, let me = currentUserID else { return }
        if asInstructor {
            // Owner side: my requests + the claims filed against them; settle any confirmed swap onto
            // my own booking (I owe the replacer half).
            let requests = await coverageService.fetchMyRequests(requesterID: me) ?? coverRequests
            let claims = await coverageService.fetchClaims(requesterID: me) ?? coverClaims
            coverRequests = requests
            coverClaims = claims
            for request in requests { resolveHandOff(request, claims: claims) }
            // Reconcile the persisted `.requested` flag against server truth: clear it ONLY for a request
            // the fetch RETURNED that is no longer open (cancelled == 2 / filled == 1). A request the fetch
            // did NOT return (offline nil-fetch keeps the prior cache, or a not-yet-healed row) is left
            // alone, so a genuinely-sent cover survives. Awarded requests were already moved to `.handedOff`
            // by `resolveHandOff` above, so this only closes out cancelled-elsewhere rows.
            for request in requests where request.status != 0 {
                if let booking = bookings.first(where: { $0.remoteID == request.bookingID }),
                   booking.coverRole == .requested {
                    booking.coverRole = .none
                }
            }

            // Replacer side: offers addressed to me drive the inbox; a session I was picked for becomes
            // a cover I'm owed for.
            let offers = await coverageService.fetchOffers(candidateID: me) ?? coverOffers
            coverOffers = offers
            for offer in offers {
                guard let request = await coverageService.fetchRequest(bookingID: offer.bookingID) else { continue }
                // Once the owner has picked ME, the CoverageSession carries the real student — I'm the
                // one about to teach them, so resolve their profile (name + photo) onto the cover
                // booking instead of the "cover-…" placeholder. Stays anonymous until I'm actually
                // awarded (`filledByID == me`), preserving the pre-award privacy of a broadcast offer.
                var student: (id: String, name: String)?
                if request.filledByID == me,
                   let cover = await coverageService.fetchCoverSession(bookingID: request.bookingID) {
                    await fetchAuthorProfiles([cover.studentID])
                    student = (cover.studentID, studentProfile(forOwnerID: cover.studentID)?.name ?? "")
                }
                resolveCovering(request, me: me, student: student)
            }
        } else {
            // Student side: informational only. Learn whether any of my bookings is being covered — the
            // booking itself is never touched (it is student-`_creator`-write).
            for booking in myBookings {
                guard let bookingID = booking.remoteID,
                      let cover = await coverageService.fetchCoverSession(bookingID: bookingID) else { continue }
                cacheCoverSession(cover)
            }
        }
        save()
    }

    // MARK: 50% ledger (cloned from the No-Show `markAttendance` / `resolveFee` / `owedFees` / `totalOwed`)

    /// Every session with an outstanding cover balance — the owner's handed-off sessions (money out)
    /// and the replacer's covered sessions (money in), which is why this reads the whole cache rather
    /// than `incomingBookings`: the two roles live on different rows. Newest session first.
    var coverOwed: [Booking] {
        bookings.filter { $0.coverStatus == .owed }
            .sorted { ($0.sessionEnd() ?? .distantPast) > ($1.sessionEnd() ?? .distantPast) }
    }

    /// Total currency outstanding across all covers.
    var totalCoverOwed: Int { coverOwed.reduce(0) { $0 + $1.coverAmount } }

    /// Resolve an outstanding cover balance once it has been settled off-app (collected or waived).
    func resolveCover(_ booking: Booking, to status: FeeStatus) {
        guard booking.coverStatus == .owed, status == .collected || status == .waived else { return }
        booking.coverStatus = status
        save()
    }

    // MARK: Picker + inbox accessors

    /// The signed-in owner's own OOS requests — drives the picker. Newest first.
    var myCoverRequests: [RemoteCoverageRequest] {
        coverRequests.sorted { $0.createdAt > $1.createdAt }
    }

    /// Accepted candidate claims filed against my requests — the shortlist the picker awards from.
    var myClaims: [RemoteCoverageClaim] {
        coverClaims.filter { $0.accepted }.sorted { $0.claimedAt > $1.claimedAt }
    }

    /// Sessions I've been asked to cover — the replacer inbox. Newest first.
    var myOffers: [RemoteCoverageOffer] {
        coverOffers.sorted { $0.createdAt > $1.createdAt }
    }

    /// Accepted claims for one request, so the picker can list the candidates under it.
    func claims(forBookingID bookingID: String) -> [RemoteCoverageClaim] {
        coverClaims.filter { $0.bookingID == bookingID && $0.accepted }
            .sorted { $0.claimedAt > $1.claimedAt }
    }

    /// For the student's booking card: the CoverageSession covering this booking, or nil. Read from the
    /// separate, student-addressed record — the booking itself is never mutated. The card checks the
    /// record's `status` (0 == covered) itself, so this returns the raw cached record.
    func coverSession(forBookingID bookingID: String) -> RemoteCoverageSession? {
        coverSessions.first { $0.bookingID == bookingID }
    }

    // MARK: Coverage internals

    private static let maxCoverageCandidates = 10

    /// A swap is confirmed once a candidate has claimed (accepted) AND the owner has picked them
    /// (`filledByID`) — the two-sided approval the whole flow turns on.
    private func isSwapConfirmed(request: RemoteCoverageRequest, claims: [RemoteCoverageClaim]) -> Bool {
        guard !request.filledByID.isEmpty else { return false }
        return claims.contains {
            $0.bookingID == request.bookingID && $0.replacerID == request.filledByID && $0.accepted
        }
    }

    /// Owner side: a confirmed swap on one of my requests hands that session off — I owe the replacer half.
    private func resolveHandOff(_ request: RemoteCoverageRequest, claims: [RemoteCoverageClaim]) {
        guard isSwapConfirmed(request: request, claims: claims),
              let booking = bookings.first(where: { $0.remoteID == request.bookingID }) else { return }
        materializeCover(booking, role: .handedOff, instructorID: request.requesterID, sessionType: request.sessionType)
    }

    /// Replacer side: a request the owner filled with *me* is a session I'm covering — I'm owed half.
    /// The session belongs to the original instructor, so there is no local booking to attach to until
    /// we materialise a private shadow for it. `student` (resolved from the CoverageSession the owner
    /// published on award) fills in who I'm actually teaching, so the covered session shows a real name
    /// + photo rather than the "cover-…" placeholder.
    private func resolveCovering(_ request: RemoteCoverageRequest, me: String, student: (id: String, name: String)?) {
        guard request.filledByID == me else { return }
        let booking = bookings.first(where: { $0.remoteID == request.bookingID }) ?? materializeCoverShadow(for: request)
        if let student, !student.id.isEmpty {
            booking.studentID = student.id
            if !student.name.isEmpty { booking.studentName = student.name }   // don't clobber a resolved name with a failed re-fetch
        }
        materializeCover(booking, role: .covering, instructorID: request.requesterID, sessionType: request.sessionType)
    }

    /// A private, instructor-local booking for a session I'm covering. Deliberately kept OUT of both
    /// `incomingBookings` (addressed to the original instructor, not me on the record) and `myBookings`
    /// (a synthetic student id that is neither nil nor mine), so a covered session surfaces only through
    /// the cover ledger and never pollutes earnings, the calendar or the student's own booking lists.
    /// The student's identity is absent by design — an offer/request never carries it (privacy).
    private func materializeCoverShadow(for request: RemoteCoverageRequest) -> Booking {
        let nextId = (bookings.map(\.legacyId).max() ?? 0) + 1
        let nextOrder = (bookings.map(\.order).max() ?? 0) + 1
        let booking = Booking(
            legacyId: nextId,
            date: request.sessionDate,
            time: request.sessionTime,
            type: request.sessionType,
            duration: request.sessionDuration,
            status: .confirmed,
            ownerID: currentUserID,
            order: nextOrder,
            remoteID: request.bookingID,
            instructorOwnerID: request.requesterID,
            studentID: "cover-\(request.bookingID)",
            studentName: ""
        )
        context.insert(booking)
        refresh()
        return booking
    }

    /// Set (or re-affirm) a booking's cover role and, the first time, its frozen 50% balance. The role
    /// is idempotent; the amount/status are written once and then left to the ledger (owed → collected
    /// / waived), exactly like `feeAmount` never being re-priced after it is first owed.
    private func materializeCover(_ booking: Booking, role: CoverRole, instructorID: String, sessionType: String) {
        booking.coverRole = role
        guard booking.coverStatus == .none else { return }
        booking.coverAmount = coverPrice(instructorID: instructorID, sessionType: sessionType) / 2
        booking.coverStatus = .owed
    }

    /// Price behind a cover, resolved like the No-Show fee: the matching lesson type's price, else the
    /// instructor's rate. Priced against the *session's* instructor so both sides agree — on the owner's
    /// device that is their own listing (so this equals `sessionPrice(for:)`); on the replacer's it is
    /// the cached original listing, falling back to its rate when its lesson types aren't cached.
    private func coverPrice(instructorID: String, sessionType: String) -> Int {
        guard let ins = instructors.first(where: { $0.ownerID == instructorID }) else { return 0 }
        return ownedLessonTypes(for: ins).first { $0.name == sessionType }?.price ?? ins.price
    }

    private func cacheCoverSession(_ cover: RemoteCoverageSession) {
        if let index = coverSessions.firstIndex(where: { $0.bookingID == cover.bookingID }) {
            coverSessions[index] = cover
        } else {
            coverSessions.append(cover)
        }
    }

    /// Rank cover candidates like `DiscoverView.byDistance`: visibility tier first (a paid Boost is
    /// never overtaken), then proximity among peers, then rating, then order. A candidate we can't
    /// measure sorts after measured peers *within its tier* rather than out of the list.
    private static func byCoverageDistance(
        _ lhs: (instructor: Instructor, distanceMetres: Double?),
        _ rhs: (instructor: Instructor, distanceMetres: Double?)
    ) -> Bool {
        let left = lhs.instructor, right = rhs.instructor
        if left.visibilityRaw != right.visibilityRaw { return left.visibilityRaw > right.visibilityRaw }
        if let a = lhs.distanceMetres, let b = rhs.distanceMetres {
            if a != b { return a < b }
        } else if lhs.distanceMetres != nil {
            return true
        } else if rhs.distanceMetres != nil {
            return false
        }
        if left.rating != right.rating { return left.rating > right.rating }
        return left.order < right.order
    }

    /// "Thu, Jul 17" → "Thu": the weekday token `Instructor.hours(on:)` keys by. Nil for anything that
    /// isn't one of `FloweConstants.weekdays`.
    private static func weekday(from date: String) -> String? {
        let token = date.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let token, FloweConstants.weekdays.contains(token) else { return nil }
        return token
    }

    // MARK: - Persistence

    private func save() {
        try? context.save()
        refresh()
    }
}

#if DEBUG
// MARK: - Dev fixtures (DEBUG ONLY — never ships, never touches CloudKit)

extension MockDataStore {

    fileprivate static let devSeedPrefix = "dev.seed."
    /// The signed-in student's debug ownerID (matches `-flowe.debugAppleUserID dev.student`). Stamped
    /// on seed bookings so instructor-side, student-correlated features resolve against a real id.
    fileprivate static let devStudentID = "dev.student"

    /// Local test fixture for the simulator. THREE guarantees keep it off CloudKit and out of release:
    ///  1. `#if DEBUG` — absent from the release binary.
    ///  2. Runs ONLY with BOTH `-flowe.seedDevData 1` AND `-flowe.disablePrivateSync 1`. The sync-off
    ///     flag forces the UserData SwiftData config to `.none` (see `FloweModelContainer`), so seeded
    ///     `Booking`/`LessonType`/`Review` rows stay on-device; `Instructor`/`StudentProfile` are ALWAYS
    ///     local (Reference `.none`). Without the sync-off flag the seed refuses to run.
    ///  3. Inserts straight into the local `context`; NEVER calls a publish/upload service.
    /// Idempotent — clears prior `dev.seed.*` rows first, so editing the fixture + relaunching is clean.
    func seedDevDataIfRequested() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "flowe.seedDevData") else { return }
        guard defaults.bool(forKey: "flowe.disablePrivateSync") else {
            print("⚠️ [DevSeed] Refusing to seed — also pass -flowe.disablePrivateSync 1 so fixtures never reach CloudKit.")
            return
        }
        clearDevSeed()

        let cal = Calendar.current
        func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: Date()) ?? Date() }

        // Instructors — Reference config (always local). name/price>0/visible/fresh-TTL → eligible.
        let specs: [(id: Int, owner: String, name: String, spec: [String], from: Int, rating: Double,
                     reviews: Int, vis: InstructorVisibility, lat: Double, lon: Double, address: String,
                     years: Int, cert: String, bio: String)] = [
            (9001, "dev.seed.1", "Maya Cohen",  ["Reformer", "Mat"],     180, 4.9, 32, .boosted, 32.0809, 34.7806, "12 Dizengoff St, Tel Aviv-Yafo", 8,  "STOTT Certified",    "Reformer-focused strength & alignment. Ex-dancer, 8 years teaching."),
            (9002, "dev.seed.2", "Noa Levi",    ["Mat", "Prenatal"],     150, 4.7, 18, .visible, 32.0750, 34.7750, "5 Rothschild Blvd, Tel Aviv-Yafo", 5, "Prenatal Certified", "Gentle mat & prenatal Pilates in a calm studio."),
            (9003, "dev.seed.3", "Dana Katz",   ["Reformer", "Tower"],   220, 5.0,  9, .visible, 32.0680, 34.8248, "20 Bialik St, Ramat Gan", 11,        "Polestar Certified", "Rehab-informed Reformer & Tower. Small groups only."),
            (9004, "dev.seed.4", "Yael Bar",    ["Barre", "Mat"],        160, 4.8, 24, .visible, 32.0900, 34.7700, "8 Ben Yehuda St, Tel Aviv-Yafo", 6,  "Barre Certified",    "High-energy barre + mat. Music-driven classes."),
            (9005, "dev.seed.5", "Tamar Shani", ["Reformer"],            200, 4.6, 12, .visible, 32.1620, 34.8440, "3 Sokolov St, Herzliya", 4,          "BASI Certified",     "Classical Reformer, one-on-one focus."),
            (9006, "dev.seed.6", "Rivka Gold",  ["Mat", "Prenatal"],     140, 0.0,  0, .visible, 32.0530, 34.7520, "40 Yefet St, Jaffa", 3,              "Mat Certified",      "New to Flowe — welcoming mat classes in Jaffa."),
        ]

        for (i, s) in specs.enumerated() {
            let ins = Instructor()
            ins.legacyId = s.id
            ins.ownerID = s.owner
            ins.name = s.name
            ins.specialties = s.spec
            ins.sessionTypes = s.spec            // denormalised names for the student catalog card
            ins.price = s.from                   // "from" price (>0 → eligible)
            ins.rating = s.rating
            ins.reviews = s.reviews
            ins.visibility = s.vis
            ins.visibilityVerifiedAt = Date()    // fresh → passes the 7-day eligibility TTL
            ins.yearsExp = s.years
            ins.students = s.reviews
            ins.cert = s.cert
            ins.bio = s.bio
            ins.img = ""                         // empty → branded gradient placeholder avatar
            ins.available = ["Mon", "Tue", "Wed", "Thu", "Fri"]
            ins.paymentMethods = ["Cash", "Bit"]
            ins.order = i
            ins.setStudioLocation(latitude: s.lat, longitude: s.lon, address: s.address)
            // Flowe Pro career layer (Phase 1) — seed the lead instructor with a headline + work
            // history so the Pro sections render live. See [[FlowePro]].
            if s.owner == "\(Self.devSeedPrefix)1" {
                ins.headline = "Reformer & alignment specialist · ex-dancer, STOTT-certified"
                ins.story = "I build strength through precise, breath-led Reformer work. Ten years in "
                    + "studios across Tel Aviv, now growing my own practice on Flowe."
                ins.brandColor = "#C67B5C"   // warm terracotta — a deliberate studio brand accent

                ins.experienceTokens = [
                    "2021-now|Independent · Flowe|Founder & lead instructor",
                    "2018-2021|Studio Viva, Tel Aviv|Senior Reformer instructor",
                    "2016-2018|BodyLine Pilates|Instructor (apprenticeship → mat & reformer)",
                ]
            }
            context.insert(ins)

            let lt1 = LessonType()
            lt1.ownerID = s.owner
            lt1.legacyId = s.id * 10 + 1
            lt1.name = "\(s.spec[0]) 1-on-1"
            lt1.details = "Private \(s.spec[0].lowercased()) session tailored to you."
            lt1.durationMinutes = 50
            lt1.capacity = 1
            lt1.price = s.from
            lt1.createdAt = day(-30); lt1.updatedAt = day(-30)
            context.insert(lt1)

            if s.spec.count > 1 {
                let lt2 = LessonType()
                lt2.ownerID = s.owner
                lt2.legacyId = s.id * 10 + 2
                lt2.name = "\(s.spec[1]) Group"
                lt2.details = "Small \(s.spec[1].lowercased()) group class."
                lt2.durationMinutes = 55
                lt2.capacity = 6
                lt2.price = max(80, s.from - 90)
                lt2.order = 1
                lt2.createdAt = day(-30); lt2.updatedAt = day(-30)
                context.insert(lt2)
            }
        }

        // Bookings for the signed-in student (studentID nil → `myBookings` treats them as mine).
        // Two completed (this week + last week → an active 2-week streak) and one upcoming.
        func booking(_ owner: String, _ instr: Int, _ type: String, _ dayOffset: Int,
                     _ time: String, _ status: BookingStatus, _ order: Int) -> Booking {
            let b = Booking()
            b.legacyId = 90_000 + order
            b.instructorId = instr
            b.instructorOwnerID = owner
            b.type = type
            b.date = FloweWeek.bookingDateString(for: day(dayOffset))
            b.time = time
            b.duration = "50 min"
            b.status = status
            // The signed-in student's ownerID (not nil): `myBookings` still counts these as the
            // student's own (studentID == currentUserID when launched as dev.student), AND — launched
            // as the INSTRUCTOR — a real studentID lets the student-correlated surfaces work: No-Show
            // Shield strikes/risk nudges, the Students list, and student avatars all key on it.
            b.studentID = Self.devStudentID
            // A STALE snapshot on purpose: this is the name frozen onto the booking at booking time
            // (a student who signed up without a name → "Member"). The student later set "Lina" on
            // their StudentProfile (seeded below). Instructor surfaces must resolve the LIVE name, not
            // this snapshot — the bug fixed 2026-08-05 in StudentsList + No-Show Shield.
            b.studentName = "Member"
            b.order = order
            // Stamp a deterministic record name so completed seed bookings are reviewable
            // (canReview requires remoteID != nil). pendingUpload stays false → treated as
            // already-synced, so the flush/upload paths never touch these local fixtures.
            b.remoteID = "\(Self.devSeedPrefix)booking.\(order)"
            return b
        }
        context.insert(booking("dev.seed.1", 9001, "Reformer 1-on-1", -2, "9:00 AM", .completed, 2))
        context.insert(booking("dev.seed.2", 9002, "Mat Group",       -9, "6:00 PM", .completed, 3))
        context.insert(booking("dev.seed.1", 9001, "Reformer 1-on-1",  3, "9:00 AM", .confirmed, 1))
        // Two more completed Maya sessions so the No-Show Shield "did they show?" queue has enough to
        // exercise every path at once: mark one attended, one no-show→collect, one no-show→waive. The
        // no-shows also give the student (dev.student) strikes → the upcoming confirmed session above
        // lights up "worth a nudge". (Only surfaced when signed in as the instructor.)
        context.insert(booking("dev.seed.1", 9001, "Reformer 1-on-1", -3, "10:00 AM", .completed, 4))
        context.insert(booking("dev.seed.1", 9001, "Reformer 1-on-1", -4, "11:00 AM", .completed, 5))

        // The signed-in student's PUBLIC profile, carrying their CURRENT name ("Lina") — set AFTER the
        // bookings above froze "Member" onto their snapshot. Instructor surfaces resolve this live via
        // `displayIdentity`, so it must override the stale snapshot. This is the fixture for the
        // Students-tab / No-Show-Shield name-sync bug (fixed 2026-08-05).
        let studentProfile = StudentProfile(ownerID: Self.devStudentID, name: "Lina", memberSince: day(-30))
        studentProfile.updatedAt = day(-1)
        context.insert(studentProfile)

        // A couple of reviews on Maya so her Reviews tab isn't empty.
        let reviewTexts = ["Maya completely fixed my posture — best Reformer teacher in TLV.",
                           "Calm, precise, and pushes you just enough."]
        for (i, txt) in reviewTexts.enumerated() {
            let r = Review()
            r.instructorID = "dev.seed.1"
            r.studentID = "dev.seed.reviewer.\(i)"
            r.studentName = ["Shira", "Amit"][i]
            r.rating = 5
            r.text = txt
            r.bookingID = "dev.seed.review.\(i)"
            r.createdAt = day(-(i + 1) * 7)
            context.insert(r)
        }

        // One community event (organized by Maya) so Community → Events + the request→accept flow can
        // be exercised. remoteID set so join/requestState resolve locally; createdAt=now spares it from
        // pruneEvents. Its public-DB write path still no-ops in the sim (no account) — this is a render/
        // logic fixture, not a live CloudKit round-trip.
        let event = CommunityEvent(legacyId: 95001, remoteID: "dev.seed.event.1")
        event.organizerID = "dev.seed.1"
        event.organizerName = "Maya Cohen"
        event.title = "Sunrise Reformer Flow"
        event.about = "A 60-minute energizing Reformer class to start your weekend. All levels welcome."
        event.location = "12 Dizengoff St, Tel Aviv-Yafo"
        event.startsAt = day(5)
        event.durationMinutes = 60
        event.capacity = 8
        event.price = 60
        event.attendees = 0
        event.createdAt = Date()
        event.updatedAt = Date()
        context.insert(event)

        // Flowe Pro career marketplace (Phase 3): a few opportunities posted by OTHER seed instructors,
        // so the signed-in instructor (Maya = dev.seed.1) sees them in her Opportunities feed (her own
        // posts are filtered out). Spans the kind spectrum + the eligibility gate. See [[FlowePro]].
        func opp(_ owner: String, _ name: String, _ kind: OpportunityKind, _ elig: OpportunityEligibility,
                 _ title: String, _ about: String, _ location: String, _ pay: String, _ commitment: String,
                 _ startsInDays: Int?, _ createdDaysAgo: Int, _ order: Int) {
            let o = Opportunity(posterID: owner, posterName: name, kind: kind, eligibility: elig,
                                title: title, about: about, location: location, payText: pay,
                                commitment: commitment, startsAt: startsInDays.map { day($0) },
                                createdAt: day(-createdDaysAgo), order: order)
            context.insert(o)
        }
        opp("dev.seed.2", "Noa Levi", .cover, .certifiedOnly,
            "Sub my Mat Group — this Thursday AM",
            "I'm out of town Thursday and need a certified instructor to cover my 8am Mat Group (6 students, all levels). Warm, welcoming studio.",
            "5 Rothschild Blvd, Tel Aviv-Yafo", "₪180 for the class", "One-off · Thu 8:00", 3, 1, 1)
        opp("dev.seed.3", "Dana Katz", .recurring, .certifiedOnly,
            "Weekly Reformer slot — Sunday mornings",
            "Looking for a reliable Reformer instructor to take a standing Sunday 9am duet slot at my Ramat Gan studio. Rehab-informed approach preferred.",
            "20 Bialik St, Ramat Gan", "60% split", "Weekly · Sun 9:00", nil, 2, 2)
        opp("dev.seed.4", "Yael Bar", .apprenticeship, .openToAll,
            "Barre apprenticeship — learn & assist",
            "Passionate about barre and want to teach one day? Assist my classes, learn the method, and grow into an instructor. Open to dedicated students — no certification needed.",
            "8 Ben Yehuda St, Tel Aviv-Yafo", "Unpaid trainee → paid once teaching", "Flexible · 2–3×/week", nil, 4, 3)

        save()   // persists locally + refresh()es the store's arrays
        print("✅ [DevSeed] Seeded \(specs.count) instructors + lesson types + 5 bookings + 2 reviews + 1 event + 3 opportunities — LOCAL only.")
    }

    /// Remove every previously-seeded `dev.seed.*` row so a relaunch reseeds cleanly.
    private func clearDevSeed() {
        let p = Self.devSeedPrefix
        for ins in (try? context.fetch(FetchDescriptor<Instructor>())) ?? [] where (ins.ownerID ?? "").hasPrefix(p) { context.delete(ins) }
        for lt in (try? context.fetch(FetchDescriptor<LessonType>())) ?? [] where (lt.ownerID ?? "").hasPrefix(p) { context.delete(lt) }
        for b in (try? context.fetch(FetchDescriptor<Booking>())) ?? [] where (b.instructorOwnerID ?? "").hasPrefix(p) { context.delete(b) }
        for r in (try? context.fetch(FetchDescriptor<Review>())) ?? [] where r.instructorID.hasPrefix(p) { context.delete(r) }
        for e in (try? context.fetch(FetchDescriptor<CommunityEvent>())) ?? [] where (e.remoteID ?? "").hasPrefix(p) { context.delete(e) }
        // The seeded student profile is keyed by the exact dev.student id (no `dev.seed.` prefix), so
        // clear it explicitly.
        for sp in (try? context.fetch(FetchDescriptor<StudentProfile>())) ?? [] where sp.ownerID == Self.devStudentID { context.delete(sp) }
        for o in (try? context.fetch(FetchDescriptor<Opportunity>())) ?? [] where o.posterID.hasPrefix(p) { context.delete(o) }
    }
}
#endif
