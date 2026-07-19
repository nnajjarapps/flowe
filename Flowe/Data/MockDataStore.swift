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

    /// The shipping app starts EMPTY — no mock data is seeded into the (CloudKit-synced) store.
    /// Sample data is only loaded for SwiftUI previews (`seed: true`, in-memory).
    init(_ context: ModelContext, seed: Bool = false) {
        self.context = context
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

    // MARK: - Instructor editing (instructor-side profile / availability)

    /// Persist edits made directly to a managed `Instructor` (bio, price, specialties, availability).
    func commit() { save() }

    /// The signed-in instructor (mock: the first catalog entry).
    var currentInstructor: Instructor? { instructors.first }

    // MARK: - Persistence

    private func save() {
        try? context.save()
        refresh()
    }
}
