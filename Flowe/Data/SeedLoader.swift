import Foundation
import SwiftData

/// Seeds the SwiftData store from the bundled `MockData/*.json` on first launch.
/// Idempotent: each entity is only seeded when its table is empty (no `@Attribute(.unique)` exists
/// under CloudKit, so re-seeding would otherwise multiply rows).
enum SeedLoader {

    @MainActor
    static func seedIfNeeded(_ context: ModelContext) {
        seed(context, InstructorSeed.self, file: "instructors.json", isEmpty: Instructor.self) { seed, i in
            let instructor = Instructor(
                legacyId: seed.id, name: seed.name, city: seed.city, rating: seed.rating,
                reviews: seed.reviews, price: seed.price, yearsExp: seed.yearsExp, students: seed.students,
                specialties: seed.specialties, sessionTypes: seed.sessionTypes, cert: seed.cert,
                img: seed.img, available: seed.available, bio: seed.bio, order: i
            )
            // Sample data (previews only): first is Boosted/featured, the rest Visible.
            instructor.visibility = i == 0 ? .boosted : .visible
            instructor.visibilityVerifiedAt = Date()
            // Every real listing is keyed by its owner (recordName == ownerID), so seeded ones need
            // one too — without it they can't be booked or messaged.
            instructor.ownerID = "seed-instructor-\(seed.id)"
            return instructor
        }

        seed(context, PostSeed.self, file: "posts.json", isEmpty: FeedPost.self) { seed, i in
            FeedPost(
                legacyId: seed.id, type: PostType(rawValue: seed.type) ?? .tip, user: seed.user,
                userImg: seed.userImg, instructor: seed.instructor, instImg: seed.instImg,
                time: seed.time, rating: seed.rating, text: seed.text, likes: seed.likes,
                comments: seed.comments, saved: seed.saved, liked: seed.liked, order: i
            )
        }

        seed(context, BookingSeed.self, file: "bookings.json", isEmpty: Booking.self) { seed, i in
            Booking(
                legacyId: seed.id, instructorId: seed.instructorId, date: seed.date, time: seed.time,
                type: seed.type, duration: seed.duration,
                status: BookingStatus(rawValue: seed.status) ?? .pending, order: i,
                // A real booking carries the shared-store identity that anchors a review to a
                // session that actually happened; seeded ones need the same, or a completed sample
                // booking can't be reviewed. Mirrors the seeded listings' `ownerID` above.
                remoteID: "seed-booking-\(seed.id)",
                instructorOwnerID: "seed-instructor-\(seed.instructorId)"
            )
        }

        seedInstructorWorkspace(context)

        try? context.save()
    }

    /// Sample data for the *signed-in* instructor (owner `local-user`, the preview/test identity):
    /// their own listing plus incoming bookings and reviews, so the dashboard, analytics, earnings
    /// and reviews tabs render populated instead of empty. Runs only under `seed: true`, which is
    /// previews and UI tests — the shipping app never seeds.
    ///
    /// Every screen still derives its numbers from these rows; nothing here is a display constant.
    @MainActor
    private static func seedInstructorWorkspace(_ context: ModelContext) {
        let owner = FloweConstants.localOwnerID
        let existing = (try? context.fetch(FetchDescriptor<Instructor>())) ?? []
        guard !existing.contains(where: { $0.ownerID == owner }) else { return }

        // The instructor's own listing — priced, so earnings are non-zero. Hidden from the student
        // feed (visibility .none) so seeded students don't see a listing named after themselves.
        let meId = (existing.map(\.legacyId).max() ?? 0) + 1
        let me = Instructor(
            legacyId: meId, name: "Taylor Brooks", city: "Lisbon",
            price: 70, yearsExp: 6, specialties: ["Reformer", "Mat"],
            sessionTypes: ["Private", "Duet"], cert: "BASI Comprehensive",
            available: ["Mon", "Wed", "Fri"], bio: "Reformer-focused sessions for every level.",
            order: meId, ownerID: owner
        )
        context.insert(me)

        // Incoming bookings addressed to this instructor. Invisible to a seeded *student* — their
        // `myBookings` only matches their own studentID — and the source of every analytics number.
        struct Incoming { let student: (id: String, name: String); let type, status: String }
        let mia = (id: "seed-student-mia", name: "Mia Tanaka")
        let feed: [Incoming] = [
            Incoming(student: mia, type: "Private", status: "completed"),
            Incoming(student: mia, type: "Reformer", status: "completed"),   // repeat student
            Incoming(student: ("seed-student-jordan", "Jordan Lee"), type: "Duet", status: "completed"),
            Incoming(student: ("seed-student-sara", "Sara Kim"), type: "Private", status: "confirmed"),
            Incoming(student: ("seed-student-alex", "Alex Rivera"), type: "Private", status: "pending"),
        ]
        for (i, b) in feed.enumerated() {
            context.insert(Booking(
                legacyId: 500 + i, instructorId: meId, date: "Thu, Jul 10", time: "9:00 AM",
                type: b.type, duration: "55 min",
                status: BookingStatus(rawValue: b.status) ?? .completed, order: i,
                remoteID: "seed-incoming-\(i)", instructorOwnerID: owner,
                studentID: b.student.id, studentName: b.student.name
            ))
        }

        // Reviews on two of the completed sessions, so the rating is derived, not seeded onto the listing.
        let seededReviews: [(booking: Int, student: (id: String, name: String), rating: Int, text: String)] = [
            (0, mia, 5, "Taylor's cueing is so clear — best Reformer session I've had."),
            (2, ("seed-student-jordan", "Jordan Lee"), 4, "Great duet class, really attentive."),
        ]
        for r in seededReviews {
            context.insert(Review(
                remoteID: "seed-review-\(r.booking)", bookingID: "seed-incoming-\(r.booking)",
                instructorID: owner, studentID: r.student.id, studentName: r.student.name,
                rating: r.rating, text: r.text,
                createdAt: Date(timeIntervalSinceNow: -Double(r.booking + 1) * 86_400)
            ))
        }
    }

    /// Insert seed rows for `Model` only if none exist yet.
    @MainActor
    private static func seed<Seed: Decodable, Model: PersistentModel>(
        _ context: ModelContext,
        _ seedType: Seed.Type,
        file: String,
        isEmpty modelType: Model.Type,
        make: (Seed, Int) -> Model
    ) {
        let count = (try? context.fetchCount(FetchDescriptor<Model>())) ?? 0
        guard count == 0 else { return }
        for (i, seed) in decode([Seed].self, from: file).enumerated() {
            context.insert(make(seed, i))
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from file: String) -> T {
        guard let url = Bundle.main.url(forResource: file, withExtension: nil),
              let data = try? Data(contentsOf: url) else {
            fatalError("Missing bundled seed: \(file)")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { fatalError("Failed to decode \(file): \(error)") }
    }

    // MARK: - Seed DTOs (match the JSON shape; kept separate from the @Model classes)

    private struct InstructorSeed: Decodable {
        let id: Int; let name, city: String; let rating: Double
        let reviews, price, yearsExp, students: Int
        let specialties, sessionTypes: [String]; let cert, img: String
        let available: [String]; let bio: String?
    }

    private struct PostSeed: Decodable {
        let id: Int; let type, user, userImg: String
        let instructor, instImg: String?; let time: String; let rating: Int?
        let text: String; let likes, comments: Int; let saved, liked: Bool
    }

    private struct BookingSeed: Decodable {
        let id, instructorId: Int
        let date, time, type, duration, status: String
    }
}
