import Foundation
import SwiftData

/// Instructor feed visibility, driven by their IAP subscription tier.
enum InstructorVisibility: Int {
    case none = 0     // not subscribed → hidden from the student feed
    case visible = 1  // Flowe Visible → appears in the feed
    case boosted = 2  // Flowe Boost → appears higher / featured
}

/// Reference catalog entry. Stored in the local (non-synced) `Reference` configuration.
/// CloudKit-legal: class, every stored property defaulted, no `@Attribute(.unique)`.
@Model
final class Instructor {
    var legacyId: Int = 0          // stable id from seed JSON; used by `instructor(id:)` + booking links
    var name: String = ""
    var city: String = ""
    var rating: Double = 0
    var reviews: Int = 0
    var price: Int = 0
    var yearsExp: Int = 0
    var students: Int = 0
    var specialties: [String] = []
    var sessionTypes: [String] = []
    var cert: String = ""
    var img: String = ""            // Unsplash photo id — seeded reference listings only
    /// Uploaded profile photo, already downscaled by `ProfileImage.prepare`. Published to the public
    /// catalog as a `CKAsset`; `img` stays the fallback for seeded listings that have no upload.
    /// External storage keeps the blob out of the SQLite row.
    @Attribute(.externalStorage) var photo: Data?
    var available: [String] = []
    /// Bookable hours, one `"Mon|9:00 AM"` token per slot. A flat `[String]` rather than a nested
    /// type because this has to survive both SwiftData and a public-database `CKRecord`, neither of
    /// which stores a dictionary. Kept alongside `available` rather than replacing it: `available`
    /// is what the feed and the catalog already publish, and it stays derived from these on save.
    var hours: [String] = []
    var bio: String?
    var order: Int = 0              // stable display order
    var ownerID: String?           // the signed-in instructor who owns/edits this listing
    var visibilityRaw: Int = 0     // InstructorVisibility — driven by the owner's subscription
    var visibilityVerifiedAt: Date? // last time the owner's device confirmed the subscription

    var visibility: InstructorVisibility {
        get { InstructorVisibility(rawValue: visibilityRaw) ?? .none }
        set { visibilityRaw = newValue.rawValue }
    }

    init(
        legacyId: Int = 0,
        name: String = "",
        city: String = "",
        rating: Double = 0,
        reviews: Int = 0,
        price: Int = 0,
        yearsExp: Int = 0,
        students: Int = 0,
        specialties: [String] = [],
        sessionTypes: [String] = [],
        cert: String = "",
        img: String = "",
        available: [String] = [],
        hours: [String] = [],
        bio: String? = nil,
        order: Int = 0,
        ownerID: String? = nil
    ) {
        self.legacyId = legacyId
        self.name = name
        self.city = city
        self.rating = rating
        self.reviews = reviews
        self.price = price
        self.yearsExp = yearsExp
        self.students = students
        self.specialties = specialties
        self.sessionTypes = sessionTypes
        self.cert = cert
        self.img = img
        self.available = available
        self.hours = hours
        self.bio = bio
        self.order = order
        self.ownerID = ownerID
    }

    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }

    // MARK: - Bookable hours

    private static let separator = "|"

    /// Bookable times on a weekday, in chronological order.
    ///
    /// A day with no stored hours falls back to the standard slate. Listings created before
    /// per-day hours existed have `available` days but no `hours`, and returning nothing for them
    /// would silently make every one of them unbookable.
    func hours(on day: String) -> [String] {
        // `self.hours` throughout: a bare `hours` here is ambiguous with this method.
        let stored = self.hours.compactMap { token -> String? in
            let parts = token.components(separatedBy: Self.separator)
            guard parts.count == 2, parts[0] == day else { return nil }
            return parts[1]
        }
        guard stored.isEmpty else { return FloweConstants.times.filter(stored.contains) }
        return available.contains(day) ? FloweConstants.times : []
    }

    /// Replace one day's hours, leaving the other days untouched.
    func setHours(_ times: [String], on day: String) {
        let others = self.hours.filter { !$0.hasPrefix(day + Self.separator) }
        self.hours = others + times.map { day + Self.separator + $0 }
    }

    /// Whether this day can be booked at all.
    func isBookable(on day: String) -> Bool { !hours(on: day).isEmpty }

    /// Days with at least one bookable hour — what `available` is kept in sync with.
    var bookableDays: [String] {
        FloweConstants.weekdays.filter(isBookable(on:))
    }
}
