import Foundation

enum UserRole: String, Codable {
    case student
    case instructor
}

struct User: Identifiable, Codable {
    var id: UUID
    var fullName: String
    var email: String
    var role: UserRole
    var avatarImageName: String?
    /// Uploaded profile photo, downscaled by `ProfileImage.prepare`. A student's own personalization —
    /// shown on their profile header. Optional String-keyed Codable so it persists in the same
    /// UserDefaults record as the rest of the identity.
    var photo: Data?
    /// A short self-description the student can set. Shown on their profile header; empty by default.
    var bio: String?
    var memberSince: Date

    static let preview = User(
        id: UUID(),
        fullName: "Mia Tanaka",
        email: "mia@example.com",
        role: .student,
        memberSince: Date()
    )
}
