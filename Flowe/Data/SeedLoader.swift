import Foundation
import SwiftData

/// Seeds the SwiftData store from the bundled `MockData/*.json` on first launch.
/// Idempotent: each entity is only seeded when its table is empty (no `@Attribute(.unique)` exists
/// under CloudKit, so re-seeding would otherwise multiply rows).
enum SeedLoader {

    @MainActor
    static func seedIfNeeded(_ context: ModelContext) {
        seed(context, InstructorSeed.self, file: "instructors.json", isEmpty: Instructor.self) { seed, i in
            Instructor(
                legacyId: seed.id, name: seed.name, city: seed.city, rating: seed.rating,
                reviews: seed.reviews, price: seed.price, yearsExp: seed.yearsExp, students: seed.students,
                specialties: seed.specialties, sessionTypes: seed.sessionTypes, cert: seed.cert,
                img: seed.img, available: seed.available, bio: seed.bio, order: i
            )
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
                status: BookingStatus(rawValue: seed.status) ?? .pending, order: i
            )
        }

        try? context.save()
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
