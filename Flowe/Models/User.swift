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
    var memberSince: Date

    static let preview = User(
        id: UUID(),
        fullName: "Mia Tanaka",
        email: "mia@example.com",
        role: .student,
        memberSince: Date()
    )
}
