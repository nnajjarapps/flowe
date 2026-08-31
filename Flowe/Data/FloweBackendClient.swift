import Foundation
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#endif

/// Where the booking authorization backend lives. The rest of the app stays serverless on CloudKit;
/// only the booking/decision exchange (and the roster/class-mates read) go through here so that
/// who-trains-with-whom is returned ONLY to the two parties, via a per-request authorization check
/// CloudKit's public DB cannot provide. See flowe_vault/nodes/system/BookingBackend.md.
enum FloweBackend {
    /// The Cloudflare Worker. A custom domain can front this later without touching callers.
    ///
    /// DEBUG builds talk to a SEPARATE worker + D1 database. Before this existed the URL was hardcoded
    /// to production, which left a genuine asymmetry: CloudKit routes a debug build to its DEVELOPMENT
    /// container automatically, so the same build read CloudKit-dev while writing D1-PROD. Simulator
    /// testing wrote real bookings, reviews and profiles next to real users' rows, a debug booking could
    /// reference an instructor that only exists in the other container, and `DELETE /me` purged live
    /// data. There was also nowhere to rehearse a migration.
    ///
    /// TestFlight and App Store builds are not DEBUG, so they keep using production — unchanged.
    #if DEBUG
    static let baseURL = URL(string: "https://flowe-backend-dev.flowepilates.workers.dev")!
    #else
    static let baseURL = URL(string: "https://flowe-backend.flowepilates.workers.dev")!
    #endif
}

enum BackendError: Error {
    /// No session and no non-interactive way to obtain one (caller should degrade, not crash).
    case notAuthenticated
    case http(Int)
    case transport(Error)
}

/// The single HTTP client for the booking backend. Owns the per-device session lifecycle:
/// verifies the Apple identity token ONCE (via POST /auth/apple) to mint a short session token +
/// long-lived refresh token, both kept in the NON-synchronizable Keychain (device-scoped — unlike the
/// DM key, a rotating token must not sync across devices). Transport only; the booking *domain* calls
/// live in `BookingService`, which uses `authorized(...)` here.
@MainActor
final class FloweBackendClient {
    static let shared = FloweBackendClient()
    private init() {}

    // Non-synchronizable (default) Keychain slots — device-scoped, do not ride iCloud Keychain.
    private let sessionKey = "flowe.session.token.v1"
    private let refreshKey = "flowe.session.refresh.v1"
    private let deviceKey  = "flowe.session.device.v1"
    // Set when a logout/delete teardown couldn't reach the backend, so a later launch retries it
    // instead of orphaning the device row / the user's booking rows.
    private let pendingLogoutKey = "flowe.session.pendingLogout"
    private let pendingDeleteKey = "flowe.session.pendingDelete"

    private let urlSession = URLSession(configuration: .default)
    /// Latest APNs device token (hex). Cached because the token callback can land before or during
    /// auth; we (re)post it whenever a session exists.
    private var apnsTokenHex: String?
    /// Retains the in-flight Apple re-auth helper for the duration of the request.
    private var reauth: AppleReauth?
    /// In-flight interactive re-auth, so concurrent callers share ONE Apple prompt (never two sheets).
    private var reauthTask: Task<Bool, Never>?
    /// In-flight silent refresh, so a burst of authorized() calls after the 1h session expires shares
    /// ONE `/auth/refresh` — the backend rotates the refresh token per use, so a stampede would have all
    /// but the first send a stale token → 401 "revoked" → wiped session → needless Sign-in-with-Apple.
    private var refreshTask: Task<Bool, Never>?
    /// Interactive recovery from a pull-to-refresh is attempted at most once per launch — otherwise a
    /// genuinely session-less user is prompted on every single refresh. Reset only by a fresh launch.
    private var didAttemptInteractiveRecovery = false

    /// The debug two-party harness injects an ownerID with no real Apple credential; skip the backend
    /// entirely there so those launches don't 401 against live JWKS verification.
    private var isDebugInjected: Bool {
        #if DEBUG
        return UserDefaults.standard.string(forKey: "flowe.debugAppleUserID")?.isEmpty == false
        #else
        return false
        #endif
    }

    /// Stable per-install id; minted once and persisted. Maps to the backend `devices` row.
    private var deviceID: String {
        if let existing = KeychainStore.get(deviceKey) { return existing }
        let fresh = UUID().uuidString
        KeychainStore.set(fresh, for: deviceKey)
        return fresh
    }

    var hasSession: Bool { KeychainStore.get(sessionKey) != nil || KeychainStore.get(refreshKey) != nil }

    /// The app's "Booking requests" toggle (NotificationPreference.bookings, default on), sent to the
    /// backend so it can honour it server-side — the toggle is otherwise inert now that booking pushes
    /// come from the backend rather than a CloudKit subscription.
    private var bookingNotificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: "notif.bookings") as? Bool ?? true
    }

    // MARK: - Session lifecycle

    /// Exchange a fresh Apple identityToken for a backend session. Non-fatal on failure — the local
    /// CloudKit-first session still proceeds; a later authorized call or launch retries.
    func bootstrap(identityToken: String) async {
        guard !isDebugInjected else { return }
        struct Req: Encodable { let identityToken: String; let deviceId: String; let apnsToken: String?; let notifyBookings: Bool }
        let payload = Req(identityToken: identityToken, deviceId: deviceID,
                          apnsToken: apnsTokenHex, notifyBookings: bookingNotificationsEnabled)
        do {
            let data = try await rawSend("/auth/apple", method: "POST",
                                         jsonBody: try JSONEncoder().encode(payload), bearer: nil)
            struct Resp: Decodable { let sessionToken: String; let refreshToken: String }
            let resp = try JSONDecoder().decode(Resp.self, from: data)
            KeychainStore.set(resp.sessionToken, for: sessionKey)
            KeychainStore.set(resp.refreshToken, for: refreshKey)
            clearPendingTeardown()
            await flushPendingAPNs()   // token that arrived mid-bootstrap is now postable
        } catch {
            // swallow — booking calls degrade to notAuthenticated until a session exists
        }
    }

    /// Silent session ensure (NO UI): valid session → true; else try a refresh. For launch/background.
    @discardableResult
    func ensureSessionSilently() async -> Bool {
        guard !isDebugInjected else { return false }
        if KeychainStore.get(sessionKey) != nil { return true }
        return await refreshSession()
    }

    /// Interactive ensure: silent first; if that fails, re-auth with Apple for a fresh identityToken.
    /// Call ONLY from a user-initiated action (a booking write) — never a launch/background path.
    @discardableResult
    func ensureInteractiveSession() async -> Bool {
        guard !isDebugInjected else { return false }
        if await ensureSessionSilently() { return true }
        // SINGLE-FLIGHT: concurrent callers (a booking write racing a background sync, two writes at
        // once) must share ONE Apple prompt — otherwise each presents its own sheet and the user sees
        // "Sign in with Apple" twice in a row. The first arrival owns the reauth; the rest await it.
        if let inFlight = reauthTask { return await inFlight.value }
        let task = Task { @MainActor () -> Bool in
            let helper = AppleReauth()
            reauth = helper
            defer { reauth = nil }
            guard let token = try? await helper.identityToken() else { return false }
            await bootstrap(identityToken: token)
            return KeychainStore.get(sessionKey) != nil
        }
        reauthTask = task
        let ok = await task.value
        reauthTask = nil
        return ok
    }

    /// Recover a backend session for someone signed in to the app who has NO backend session — they
    /// signed in BEFORE the backend existed (so `bootstrap` never ran) or their refresh token was
    /// wiped. Reads are non-interactive and can't self-heal, so the booking screens call this from a
    /// **user-initiated** pull-to-refresh / retry (never a launch or background path — that keeps
    /// `ensureInteractiveSession`'s contract intact). It is **silent-first**: a live session or a
    /// working refresh token recovers with NO prompt (the common case, so a normal user never sees a
    /// sheet); only a genuinely session-less user gets one contextual Apple re-auth. Returns whether a
    /// session exists afterward.
    @discardableResult
    func recoverSessionIfNeeded() async -> Bool {
        // Silent-first: a live session or a working refresh token recovers with NO prompt (the common
        // case). Escalate to an interactive Apple prompt AT MOST ONCE per launch — the calendar and
        // booking screens call this from EVERY pull-to-refresh, so without this guard a genuinely
        // session-less user was prompted on every single refresh. After one attempt, refreshes recover
        // silently only (a deliberate booking WRITE can still prompt via `ensureInteractiveSession`).
        if await ensureSessionSilently() { return true }
        guard !didAttemptInteractiveRecovery else { return false }
        didAttemptInteractiveRecovery = true
        return await ensureInteractiveSession()
    }

    /// Refresh the short session token. On a DEFINITIVE 401 (refresh token revoked/expired) wipe BOTH
    /// tokens so `hasSession` drops and the app re-auths cleanly; on transport/5xx keep them (offline
    /// is recoverable). Stores the rotated refresh token the backend returns.
    private func refreshSession() async -> Bool {
        // SINGLE-FLIGHT (the "stay signed in like WhatsApp" fix): after the 1h session token expires, a
        // screen refresh fans out MANY authorized() calls at once — each would call refreshSession with
        // the SAME refresh token. The backend ROTATES the token per use, so the first call invalidates
        // it and the rest send a stale token → 401 "revoked" → wipeTokens() → an interactive Apple
        // prompt. Sharing ONE refresh (concurrent callers await it) keeps the 90-day session alive
        // silently; only a GENUINELY revoked token (the single call fails) wipes and forces re-auth.
        if let inFlight = refreshTask { return await inFlight.value }
        let task = Task { @MainActor () -> Bool in
            guard let refresh = KeychainStore.get(refreshKey) else { return false }
            struct Req: Encodable { let refreshToken: String; let deviceId: String }
            do {
                let data = try await rawSend("/auth/refresh", method: "POST",
                                             jsonBody: try JSONEncoder().encode(Req(refreshToken: refresh, deviceId: deviceID)),
                                             bearer: nil)
                struct Resp: Decodable { let sessionToken: String; let refreshToken: String? }
                let resp = try JSONDecoder().decode(Resp.self, from: data)
                KeychainStore.set(resp.sessionToken, for: sessionKey)
                if let rotated = resp.refreshToken { KeychainStore.set(rotated, for: refreshKey) }
                return true
            } catch BackendError.http(401) {
                wipeTokens()   // the refresh token is genuinely dead — don't leave a wedged session
                return false
            } catch {
                return false   // transient — keep tokens for the next attempt
            }
        }
        refreshTask = task
        let ok = await task.value
        refreshTask = nil
        return ok
    }

    // MARK: - Authorized requests (the seam BookingService uses)

    func authorized(_ path: String, method: String = "GET", query: [URLQueryItem] = [], interactive: Bool = false) async throws -> Data {
        try await authorizedData(path, method: method, query: query, jsonBody: nil, interactive: interactive)
    }

    func authorized<T: Encodable>(_ path: String, method: String = "POST", query: [URLQueryItem] = [], body: T, interactive: Bool = false) async throws -> Data {
        try await authorizedData(path, method: method, query: query, jsonBody: try JSONEncoder().encode(body), interactive: interactive)
    }

    /// Core: guarantee a session, attach the bearer, and transparently refresh once on a 401. Reads
    /// pass `interactive: false` (a failed session → `.notAuthenticated`, degrade quietly); user-driven
    /// writes pass `interactive: true` so an upgraded/new-device user gets a contextual Apple re-auth.
    private func authorizedData(_ path: String, method: String, query: [URLQueryItem], jsonBody: Data?, interactive: Bool) async throws -> Data {
        guard !isDebugInjected else { throw BackendError.notAuthenticated }
        try await ensureAuthed(interactive: interactive)
        do {
            return try await rawSend(path, method: method, query: query, jsonBody: jsonBody, bearer: KeychainStore.get(sessionKey))
        } catch BackendError.http(401) {
            try await ensureAuthed(interactive: interactive, forceRefresh: true)
            return try await rawSend(path, method: method, query: query, jsonBody: jsonBody, bearer: KeychainStore.get(sessionKey))
        }
    }

    private func ensureAuthed(interactive: Bool, forceRefresh: Bool = false) async throws {
        if !forceRefresh, KeychainStore.get(sessionKey) != nil { return }
        if await refreshSession() { return }
        if interactive, await ensureInteractiveSession() { return }
        throw BackendError.notAuthenticated
    }

    // MARK: - Device / push

    /// Cache the APNs token and, if a session exists, register it. Re-posts on rotation.
    func registerAPNs(token hex: String) async {
        apnsTokenHex = hex
        guard !isDebugInjected, hasSession else { return }
        struct Req: Encodable { let deviceId: String; let apnsToken: String }
        _ = try? await authorized("/devices", method: "POST", body: Req(deviceId: deviceID, apnsToken: hex))
    }

    /// Re-post a token that was cached before a session existed (e.g. it arrived mid-bootstrap).
    private func flushPendingAPNs() async {
        guard let hex = apnsTokenHex, KeychainStore.get(sessionKey) != nil else { return }
        struct Req: Encodable { let deviceId: String; let apnsToken: String }
        guard let jsonBody = try? JSONEncoder().encode(Req(deviceId: deviceID, apnsToken: hex)) else { return }
        _ = try? await rawSend("/devices", method: "POST", jsonBody: jsonBody, bearer: KeychainStore.get(sessionKey))
    }

    /// Push the "Booking requests" toggle to the backend so booking pushes actually stop/resume.
    func setBookingNotifications(_ enabled: Bool) async {
        guard !isDebugInjected, hasSession else { return }
        struct Req: Encodable { let deviceId: String; let notifyBookings: Bool }
        _ = try? await authorized("/devices", method: "POST", body: Req(deviceId: deviceID, notifyBookings: enabled))
    }

    /// Push the "Reviews" toggle to the backend so review pushes actually stop/resume.
    func setReviewNotifications(_ enabled: Bool) async {
        guard !isDebugInjected, hasSession else { return }
        struct Req: Encodable { let deviceId: String; let notifyReviews: Bool }
        _ = try? await authorized("/devices", method: "POST", body: Req(deviceId: deviceID, notifyReviews: enabled))
    }

    /// Unauthenticated GET for a PUBLIC endpoint (e.g. the reviews wall a guest browses) — no session or
    /// bearer required, so it works before/without sign-in. Callers degrade on throw.
    func publicData(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await rawSend(path, method: "GET", query: query, jsonBody: nil, bearer: nil)
    }

    /// Sync the user's community opt-in + display name to the backend `profiles` table. This is what
    /// makes the event "who's going" roster secure — the mutual opt-in is enforced server-side, so a
    /// name is returned only when both the viewer and the attendee have opted in. Best-effort.
    func setCommunityVisible(_ visible: Bool, name: String) async {
        guard !isDebugInjected, hasSession else { return }
        struct Req: Encodable { let communityVisible: Bool; let displayName: String }
        _ = try? await authorized("/profile", method: "POST", body: Req(communityVisible: visible, displayName: name))
    }

    // MARK: - Subscription entitlement

    /// Report what StoreKit resolved to the backend, so Flowe holds its own durable record of who is
    /// subscribed. Until this existed the ONLY trace of a subscription was `InstructorListing.visibility`
    /// — a derived field the instructor's own device writes to public CloudKit — so nothing server-side
    /// could answer "is this instructor actually paying?", and a lapse stayed invisible until their
    /// device happened to reopen.
    ///
    /// This is BOOKKEEPING, not verification: the payload comes from the device, so it must never
    /// become an authorization decision. Making it authoritative means App Store Server Notifications
    /// V2 posting Apple's signed JWS to the backend instead of the client reporting it.
    /// Best-effort and silent — entitlement on THIS device still comes from StoreKit either way.
    func reportEntitlement(tier: Int, productID: String?, expiresAt: Date?,
                           originalID: String?, environment: String?) async {
        guard !isDebugInjected, hasSession else { return }
        struct Req: Encodable {
            let tier: Int; let productID: String?; let expiresAt: Double?
            let originalID: String?; let environment: String?
        }
        _ = try? await authorized("/entitlement", method: "POST", body: Req(
            tier: tier, productID: productID,
            expiresAt: expiresAt.map { $0.timeIntervalSince1970 * 1000 },
            originalID: originalID, environment: environment))
    }

    // MARK: - Student preferences (reinstall recovery)

    /// Mirror the student's quiz answers to the backend. They previously lived only in UserDefaults,
    /// which app deletion wipes — so a reinstalling student was pushed back through the whole quiz and
    /// silently lost the match profile driving their recommendations. Best-effort: the local copy stays
    /// the source of truth for this device, this is the copy that survives the device.
    func saveStudentPreferences(json: String) async {
        guard !isDebugInjected, hasSession else { return }
        struct Req: Encodable { let preferences: String }
        _ = try? await authorized("/profile", method: "POST", body: Req(preferences: json))
    }

    /// My own profile row. Used on sign-in to recover account state the device can't rebuild locally.
    /// Returns nil when there's no session, no row, or the call fails — every caller treats a nil as
    /// "nothing to restore" and carries on.
    func fetchMyProfile() async -> RemoteProfile? {
        guard !isDebugInjected, hasSession else { return nil }
        guard let data = try? await authorized("/profile", method: "GET") else { return nil }
        guard let resp = try? JSONDecoder().decode(RemoteProfile.self, from: data), resp.found else { return nil }
        return resp
    }

    struct RemoteProfile: Decodable {
        let found: Bool
        let communityVisible: Bool?
        let presenceVisible: Bool?
        let displayName: String?
        let preferences: String?
        /// When this account first published a DM public key. Environment-INDEPENDENT proof that a
        /// keypair exists — see `reportDMKeyPublished()`.
        let dmKeyAt: Double?
    }

    /// Record that this account has a DM keypair.
    ///
    /// `MessageCrypto` must never mint a key when one already exists, because minting overwrites the
    /// iCloud-Keychain key and permanently orphans every message sealed against it. Its evidence used to
    /// be the CloudKit `PublicKey` record — but that record is PER-CONTAINER, so a debug build looks in
    /// Development, and on a fresh device would find nothing, mint, and destroy the production key it
    /// shares through the Keychain. This marker does not care which container you are talking to.
    ///
    /// Write-once server-side: the stamp is never refreshed or cleared, only removed with the account.
    func reportDMKeyPublished() async {
        guard !isDebugInjected, hasSession else { return }
        struct Req: Encodable { let dmKeyPublished: Bool }
        _ = try? await authorized("/profile", method: "POST", body: Req(dmKeyPublished: true))
    }

    // MARK: - Hidden messages (delete-for-me, reinstall recovery)

    /// Mirror deleted-message tombstones. A message the user RECEIVED isn't theirs to delete from the
    /// shared store — it can only be hidden — and that hiding previously lived only in UserDefaults,
    /// which app deletion wipes, so deleting a conversation and reinstalling brought the counterpart's
    /// half of it straight back. Best-effort: the local set stays the source of truth for this device.
    func hideMessages(remoteIDs: [String]) async {
        guard !isDebugInjected, hasSession, !remoteIDs.isEmpty else { return }
        struct Req: Encodable { let remoteIDs: [String] }
        // The route caps a call at 500 ids; a long-running thread can exceed that in one delete.
        for chunk in stride(from: 0, to: remoteIDs.count, by: 500).map({
            Array(remoteIDs[$0..<min($0 + 500, remoteIDs.count)])
        }) {
            _ = try? await authorized("/messages/hidden", method: "POST", body: Req(remoteIDs: chunk))
        }
    }

    /// Every message this account has hidden, on any install. Empty on no session or failure — callers
    /// treat that as "nothing extra to hide" and keep their local set.
    func fetchHiddenMessages() async -> [String] {
        guard !isDebugInjected, hasSession else { return [] }
        guard let data = try? await authorized("/messages/hidden", method: "GET") else { return [] }
        struct Resp: Decodable { let remoteIDs: [String] }
        return (try? JSONDecoder().decode(Resp.self, from: data))?.remoteIDs ?? []
    }

    // MARK: - Presence ("last seen")

    /// Heartbeat MY last-seen — the backend stamps SERVER time on the authenticated ownerID (a client
    /// timestamp is never trusted). Fire-and-forget; the caller gates on the presence opt-out + non-guest.
    func heartbeatPresence() async {
        guard !isDebugInjected, hasSession else { return }
        _ = try? await authorized("/presence", method: "POST")
    }

    /// Last-seen for the given owners (the caller's conversation partners). Server enforces WhatsApp
    /// reciprocity + each owner's visibility, so it returns only owners the backend permits.
    func fetchPresence(ownerIDs: [String]) async -> [String: Date] {
        guard !isDebugInjected, hasSession, !ownerIDs.isEmpty else { return [:] }
        let query = ownerIDs.prefix(200).map { URLQueryItem(name: "ownerID", value: $0) }
        do {
            let data = try await authorized("/presence", method: "GET", query: Array(query))
            struct Resp: Decodable { let presence: [String: Double] }
            let resp = try JSONDecoder().decode(Resp.self, from: data)
            return resp.presence.mapValues { Date(timeIntervalSince1970: $0 / 1000) }
        } catch {
            return [:]
        }
    }

    /// Publish the "show when I'm active" opt-out to the backend (server-enforced, WhatsApp reciprocity —
    /// hiding yours also hides everyone else's from you).
    func setPresenceVisible(_ visible: Bool) async {
        guard !isDebugInjected, hasSession else { return }
        struct Req: Encodable { let presenceVisible: Bool }
        _ = try? await authorized("/profile", method: "POST", body: Req(presenceVisible: visible))
    }

    // MARK: - Teardown

    /// Logout: stop the backend pushing to this device, then wipe local tokens. Wipes ONLY on a
    /// confirmed DELETE; otherwise keeps the session and flags a retry so the device row isn't
    /// orphaned (which would keep pushing the prior user's booking alerts to a signed-out device).
    func logout() async {
        struct Req: Encodable { let deviceId: String }
        let ok = (try? await authorized("/devices", method: "DELETE", body: Req(deviceId: deviceID))) != nil
        if ok {
            UserDefaults.standard.removeObject(forKey: pendingLogoutKey)
            wipeTokens()
        } else {
            UserDefaults.standard.set(true, forKey: pendingLogoutKey)
        }
    }

    /// Account deletion (Guideline 5.1.1v): purge every backend row this user is party to, then wipe.
    /// Wipes ONLY on a confirmed DELETE; otherwise keeps the session and flags a retry so the user's
    /// relationship-graph rows are never silently orphaned (which would defeat the deletion promise).
    func deleteAccount() async {
        let ok = (try? await authorized("/me", method: "DELETE")) != nil
        if ok {
            UserDefaults.standard.removeObject(forKey: pendingDeleteKey)
            wipeTokens()
        } else {
            UserDefaults.standard.set(true, forKey: pendingDeleteKey)
        }
    }

    /// Retry an interrupted logout/delete at launch (a deletion takes priority over a logout).
    func resumePendingTeardown() async {
        guard !isDebugInjected else { return }
        if UserDefaults.standard.bool(forKey: pendingDeleteKey) { await deleteAccount(); return }
        if UserDefaults.standard.bool(forKey: pendingLogoutKey) { await logout() }
    }

    private func clearPendingTeardown() {
        UserDefaults.standard.removeObject(forKey: pendingLogoutKey)
        UserDefaults.standard.removeObject(forKey: pendingDeleteKey)
    }

    private func wipeTokens() {
        KeychainStore.set(nil, for: sessionKey)
        KeychainStore.set(nil, for: refreshKey)
        // deviceID intentionally preserved — a fresh sign-in reuses the same device row.
    }

    // MARK: - Raw transport

    private func rawSend(_ path: String, method: String, query: [URLQueryItem] = [], jsonBody: Data?, bearer: String?) async throws -> Data {
        var comps = URLComponents(url: FloweBackend.baseURL, resolvingAgainstBaseURL: false)!
        comps.path = path
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw BackendError.transport(URLError(.badURL)) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = jsonBody
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch {
            throw BackendError.transport(error)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw BackendError.http(code) }
        return data
    }
}

/// One-shot Apple re-authentication that yields a fresh identityToken. Used only when the backend
/// refresh token is gone; for an already-authorized user on the same device this typically completes
/// with minimal or no UI. This is the codebase's only hand-rolled ASAuthorizationController (all other
/// sign-in goes through SwiftUI's SignInWithAppleButton).
@MainActor
final class AppleReauth: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<String, Error>?

    func identityToken() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            let request = ASAuthorizationAppleIDProvider().createRequest()
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = cred.identityToken,
              let token = String(data: data, encoding: .utf8) else {
            continuation?.resume(throwing: BackendError.notAuthenticated); continuation = nil; return
        }
        continuation?.resume(returning: token); continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) ?? scenes.first?.windows.first {
            return window
        }
        return ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}
