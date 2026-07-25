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

    /// Stable id for the signed-in user — used to own their bookings, messages and reviews.
    ///
    /// This is the Apple credential's user id, which Apple guarantees is stable for this app across
    /// the user's devices and reinstalls, and which the Keychain preserves locally.
    ///
    /// It deliberately does **not** fall back to `currentUser.id`. That is a fresh `UUID` minted on
    /// every sign-in, so using it as an owner id silently orphaned everything the user had the
    /// moment they signed out and back in — their records stayed in the shared store under an id
    /// nothing would ever look up again. Sign in with Apple is the only authenticated path, so a
    /// real session always has `appleUserID`; the fallback exists for UI-test launches that skip
    /// onboarding entirely.
    var ownerID: String { appleUserID ?? FloweConstants.localOwnerID }

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

    /// Applies a student's profile edits to the signed-in identity and persists them. A `nil`
    /// argument leaves that field untouched, so callers can update just the photo or just the bio.
    /// Trimmed, empty strings clear the field rather than storing whitespace.
    ///
    /// A logged-in session normally already carries a `currentUser` from the sign-in flow, but a
    /// UI-test launch (and any future path that logs in without minting one) can be authenticated
    /// with no user record. Rather than silently no-op there, synthesise a minimal `User` from the
    /// current auth state so the edit takes effect and persists.
    func updateProfile(fullName: String? = nil, bio: String? = nil, photo: Data?? = .none) {
        var user = currentUser ?? User(
            id: UUID(),
            fullName: "",
            email: "",
            role: authState == .instructor ? .instructor : .student,
            memberSince: Date()
        )
        guard authState != .unauthenticated || currentUser != nil else { return }
        if let fullName {
            let trimmed = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { user.fullName = trimmed }
        }
        if let bio {
            let trimmed = bio.trimmingCharacters(in: .whitespacesAndNewlines)
            user.bio = trimmed.isEmpty ? nil : trimmed
        }
        if case .some(let newPhoto) = photo { user.photo = newPhoto }
        currentUser = user
        persistUser()
        persistDurableProfile()
    }

    // MARK: - Durable per-account profile
    //
    // `userKey` is the *session* copy — `logout()` clears it so the next person on a shared device
    // doesn't inherit the last one's identity. But a user's own edits (name, bio, photo, join date)
    // must come back when *they* sign in again. Apple returns the name only on the first
    // authorization and nothing thereafter, so without this a re-sign-in mints a blank profile and
    // the edits appear lost. This copy is keyed by the stable owner id, outlives logout, and is
    // restored on the next sign-in for the same account.

    private func durableProfileKey(for owner: String) -> String { "flowe.profile.\(owner)" }

    private func persistDurableProfile() {
        guard let user = currentUser, let data = try? JSONEncoder().encode(user) else { return }
        UserDefaults.standard.set(data, forKey: durableProfileKey(for: ownerID))
    }

    private func loadDurableProfile() -> User? {
        guard let data = UserDefaults.standard.data(forKey: durableProfileKey(for: ownerID)) else { return nil }
        return try? JSONDecoder().decode(User.self, from: data)
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

    /// Start a session for an Apple-authenticated user.
    ///
    /// `User.id` is a fresh UUID and is **display-only** — never use it as an owner id. Ownership
    /// comes from `ownerID`, which is backed by the Apple credential; see the note there.
    func signUp(name: String, email: String, role: UserRole) {
        startSession(defaultName: name, email: email, role: role)
    }

    func login(email: String, role: UserRole) {
        startSession(defaultName: Self.displayName(fromEmail: email), email: email, role: role)
    }

    /// Begin an authenticated session. If the account has a saved profile from a previous session
    /// (see the durable-profile note above), restore the user's own edits — name, bio, photo, join
    /// date — instead of minting a blank identity. Role always comes from this sign-in; the email is
    /// only taken when none was stored, so a real address survives Apple's nil-on-re-auth behaviour.
    private func startSession(defaultName: String, email: String, role: UserRole) {
        if var saved = loadDurableProfile() {
            saved.role = role
            if saved.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                saved.fullName = defaultName
            }
            if saved.email.isEmpty, !email.isEmpty { saved.email = email }
            currentUser = saved
        } else {
            currentUser = User(
                id: UUID(),
                fullName: defaultName,
                email: email,
                role: role,
                memberSince: Date()
            )
        }
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

    /// Forget the credential after the account's data has been erased (see `DeleteAccountView`).
    ///
    /// Identical to `logout()` today because logout already discards the stored identity. It stays a
    /// separate entry point so deletion can never quietly degrade into a plain sign-out should
    /// `logout()` ever gain session-preserving behaviour.
    func deleteAccount() {
        logout()
    }

    private func persist(role: UserRole) {
        UserDefaults.standard.set(role.rawValue, forKey: roleKey)
        UserDefaults.standard.set(true, forKey: loggedInKey)
        persistUser()
        persistDurableProfile()
        withAnimation(.spring(duration: 0.4, bounce: 0.1)) {
            authState = role == .student ? .student : .instructor
        }
    }
}
