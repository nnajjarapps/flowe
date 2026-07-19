import Foundation
import SwiftData

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
    var img: String = ""            // Unsplash photo id
    var available: [String] = []
    var bio: String?
    var order: Int = 0              // stable display order
    var ownerID: String?           // the signed-in instructor who owns/edits this listing

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
        self.bio = bio
        self.order = order
        self.ownerID = ownerID
    }

    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
}
