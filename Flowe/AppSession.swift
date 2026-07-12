import SwiftUI
import Observation

enum AuthState {
    case unauthenticated
    case student
    case instructor
}

@Observable
final class AppSession {
    var authState: AuthState = .unauthenticated
    var currentUser: User?

    private let roleKey = "flowe.userRole"
    private let loggedInKey = "flowe.isLoggedIn"

    init() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: loggedInKey),
           let rawRole = defaults.string(forKey: roleKey),
           let role = UserRole(rawValue: rawRole) {
            authState = role == .student ? .student : .instructor
        }
    }

    func signUp(name: String, email: String, role: UserRole) {
        currentUser = User(
            id: UUID(),
            fullName: name,
            email: email,
            role: role,
            memberSince: Date()
        )
        persist(role: role)
    }

    func login(email: String, role: UserRole) {
        currentUser = User(
            id: UUID(),
            fullName: "Demo User",
            email: email,
            role: role,
            memberSince: Date()
        )
        persist(role: role)
    }

    func logout() {
        currentUser = nil
        authState = .unauthenticated
        UserDefaults.standard.removeObject(forKey: roleKey)
        UserDefaults.standard.set(false, forKey: loggedInKey)
    }

    private func persist(role: UserRole) {
        UserDefaults.standard.set(role.rawValue, forKey: roleKey)
        UserDefaults.standard.set(true, forKey: loggedInKey)
        withAnimation(.spring(duration: 0.4, bounce: 0.1)) {
            authState = role == .student ? .student : .instructor
        }
    }
}
