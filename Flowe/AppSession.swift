import SwiftUI
import Observation
import AuthenticationServices

enum AuthState {
    case unauthenticated
    case student
    case instructor
}

@Observable
final class AppSession {
    var authState: AuthState = .unauthenticated
    var currentUser: User?

    /// Stable Apple user identifier (the only id Apple returns on every sign-in). Kept in the
    /// Keychain so it survives reinstalls; becomes the owner id for the user's CloudKit records.
    private(set) var appleUserID: String?

    private let roleKey = "flowe.userRole"
    private let loggedInKey = "flowe.isLoggedIn"
    private let appleUserKey = "flowe.appleUserID"
    private let userKey = "flowe.user"

    /// Stable id for the signed-in user — used to own their SwiftData records.
    var ownerID: String { appleUserID ?? currentUser?.id.uuidString ?? "local-user" }

    init() {
        appleUserID = KeychainStore.get(appleUserKey)
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: loggedInKey),
           let rawRole = defaults.string(forKey: roleKey),
           let role = UserRole(rawValue: rawRole) {
            currentUser = Self.loadUser(from: defaults, key: userKey)
            authState = role == .student ? .student : .instructor
        }
    }

    private static func loadUser(from defaults: UserDefaults, key: String) -> User? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(User.self, from: data)
    }

    private func persistUser() {
        if let currentUser, let data = try? JSONEncoder().encode(currentUser) {
            UserDefaults.standard.set(data, forKey: userKey)
        }
    }

    /// Records the Apple credential's stable user id (persisted to the Keychain).
    func setAppleUserID(_ id: String) {
        appleUserID = id
        KeychainStore.set(id, for: appleUserKey)
    }

    /// On launch, drop the session if Apple has revoked the credential.
    func validateAppleCredential() async {
        guard let appleUserID else { return }
        let state = try? await ASAuthorizationAppleIDProvider()
            .credentialState(forUserID: appleUserID)
        if state == .revoked || state == .notFound {
            await MainActor.run { logout() }
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
            fullName: Self.displayName(fromEmail: email),
            email: email,
            role: role,
            memberSince: Date()
        )
        persist(role: role)
    }

    /// Best-effort display name from an email local-part (no backend to look up the real name yet).
    private static func displayName(fromEmail email: String) -> String {
        let local = email.split(separator: "@").first.map(String.init) ?? email
        return local
            .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    func logout() {
        currentUser = nil
        appleUserID = nil
        authState = .unauthenticated
        UserDefaults.standard.removeObject(forKey: roleKey)
        UserDefaults.standard.removeObject(forKey: userKey)
        UserDefaults.standard.set(false, forKey: loggedInKey)
        KeychainStore.set(nil, for: appleUserKey)
    }

    private func persist(role: UserRole) {
        UserDefaults.standard.set(role.rawValue, forKey: roleKey)
        UserDefaults.standard.set(true, forKey: loggedInKey)
        persistUser()
        withAnimation(.spring(duration: 0.4, bounce: 0.1)) {
            authState = role == .student ? .student : .instructor
        }
    }
}
