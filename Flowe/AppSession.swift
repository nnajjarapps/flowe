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

    /// Guest-browse mode (App Store Guideline 5.1.1(v)): the user chose to explore Discover WITHOUT an
    /// account. They deliberately stay `authState == .unauthenticated` — so every signed-in-only guard
    /// (FlowApp's `else if authState == .student`, `guard authState != .unauthenticated`) still fences
    /// off ALL account writes — while `AppRouter` renders the student tab shell (Discover) instead of
    /// onboarding. Cleared the instant they sign in (`startSession`) or out (`logout`).
    private(set) var isGuest = false

    /// Enter guest-browse mode from the welcome screen.
    func enterGuest() { isGuest = true }

    /// True when a signed-in student hasn't finished the onboarding quiz — drives `AppRouter` to show
    /// the quiz before the tabs.
    var needsOnboardingQuiz = false

    /// Deep-link target captured from a Universal Link (`https://nnajjarapps.github.io/flowe-support/i/<ownerID>`)
    /// before `StudentTabView` is mounted. Survives the login/quiz gate; consumed + cleared by
    /// `StudentTabView`. The exact analog of `PushService.pendingTopic`.
    var pendingInstructorID: String?

    /// The student's saved match preferences. Restored per-account (mirrors the durable-profile
    /// pattern), so they survive logout and come back on re-sign-in for the same Apple ID.
    private(set) var studentPreferences: StudentPreferences?

    /// Stable Apple user identifier (the only id Apple returns on every sign-in). Kept in the
    /// Keychain so it survives reinstalls; becomes the owner id for the user's CloudKit records.
    private(set) var appleUserID: String?

    private let roleKey = "flowe.userRole"
    private let loggedInKey = "flowe.isLoggedIn"
    private let appleUserKey = "flowe.appleUserID"
    private let userKey = "flowe.user"

    /// Shared source of truth for which role this Apple ID currently acts as — the cross-device guard
    /// that keeps one account from being an instructor on one device and a student on another.
    private let accountRoleService = AccountRoleService()

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
        #if DEBUG
        applyDebugIdentityInjection(defaults)
        #endif
        refreshStudentPreferences()
        refreshTermsAcceptance()   // so a returning, already-accepted account isn't re-gated on launch
    }

    #if DEBUG
    /// Two-party manual-testing harness (DEBUG only, never ships). Launching with
    /// `-flowe.debugAppleUserID <id> -flowe.isLoggedIn 1 -flowe.userRole instructor|student`
    /// forces a stable LOGICAL identity (ownerID = `<id>`) without going through the flaky
    /// Sign-in-with-Apple UI in the simulator. Real CloudKit still authenticates against whatever
    /// iCloud account the simulator is signed into — this only overrides the app's own owner id, so
    /// two simulators can act as a distinct instructor and student against the real public database.
    /// `validateAppleCredential()` is a no-op under this flag (see there), so the injected id isn't
    /// wiped as "unknown to Apple". `-flowe.debugUserName "Name"` sets the display name.
    private func applyDebugIdentityInjection(_ defaults: UserDefaults) {
        guard let injected = defaults.string(forKey: "flowe.debugAppleUserID"), !injected.isEmpty
        else { return }
        setAppleUserID(injected)
        let role: UserRole = defaults.string(forKey: roleKey) == "instructor" ? .instructor : .student
        let name = defaults.string(forKey: "flowe.debugUserName")
            ?? (role == .instructor ? "Test Instructor" : "Test Student")
        currentUser = loadDurableProfile() ?? User(
            id: UUID(), fullName: name, email: "", role: role, memberSince: Date()
        )
        authState = role == .instructor ? .instructor : .student
        // The harness bypasses Sign-in-with-Apple, so also bypass the router's terms gate — otherwise a
        // debug/UI-test launch lands on the acceptance screen instead of the app.
        recordTermsAcceptance()

        // `-flowe.debugOpenInstructor <ownerID>` deep-links a student straight to that instructor's
        // profile by DIRECT recordID fetch (`loadInstructor` → `CatalogService.fetch(ownerIDs:)`),
        // bypassing both the flaky simulator universal-link delivery AND the CloudKit visibility>0
        // query index (which lags for a just-published listing seen by another account). Same seam the
        // real universal link uses — `StudentTabView.task(id: pendingInstructorID)`.
        if let openID = defaults.string(forKey: "flowe.debugOpenInstructor"), !openID.isEmpty {
            pendingInstructorID = openID
        }
    }
    #endif

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

    // MARK: - Student onboarding preferences (durable, per-account)

    private func studentPrefsKey(for owner: String) -> String { "flowe.studentPrefs.\(owner)" }

    /// Persist the student's quiz answers and leave onboarding. Stamps `completedAt` if the caller
    /// didn't (a skip stores an empty completed record, so we never re-prompt).
    func saveStudentPreferences(_ prefs: StudentPreferences) {
        var stored = prefs
        if stored.completedAt == nil { stored.completedAt = Date() }
        studentPreferences = stored
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: studentPrefsKey(for: ownerID))
        }
        withAnimation(.spring(duration: 0.4, bounce: 0.1)) { needsOnboardingQuiz = false }
    }

    private func loadStudentPreferences() -> StudentPreferences? {
        guard let data = UserDefaults.standard.data(forKey: studentPrefsKey(for: ownerID)) else { return nil }
        return try? JSONDecoder().decode(StudentPreferences.self, from: data)
    }

    /// Re-derive the in-memory prefs + onboarding flag from disk for the current owner.
    private func refreshStudentPreferences() {
        let prefs = loadStudentPreferences()
        studentPreferences = prefs
        needsOnboardingQuiz = (authState == .student) && (prefs == nil)
    }

    /// Records the Apple credential's stable user id (persisted to the Keychain).
    func setAppleUserID(_ id: String) {
        appleUserID = id
        KeychainStore.set(id, for: appleUserKey)
    }

    /// On launch, drop the session if Apple has revoked the credential.
    func validateAppleCredential() async {
        #if DEBUG
        // Injected debug identity (two-party test harness) is unknown to Apple, so the real
        // credential check would report `.notFound` and log us straight back out. Skip it.
        if UserDefaults.standard.string(forKey: "flowe.debugAppleUserID")?.isEmpty == false { return }
        #endif
        guard let appleUserID else { return }
        let state = try? await ASAuthorizationAppleIDProvider()
            .credentialState(forUserID: appleUserID)
        if state == .revoked || state == .notFound {
            await MainActor.run { logout() }
        }
    }

    // MARK: - Terms & Community Guidelines acceptance (App Store Guideline 1.2 — UGC)

    /// Bump when the Terms of Use / Community Guidelines change materially — every account is then
    /// re-prompted (the router gate re-appears) before continuing.
    static let termsVersion = 1
    /// PER-ACCOUNT key (by `ownerID`) — device-global storage let a second Apple ID on a shared device
    /// slip in without agreeing, and couldn't distinguish who accepted which version.
    private func termsKey(for ownerID: String) -> String { "flowe.termsAcceptedVersion.\(ownerID)" }

    /// Whether the CURRENT account has accepted the CURRENT Terms + Community Guidelines. Observable
    /// (`private(set) var`, not a UserDefaults read) so [[AppRouter]]'s gate re-renders the instant it
    /// flips. Refreshed on session start / launch-restore; `false` when signed out or after a version bump.
    private(set) var hasAcceptedTerms = false

    /// Load the signed-in account's acceptance into the observable flag. Called from `init` (launch
    /// restore) and `startSession` (fresh sign-in), once `ownerID` is known.
    private func refreshTermsAcceptance() {
        hasAcceptedTerms = UserDefaults.standard.integer(forKey: termsKey(for: ownerID)) >= Self.termsVersion
    }

    /// Record acceptance for the current account (App Store Guideline 1.2). Idempotent; flips the
    /// observable flag so the router gate dismisses immediately.
    func recordTermsAcceptance() {
        UserDefaults.standard.set(Self.termsVersion, forKey: termsKey(for: ownerID))
        UserDefaults.standard.set(Date(), forKey: termsKey(for: ownerID) + ".date")
        hasAcceptedTerms = true
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
        isGuest = false   // signing in always exits guest-browse mode
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
        // Restore this account's quiz answers; a student with none is routed to onboarding.
        // (ownerID is valid here — sign-in sets the Apple id before signUp/login.)
        let prefs = loadStudentPreferences()
        studentPreferences = prefs
        needsOnboardingQuiz = (role == .student) && (prefs == nil)
        persist(role: role)
        refreshTermsAcceptance()   // load THIS account's acceptance; router gates if it hasn't accepted
    }

    // MARK: - Cross-device role guard
    //
    // One Apple ID = one ACTIVE role at a time. The role is switchable (`switchRole`) but must never
    // DIVERGE across a user's devices: an iPad-instructor + iPhone-student on ONE iCloud account share a
    // private CloudKit DB and cross-contaminate, and every student↔instructor flow becomes self-
    // referential. `AccountRoleService` is the shared, per-ownerID source of truth.

    /// Outcome of an Apple sign-in that first reconciles against the account's established role.
    enum SignInOutcome: Equatable {
        case started(UserRole)                 // a session began as this role
        case roleMismatch(existing: UserRole)  // blocked — this Apple ID already acts as the other role
    }

    /// Pure decision: given the desired role and what CloudKit says is established, do we proceed (and
    /// should we write/refresh the claim), or block? Extracted so it's unit-testable without CloudKit.
    /// NEVER claims on `.unavailable` — a transient read failure must not let a stale choice overwrite a
    /// real claim (foreground `reconcileRole` repairs the fail-open case once connectivity returns).
    nonisolated static func roleGate(desired: UserRole,
                                     established: EstablishedRole) -> (proceed: Bool, claim: Bool, existing: UserRole?) {
        switch established {
        case .claimed(let r): return r == desired ? (true, false, nil) : (false, false, r)
        case .none:           return (true, true, nil)
        case .unavailable:    return (true, false, nil)
        }
    }

    /// Begin a session for an Apple credential, but first check the account's established role so a
    /// second device can't sign in as a different role. On a mismatch the session is NOT started and the
    /// pending identity is cleared — the caller shows the "already set up as …" message.
    /// `adoptExistingRole`: when true, a role MISMATCH signs the user into their ACCOUNT'S established
    /// role instead of blocking. Used only by the guest-browse sign-in ([[Guest-Browse-Mode]]): a guest
    /// isn't choosing student-vs-instructor across devices — they're signing into whatever their account
    /// actually is — so blocking (which the normal onboarding keeps, to guard cross-device divergence)
    /// would strand an instructor in the guest student shell. Onboarding leaves this false.
    @MainActor
    func startSignIn(appleUserID: String, name: String, email: String,
                     desiredRole: UserRole, acceptTerms: Bool = false,
                     adoptExistingRole: Bool = false) async -> SignInOutcome {
        setAppleUserID(appleUserID)
        let established = await accountRoleService.lookup(for: appleUserID)
        let gate = Self.roleGate(desired: desiredRole, established: established)
        guard gate.proceed else {
            if adoptExistingRole, case .claimed(let actual) = established {
                if acceptTerms { recordTermsAcceptance() }
                startSession(defaultName: name, email: email, role: actual)
                return .started(actual)
            }
            clearPendingIdentity()
            return .roleMismatch(existing: gate.existing ?? desiredRole)
        }
        // Record acceptance BEFORE the session starts so the router's terms gate never flashes.
        if acceptTerms { recordTermsAcceptance() }
        startSession(defaultName: name, email: email, role: desiredRole)
        if gate.claim { await accountRoleService.setRole(desiredRole, for: appleUserID) }
        return .started(desiredRole)
    }

    /// Deliberately switch this account between student and instructor (Settings action). Updates the
    /// shared claim so every device converges, and flips the local shell immediately. Returns the role
    /// now in force (may differ from the target if another device raced a switch).
    @MainActor
    @discardableResult
    func switchRole() async -> UserRole? {
        guard let owner = appleUserID else { return nil }
        let current: UserRole = authState == .instructor ? .instructor : .student
        let target: UserRole = current == .instructor ? .student : .instructor
        let inForce = await accountRoleService.setRole(target, for: owner) ?? target
        applyRole(inForce)
        return inForce
    }

    /// On foreground, follow the account's current role if another device switched it — preserving the
    /// invariant that one Apple ID acts as ONE role at a time. No-op when the claim matches or can't be read.
    @MainActor
    func reconcileRole() async {
        guard authState != .unauthenticated, let owner = appleUserID else { return }
        guard case .claimed(let claimed) = await accountRoleService.lookup(for: owner) else { return }
        let current: UserRole = authState == .instructor ? .instructor : .student
        if claimed != current { applyRole(claimed) }
    }

    /// Apply a role locally: update the durable profile + auth state (which re-renders the correct shell).
    private func applyRole(_ role: UserRole) {
        if var u = currentUser { u.role = role; currentUser = u }
        persist(role: role)
        let prefs = loadStudentPreferences()
        needsOnboardingQuiz = (role == .student) && (prefs == nil)
    }

    /// User-facing copy for a blocked sign-in — shared by the sign-up and log-in screens. Names the role
    /// the Apple ID already holds and points at the in-app switch (the block isn't a lock).
    nonisolated static func roleMismatchMessage(existing: UserRole) -> String {
        existing == .instructor
            ? String(localized: "This Apple ID is already set up as an instructor. Go back and continue as an instructor — you can switch to a student account anytime in Settings.")
            : String(localized: "This Apple ID is already set up as a student. Go back and continue as a student — you can switch to an instructor account anytime in Settings.")
    }

    /// Undo a half-started sign-in: forget the Apple id we set before discovering a role mismatch, so no
    /// authenticated state lingers. Auth state stays `.unauthenticated`.
    func clearPendingIdentity() {
        appleUserID = nil
        KeychainStore.set(nil, for: appleUserKey)
    }

    /// Best-effort display name from an email local-part (no backend to look up the real name yet).
    static func displayName(fromEmail email: String) -> String {
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
        isGuest = false   // a signed-out user is not a guest — send them back to onboarding
        needsOnboardingQuiz = false
        // Clear the in-memory prefs, but leave the durable per-account copy on disk — it's restored
        // on re-sign-in, exactly like the durable profile.
        studentPreferences = nil
        UserDefaults.standard.removeObject(forKey: roleKey)
        UserDefaults.standard.removeObject(forKey: userKey)
        UserDefaults.standard.set(false, forKey: loggedInKey)
        KeychainStore.set(nil, for: appleUserKey)
    }

    /// Forget the credential AND wipe the durable per-account state after the account's data has been
    /// erased (see `DeleteAccountView`).
    ///
    /// This is where deletion diverges from a plain sign-out. `logout()` deliberately PRESERVES the
    /// durable per-account records (profile, quiz answers, terms acceptance, instructor-wizard state) so
    /// an ordinary sign-out → sign-in restores your edits. A DELETION must destroy them, or a re-signup
    /// with the SAME Apple ID silently inherits the old profile and skips every onboarding gate — blank
    /// profile, the student quiz, and the Guideline-1.2 terms gate would all be defeated. The keys are
    /// scoped by `ownerID` (== `appleUserID`), so they MUST be removed BEFORE `logout()` nils
    /// `appleUserID` — after that `ownerID` falls back to the local placeholder and the removals miss.
    func deleteAccount() {
        let owner = ownerID
        let d = UserDefaults.standard
        d.removeObject(forKey: durableProfileKey(for: owner))
        d.removeObject(forKey: studentPrefsKey(for: owner))
        d.removeObject(forKey: termsKey(for: owner))
        d.removeObject(forKey: termsKey(for: owner) + ".date")
        d.removeObject(forKey: "flowe.studioWizardDismissed.\(owner)")
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
