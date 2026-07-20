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
    private(set) var bookings: [Booking] = []
    private(set) var messages: [Message] = []
    private(set) var blocked: [BlockedUser] = []
    private(set) var reviews: [Review] = []

    private let catalog = CatalogService()
    private let bookingService = BookingService()
    private let messagingService = MessagingService()
    private let deletionService = AccountDeletionService()
    private let reportService = ReportService()
    private let reviewService = ReviewService()
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
        try? context.delete(model: Booking.self)
        try? context.delete(model: Message.self)
        try? context.delete(model: BlockedUser.self)
        try? context.delete(model: Review.self)
        try? context.save()
    }

    /// Fresh in-memory store seeded with sample data — for SwiftUI previews only.
    static var preview: MockDataStore {
        MockDataStore(FloweModelContainer.make(inMemory: true).mainContext, seed: true)
    }

    func refresh() {
        instructors = fetch(sortBy: \Instructor.order)
        posts       = fetch(sortBy: \FeedPost.order)
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

    /// A booking is pending until the instructor responds; a student cancellation always wins.
    private static func status(for booking: RemoteBooking, decision: RemoteDecision?) -> BookingStatus {
        if booking.cancelled { return .cancelled }
        guard let decision else { return .pending }
        return decision.confirmed ? .confirmed : .cancelled
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

    // MARK: - Like / save toggles

    func toggleLike(_ post: FeedPost) {
        post.liked.toggle()
        post.likes += post.liked ? 1 : -1
        save()
    }

    func toggleSave(_ post: FeedPost) {
        post.saved.toggle()
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
        guard !isPreview, let me = currentInstructor else { return }
        Task { await catalog.publish(me) }
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
        ins.specialties = l.specialties; ins.sessionTypes = l.sessionTypes; ins.available = l.available
        ins.rating = l.rating; ins.reviews = l.reviews; ins.img = l.img; ins.cert = l.cert
        ins.visibilityRaw = l.visibility
        ins.visibilityVerifiedAt = Date()
        // Only overwrite the cached photo when the server actually has one. A nil here usually means
        // "this listing has no upload", but for my own listing it can also mean my photo hasn't
        // reached the server yet — and clobbering it would lose the picture the user just chose.
        if let photo = l.photo { ins.photo = photo }
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
