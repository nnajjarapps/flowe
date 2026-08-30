import SwiftUI
import AuthenticationServices

/// Log in. Sign in with Apple is the only path.
///
/// The email/password form this screen used to carry verified nothing — it checked the fields were
/// non-empty and signed the user straight in. With no backend there is nothing to check a password
/// against, so the form was theatre, and it meant every login minted a brand-new identity that
/// orphaned the user's bookings, messages and reviews. Apple's credential is a real, verified,
/// stable id, and it is the only one this app can honestly issue.
struct LoginView: View {
    let role: UserRole
    /// Guest-browse sign-in: adopt the account's real role on a mismatch instead of blocking. See
    /// [[Guest-Browse-Mode]]. Onboarding leaves this false.
    var adoptExistingRole: Bool = false
    @Environment(AppSession.self) private var session

    @State private var errorMessage: String?
    /// The cross-device role check is a CloudKit round-trip — block re-taps while it's in flight.
    @State private var isSigningIn = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FlowSpacing.xl) {
                VStack(alignment: .leading, spacing: FlowSpacing.xs) {
                    Text("Welcome back")
                        .flowFont(.displayMedium)
                        .foregroundStyle(Color.floweInk)

                    Text("Log in to continue your journey")
                        .flowFont(.bodyMedium)
                        .foregroundStyle(Color.floweMuted)
                }

                if let error = errorMessage {
                    Text(error)
                        .flowFont(.caption)
                        .foregroundStyle(Color.red)
                }

                SignInWithAppleButton(.signIn) { request in
                    // Name only — Flowe does not collect email (backend stores "never email"), so we don't
                    // request the scope. Keeps the App Privacy label / manifest honest (no Email Address).
                    request.requestedScopes = [.fullName]
                } onCompletion: { result in
                    handleApple(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 56)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .disabled(isSigningIn)
                .opacity(isSigningIn ? 0.45 : 1)
                .overlay { if isSigningIn { ProgressView().tint(.white) } }
                .accessibilityIdentifier("login.apple")

                Text("Flowe uses your Apple account so your sessions, messages and reviews stay "
                     + "with you across devices. We never see your password.")
                    .flowFont(.caption)
                    .foregroundStyle(Color.floweMuted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: FlowSpacing.xs) {
                    Text("Not a member?")
                        .flowFont(.bodyMedium)
                        .foregroundStyle(Color.floweMuted)
                    NavigationLink("Join now") {
                        CreateAccountView(role: role, adoptExistingRole: adoptExistingRole)
                    }
                    .flowFont(.bodyMedium)
                    .foregroundStyle(Color.flowePinkDeep)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, FlowSpacing.xl)
            .padding(.vertical, FlowSpacing.xl)
        }
        .floweBackground()
        .navigationTitle("Log In")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential else {
                errorMessage = "Apple Sign-In didn't return an account. Please try again."
                return
            }
            // Sign-in first reconciles the account's role across devices: if this Apple ID already acts
            // as the OTHER role, the session is blocked instead of creating a split-brain that shares
            // (and corrupts) the same private database. A user who has never accepted the terms is caught
            // by the router's gate right after sign-in.
            // The identity token (a JWT) is the credential Apple returns on EVERY sign-in; the booking
            // backend verifies it to mint a per-device session. Optional, so bootstrap only when present.
            let identityToken = cred.identityToken.flatMap { String(data: $0, encoding: .utf8) }
            // Apple returns the name only on the FIRST authorization, so it is nil on every later
            // sign-in — including the reinstall case this screen mostly serves. Empty is the honest
            // answer: `isPlaceholderName("")` is true, so FlowApp's post-sign-in hydrate refills the
            // real name from the user's own public record.
            //
            // This previously read `cred.email`, a scope the request above deliberately never asks for
            // (Flowe collects no email — see the App Privacy label). It was therefore ALWAYS nil, so
            // every login fell through to "member@flowe.app" and named the user "Member".
            let name = [cred.fullName?.givenName, cred.fullName?.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
            isSigningIn = true
            Task {
                let outcome = await session.startSignIn(
                    appleUserID: cred.user,
                    name: name,
                    email: cred.email ?? "",
                    desiredRole: role,
                    adoptExistingRole: adoptExistingRole,
                    identityToken: identityToken
                )
                isSigningIn = false
                if case .roleMismatch(let existing) = outcome {
                    errorMessage = AppSession.roleMismatchMessage(existing: existing)
                }
            }
        case .failure(let error):
            if (error as NSError).code == ASAuthorizationError.canceled.rawValue { return }
            errorMessage = "Apple Sign-In failed: \(error.localizedDescription)"
        }
    }
}
