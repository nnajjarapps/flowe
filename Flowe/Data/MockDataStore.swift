import SwiftUI
import SwiftData
import Observation

/// Repository facade over SwiftData. Keeps the same public API the screens already use, so the
/// storage swap (JSON → `ModelContext`, later CloudKit-synced) doesn't ripple into the views.
///
/// Cached arrays are re-fetched via `refresh()` after each mutation so `@Observable` re-renders.
@MainActor
@Observable
final class MockDataStore {
    private let context: ModelContext

    private(set) var instructors: [Instructor] = []
    private(set) var posts: [FeedPost] = []
    private(set) var postComments: [PostComment] = []
    private(set) var bookings: [Booking] = []
    private(set) var messages: [Message] = []
    private(set) var blocked: [BlockedUser] = []
    private(set) var reviews: [Review] = []
    private(set) var events: [CommunityEvent] = []

    private let catalog = CatalogService()
    private let bookingService = BookingService()
    private let messagingService = MessagingService()
    private let deletionService = AccountDeletionService()
    private let reportService = ReportService()
    private let reviewService = ReviewService()
    private let communityService = CommunityService()
    private let eventService = EventService()
    /// Suppresses public-catalog network calls (previews + UI tests).
    private let isPreview: Bool

    /// The shipping app starts EMPTY — no mock data is seeded into the (CloudKit-synced) store.
    /// Sample data is only loaded for SwiftUI previews and UI tests (`seed: true`).
    /// - Parameters:
    ///   - reset: wipe all stored models first (UI-test isolation).
    ///   - offline: skip public-catalog sync/publish (UI tests run deterministically offline).
    init(_ context: ModelContext, seed: Bool = false, reset: Bool = false, offline: Bool = false) {
        self.context = context
        self.isPreview = seed || offline
        if reset { Self.deleteAll(context) }
        if seed { SeedLoader.seedIfNeeded(context) }
        refresh()
    }

    /// Removes every stored model — used to give each UI test a clean slate.
    private static func deleteAll(_ context: ModelContext) {
        try? context.delete(model: Instructor.self)
        try? context.delete(model: FeedPost.self)
        try? context.delete(model: PostComment.self)
        try? context.delete(model: Booking.self)
        try? context.delete(model: Message.self)
        try? context.delete(model: BlockedUser.self)
        try? context.delete(model: Review.self)
        try? context.delete(model: CommunityEvent.self)
        try? context.save()
    }

    /// Fresh in-memory store seeded with sample data — for SwiftUI previews only.
    static var preview: MockDataStore {
        MockDataStore(FloweModelContainer.make(inMemory: true).mainContext, seed: true)
    }

    func refresh() {
        instructors = fetch(sortBy: \Instructor.order)
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
        reviews     = (try? context.fetch(
            FetchDescriptor<Review>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        )) ?? []
        // Earliest-starting first: the events list is a chronological schedule, and the store never
        // relies on a local `order` for shared records.
        events      = (try? context.fetch(
            FetchDescriptor<CommunityEvent>(sortBy: [SortDescriptor(\.startsAt, order: .forward)])
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

    private static func isEligible(_ ins: Instructor) -> Bool {
        guard ins.visibility != .none, ins.price > 0, !ins.name.isEmpty else { return false }
        // 7-day TTL backstop: a lapsed subscription on a device that never reopened stays hidden.
        if let verified = ins.visibilityVerifiedAt {
            return Date().timeIntervalSince(verified) < 7 * 24 * 3600
        }
        return true
    }

    /// Stamp the signed-in instructor's listing with their subscription-derived visibility,
    /// and push the change to the public catalog so students see (or stop seeing) them.
    func applyVisibility(_ level: InstructorVisibility, for ownerID: String) {
        guard let listing = instructors.first(where: { $0.ownerID == ownerID }) else { return }
        listing.visibility = level
        listing.visibilityVerifiedAt = Date()
        save()
        if !isPreview { Task { await catalog.publish(listing) } }
    }

    // MARK: - Bookings

    var upcomingBookings: [Booking] { myBookings.filter { $0.status.isUpcoming } }
    var pastBookings: [Booking] { myBookings.filter { !$0.status.isUpcoming } }

    var upcomingCount: Int { upcomingBookings.count }
    var completedCount: Int { myBookings.filter { $0.status == .completed }.count }

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

    /// Earnings priced at the instructor's rate. Payment is arranged directly with the student, so
    /// `collected` is what completed sessions were worth and `projected` what accepted-but-not-yet-
    /// delivered sessions will be worth — a forecast, not an in-app balance.
    var instructorEarnings: (collected: Int, projected: Int) {
        let price = currentInstructor?.price ?? 0
        let completed = incomingBookings.filter { $0.status == .completed }.count
        let confirmed = incomingBookings.filter { $0.status == .confirmed }.count
        return (completed * price, confirmed * price)
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

    /// Creates a booking from a completed BookingSheet flow and publishes it to the shared
    /// database so the instructor actually receives it.
    ///
    /// The booking starts `pending`: it is a *request* until the instructor accepts. Payment is
    /// arranged directly with the instructor — this release takes no money in-app.
    func addBooking(instructor: Instructor, day: String, time: String, type: String) {
        let nextId = (bookings.map(\.legacyId).max() ?? 0) + 1
        let topOrder = (bookings.map(\.order).min() ?? 0) - 1   // smaller order sorts first
        let booking = Booking(
            legacyId: nextId,
            instructorId: instructor.legacyId,
            date: Self.formatDay(day),
            time: time,
            type: type,
            duration: type == "Private" ? "55 min" : "50 min",
            status: .pending,
            ownerID: currentUserID,
            order: topOrder,
            instructorOwnerID: instructor.ownerID,
            studentID: currentUserID,
            studentName: currentUserName
        )
        // Marked pending up front: if the app is killed before the upload finishes, the next
        // sync retries it rather than losing the booking.
        booking.pendingUpload = true
        context.insert(booking)
        save()

        guard !isPreview,
              let instructorID = instructor.ownerID,
              let studentID = currentUserID else { return }
        Task { await upload(booking, instructorID: instructorID, studentID: studentID) }
    }

    /// Push a locally-created booking to the shared database, flagging it for retry if it fails.
    private func upload(_ booking: Booking, instructorID: String, studentID: String) async {
        let remoteID = await bookingService.create(
            instructorID: instructorID,
            studentID: studentID,
            studentName: booking.studentName,
            date: booking.date,
            time: booking.time,
            type: booking.type,
            duration: booking.duration
        )
        booking.remoteID = remoteID
        booking.pendingUpload = remoteID == nil
        save()
    }

    /// Instructor accepts or declines a request; the student sees the result on their next sync.
    func respond(to booking: Booking, confirmed: Bool) {
        booking.status = confirmed ? .confirmed : .cancelled
        booking.pendingDecision = true
        save()
        guard !isPreview, let remoteID = booking.remoteID else { return }
        Task {
            let delivered = await bookingService.respond(bookingID: remoteID, confirmed: confirmed)
            booking.pendingDecision = !delivered
            save()
        }
    }

    /// Student cancels their own booking.
    func cancel(_ booking: Booking) {
        booking.status = .cancelled
        booking.pendingDecision = true
        save()
        guard !isPreview, let remoteID = booking.remoteID else { return }
        Task {
            let delivered = await bookingService.cancel(bookingID: remoteID)
            booking.pendingDecision = !delivered
            save()
        }
    }

    /// Re-send anything that never reached the server — a booking made offline, or a decision
    /// taken while the network was down.
    private func flushPendingWrites() async {
        for booking in bookings where booking.pendingUpload && booking.remoteID == nil {
            guard let instructorID = booking.instructorOwnerID,
                  let studentID = booking.studentID else { continue }
            await upload(booking, instructorID: instructorID, studentID: studentID)
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
    func syncBookings(asInstructor: Bool) async {
        guard !isPreview, let currentUserID else { return }
        if asInstructor { await flushPendingListing() }
        await flushPendingWrites()
        let remote = asInstructor
            ? await bookingService.fetchForInstructor(ownerID: currentUserID)
            : await bookingService.fetchForStudent(ownerID: currentUserID)
        guard !remote.isEmpty else { return }

        let decisions = await bookingService.fetchDecisions(bookingIDs: remote.map(\.id))
        var nextId = bookings.map(\.legacyId).max() ?? 0
        var nextOrder = bookings.map(\.order).max() ?? 0

        for entry in remote {
            let status = Self.status(for: entry, decision: decisions[entry.id])
            if let cached = bookings.first(where: { $0.remoteID == entry.id }) {
                // Don't undo a local decision whose write hasn't landed yet (offline accept, or a
                // decision saved since this fetch started) — that would flip the row back to
                // Pending and re-prompt the instructor for something they already answered.
                let losesLocalDecision = status == .pending && cached.status != .pending
                if !losesLocalDecision { cached.status = status }
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
        }
        save()
    }

    /// A booking is pending until the instructor responds; a student cancellation always wins; and a
    /// confirmed session whose time has passed has been delivered → `.completed`.
    ///
    /// The completion step lives here, in the one resolver every sync runs, so the merge writes
    /// `.completed` directly and a later sync can't revert it (the alternative — a local-only
    /// transition — would be clobbered the next time this returned `.confirmed`). Nothing else in
    /// production ever produced `.completed`, which left the Past tab, instructor earnings/sessions
    /// and the whole review flow permanently unreachable.
    private static func status(for booking: RemoteBooking, decision: RemoteDecision?,
                               now: Date = Date()) -> BookingStatus {
        if booking.cancelled { return .cancelled }
        guard let decision else { return .pending }
        guard decision.confirmed else { return .cancelled }
        return Booking.isOver(date: booking.date, time: booking.time, duration: booking.duration, now: now)
            ? .completed : .confirmed
    }

    /// "Thu Jul 10" → "Thu, Jul 10" to match the booking-card format.
    private static func formatDay(_ day: String) -> String {
        let parts = day.split(separator: " ")
        guard let first = parts.first else { return day }
        let rest = parts.dropFirst().joined(separator: " ")
        return rest.isEmpty ? String(first) : "\(first), \(rest)"
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
            // Instructors have a listing photo; students don't.
            if let listing = instructors.first(where: { $0.ownerID == counterpart.id }) {
                counterpart.avatarID = listing.img
            }
            return ConversationSummary(
                counterpart: counterpart,
                lastMessage: latest.text,
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
        let remoteID = await messagingService.send(
            conversationID: message.conversationID,
            senderID: message.senderID,
            senderName: message.senderName,
            recipientID: message.recipientID,
            recipientName: message.recipientName,
            text: message.text,
            sentAt: message.sentAt
        )
        message.remoteID = remoteID
        message.pendingUpload = remoteID == nil
        save()
    }

    /// Mark everything received in a thread as read (called when the thread is opened).
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
    }

    /// Pull all messages involving this user and cache anything new.
    func syncMessages() async {
        guard !isPreview, let me = currentUserID else { return }
        for message in messages where message.pendingUpload && message.remoteID == nil {
            await upload(message)
        }
        let remote = await messagingService.fetchMessages(for: me)
        merge(remote, me: me)
    }

    /// Refresh a single thread — cheaper than a full sync while a conversation is open.
    func syncThread(with counterpartID: String) async {
        guard !isPreview, let me = currentUserID else { return }
        let remote = await messagingService.fetchThread(
            conversationID: Message.conversationID(me, counterpartID)
        )
        merge(remote, me: me)
    }

    private func merge(_ remote: [RemoteMessage], me: String) {
        guard !remote.isEmpty else { return }
        let known = Set(messages.compactMap(\.remoteID))
        var inserted = false
        for entry in remote where !known.contains(entry.id) {
            context.insert(Message(
                remoteID: entry.id,
                conversationID: entry.conversationID,
                senderID: entry.senderID,
                senderName: entry.senderName,
                recipientID: entry.recipientID,
                recipientName: entry.recipientName,
                text: entry.text,
                sentAt: entry.sentAt,
                // Anything I sent is implicitly read; anything received starts unread.
                isRead: entry.senderID == me
            ))
            inserted = true
        }
        if inserted { save() }
    }

    /// People this user can start a conversation with. A student writes to instructors they can
    /// see; an instructor writes to students who have booked them.
    func addressBook(asInstructor: Bool) -> [Counterpart] {
        if asInstructor {
            let students = incomingBookings.compactMap { booking -> Counterpart? in
                guard let id = booking.studentID, !isBlocked(id) else { return nil }
                return Counterpart(id: id, name: booking.studentName)
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
            return Counterpart(id: id, name: listing.name, avatarID: listing.img)
        }
        return dedupe(listings)
    }

    private func dedupe(_ people: [Counterpart]) -> [Counterpart] {
        var seen = Set<String>()
        return people.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Reviews

    /// Reviews written about an instructor, newest first. Blocked students are filtered out for the
    /// same reason their messages are.
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
        let remoteID = await reviewService.submit(
            bookingID: review.bookingID,
            instructorID: review.instructorID,
            studentID: review.studentID,
            studentName: review.studentName,
            rating: review.rating,
            text: review.text,
            createdAt: review.createdAt
        )
        review.remoteID = remoteID
        review.pendingUpload = remoteID == nil
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
            if let existing = reviews.first(where: { $0.bookingID == entry.bookingID }) {
                // The remote copy wins — it is the one other people see.
                guard existing.remoteID != entry.id
                        || existing.rating != entry.rating
                        || existing.text != entry.text else { continue }
                existing.remoteID = entry.id
                existing.rating = entry.rating
                existing.text = entry.text
                existing.studentName = entry.studentName
                existing.createdAt = entry.createdAt
                existing.pendingUpload = false
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
    }

    func unblock(_ ownerID: String) {
        for entry in blocked where entry.blockedID == ownerID { context.delete(entry) }
        save()
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
        if !isPreview, let me = currentUserID {
            guard await deletionService.deleteAllRecords(ownerID: me) else { return false }
        }
        Self.deleteAll(context)
        currentUserID = nil
        currentUserName = ""
        refresh()
        return true
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

    /// The author's uploaded profile photo, if they have a listing.
    ///
    /// Instructors have one; a student has no listing and so no avatar, and falls back to the
    /// gradient placeholder. This is the only source — the post itself carries no author image.
    func authorPhoto(for post: FeedPost) -> Data? {
        guard let authorID = post.ownerID else { return nil }
        return instructors.first { $0.ownerID == authorID }?.photo
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
        await flushPendingCommunityWrites()
        mergePosts(await communityService.fetchRecentPosts())
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
        var nextId = posts.map(\.legacyId).max() ?? 0

        for entry in remote where !known.contains(entry.id) {
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
        let settled = Date(timeIntervalSinceNow: -300)
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
            for post in posts {
                guard let remoteID = post.remoteID else { continue }
                let rows = byPost[remoteID] ?? []
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

    /// The events a student should see: blocked organizers gone, deletions already hidden, and a
    /// cancelled event hidden from everyone *except* someone who joined it — they keep seeing it wear
    /// a "Cancelled" badge, which is the only way they learn of the cancellation (there is no push).
    var visibleEvents: [CommunityEvent] {
        events.filter { !isBlocked($0.organizerID) && !$0.pendingDelete && (!$0.cancelled || $0.joined) }
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

        // Optimistic local move so the tap feels answered.
        event.joined = true
        // nil stays nil — bumping to 1 would assert a total on evidence never gathered.
        if let c = event.attendees { event.attendees = c + 1 }
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
        event.joined = false
        if let c = event.attendees { event.attendees = max(0, c - 1) }
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
        await flushPendingEventWrites()

        // The 6-hour grace keeps a class that started an hour ago from vanishing while people are in
        // it. Only this (whole-window) merge prunes — see `mergeEvents(_:prune:)`.
        mergeEvents(await eventService.fetchUpcoming(since: Date(timeIntervalSinceNow: -6 * 3600)))
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
        // nil means the query failed — NOT "nobody joined". Conflating them would zero every count
        // offline and could withdraw a genuine registration on no evidence.
        guard let rows = await eventService.fetchRegistrations(eventIDs: eventIDs) else { return }
        let byEvent = Dictionary(grouping: rows, by: \.eventID)

        var toWithdraw: [CommunityEvent] = []
        var lost: [CommunityEvent] = []

        for event in subjects {
            guard let remoteID = event.remoteID else { continue }
            let mineRows = byEvent[remoteID] ?? []
            let admitted = EventService.admitted(mineRows, capacity: event.capacity)
            let mine = admitted.contains(me)
            if event.pendingJoin {
                // An undelivered join/leave: keep the user's own desired state and keep the count
                // consistent with it, the same correction `refreshEngagement` makes for a pending like.
                event.attendees = mineRows.count
                    + (event.joined && !mine ? 1 : 0)
                    - (!event.joined && mine ? 1 : 0)
            } else {
                let wasJoined = event.joined
                // The TRUE count, not the admitted count — `spotsLeft` clamps at 0 anyway, and the
                // organizer must see the overflow.
                event.attendees = mineRows.count
                event.joined = mine
                if wasJoined && !mine { lost.append(event) }                        // I was in, now I'm not
                if !mine, mineRows.contains(where: { $0.studentID == me }) {         // holding a losing record
                    toWithdraw.append(event)
                }
            }
        }

        // Withdraw my own losing registration (the only record I may delete), then surface the loss.
        for event in toWithdraw {
            guard let remoteID = event.remoteID else { continue }
            _ = await eventService.setRegistration(
                false, eventID: remoteID, studentID: me, studentName: currentUserName,
                eventTitle: event.title, organizerID: event.organizerID ?? ""
            )
        }
        for event in lost { lastJoinOutcome = .missedOut(title: event.title) }
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
        // Marked before the attempt so a crash or a kill mid-publish still retries.
        me.pendingPublish = true
        save()
        guard !isPreview else { return }
        Task {
            if await catalog.publish(me) {
                me.pendingPublish = false
                save()
            }
        }
    }

    /// Re-publish a listing whose last save never landed. Called from the instructor's own syncs,
    /// because `syncCatalog` is student-side only and would never reach this.
    func flushPendingListing() async {
        guard !isPreview, let me = currentInstructor, me.pendingPublish else { return }
        if await catalog.publish(me) {
            me.pendingPublish = false
            save()
        }
    }

    // MARK: - Public catalog sync (cross-device instructor discovery)

    /// Fetch visible listings from the public catalog and cache them into the local store the feed reads.
    func syncCatalog() async {
        guard !isPreview else { return }
        let listings = await catalog.fetchVisibleListings()
        var nextId = instructors.map(\.legacyId).max() ?? 0
        var nextOrder = instructors.map(\.order).max() ?? 0
        let owners = Set(listings.map(\.ownerID))

        for listing in listings {
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
            if !owners.contains(ins.ownerID!) { ins.visibilityRaw = 0 }
        }
        save()
    }

    private func apply(_ l: CatalogListing, to ins: Instructor) {
        ins.name = l.name; ins.city = l.city; ins.bio = l.bio; ins.price = l.price
        ins.yearsExp = l.yearsExp
        ins.specialties = l.specialties; ins.sessionTypes = l.sessionTypes
        ins.available = l.available; ins.hours = l.hours
        ins.rating = l.rating; ins.reviews = l.reviews; ins.img = l.img; ins.cert = l.cert
        ins.paymentMethods = l.paymentMethods
        ins.visibilityRaw = l.visibility
        // Assigned unconditionally, nil included: an instructor who removed their teaching area must
        // stop being placed on the map on everyone else's device. Re-snapped on the way in by
        // `setCoarseLocation`, so a row published at finer precision by any other client still only
        // resolves to a ~1 km cell here.
        ins.setCoarseLocation(CoarseLocation(snappingLatitude: l.latitude, longitude: l.longitude))
        ins.visibilityVerifiedAt = Date()
        // Only overwrite a cached image when the server actually has one. A nil here usually means
        // "this listing has no upload", but for my own listing it can also mean my photo hasn't
        // reached the server yet — and clobbering it would lose the picture the user just chose.
        if let photo = l.photo { ins.photo = photo }
        // Assigned unconditionally, unlike `photo` above: the nil-skip there protects the owner's
        // own not-yet-uploaded image, but for someone else's cached listing a nil means the
        // instructor removed the certificate — and a withdrawn credential must stop being shown.
        ins.certPhoto = l.certPhoto
    }

    /// The signed-in instructor's own listing (resolved by owner), if it exists.
    var currentInstructor: Instructor? {
        guard let currentUserID else { return nil }
        return instructors.first { $0.ownerID == currentUserID }
    }

    /// Ensures the signed-in instructor has an (empty, editable) listing. Called on instructor login.
    @discardableResult
    func ensureInstructorProfile(ownerID: String, name: String, city: String = "") -> Instructor {
        if let existing = instructors.first(where: { $0.ownerID == ownerID }) { return existing }
        let nextId = (instructors.map(\.legacyId).max() ?? 0) + 1
        let nextOrder = (instructors.map(\.order).max() ?? 0) + 1
        let instructor = Instructor(
            legacyId: nextId, name: name, city: city, sessionTypes: ["Private"],
            order: nextOrder, ownerID: ownerID
        )
        context.insert(instructor)
        save()
        return instructor
    }

    // MARK: - Persistence

    private func save() {
        try? context.save()
        refresh()
    }
}
