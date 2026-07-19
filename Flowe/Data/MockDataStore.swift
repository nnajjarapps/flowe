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

    private let catalog = CatalogService()
    private let isPreview: Bool

    /// The shipping app starts EMPTY — no mock data is seeded into the (CloudKit-synced) store.
    /// Sample data is only loaded for SwiftUI previews (`seed: true`, in-memory).
    init(_ context: ModelContext, seed: Bool = false) {
        self.context = context
        self.isPreview = seed
        if seed { SeedLoader.seedIfNeeded(context) }
        refresh()
    }

    /// Fresh in-memory store seeded with sample data — for SwiftUI previews only.
    static var preview: MockDataStore {
        MockDataStore(FloweModelContainer.make(inMemory: true).mainContext, seed: true)
    }

    func refresh() {
        instructors = fetch(sortBy: \Instructor.order)
        posts       = fetch(sortBy: \FeedPost.order)
        bookings    = fetch(sortBy: \Booking.order)
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
        instructors.filter(Self.isEligible).sorted {
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

    var upcomingBookings: [Booking] { bookings.filter { $0.status.isUpcoming } }
    var pastBookings: [Booking] { bookings.filter { !$0.status.isUpcoming } }

    var upcomingCount: Int { upcomingBookings.count }
    var completedCount: Int { bookings.filter { $0.status == .completed }.count }

    /// Total practiced hours from completed sessions' durations (e.g. "55 min").
    var hoursDisplay: String {
        let minutes = bookings
            .filter { $0.status == .completed }
            .reduce(0) { $0 + (Int($1.duration.filter(\.isNumber)) ?? 0) }
        let hours = Double(minutes) / 60
        return hours == hours.rounded() ? String(format: "%.0f", hours) : String(format: "%.1f", hours)
    }

    /// Creates a confirmed booking from a completed BookingSheet flow.
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
            status: .confirmed,
            order: topOrder
        )
        context.insert(booking)
        save()
    }

    /// "Thu Jul 10" → "Thu, Jul 10" to match the booking-card format.
    private static func formatDay(_ day: String) -> String {
        let parts = day.split(separator: " ")
        guard let first = parts.first else { return day }
        let rest = parts.dropFirst().joined(separator: " ")
        return rest.isEmpty ? String(first) : "\(first), \(rest)"
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
