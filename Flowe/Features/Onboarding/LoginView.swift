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
    @Environment(AppSession.self) private var session

    @State private var errorMessage: String?
    /// Only a user who has NOT yet accepted the current Terms + Community Guidelines is gated here
    /// (closes the "Log in" bypass for a brand-new user); a returning user who already accepted sees
    /// no extra friction. App Store Guideline 1.2.
    @State private var agreedToTerms = false
    private var canProceed: Bool { session.hasAcceptedTerms || agreedToTerms }

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

                if !session.hasAcceptedTerms {
                    TermsAcceptanceView(isAgreed: $agreedToTerms)
                }

                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    handleApple(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 56)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .disabled(!canProceed)
                .opacity(canProceed ? 1 : 0.45)
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
                        CreateAccountView(role: role)
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
            // A first-time user reaching account creation via this screen agreed here; persist it.
            if !session.hasAcceptedTerms { session.recordTermsAcceptance() }
            // Record the Apple id *before* starting the session: it is the owner id every booking,
            // message and review is filed under, and a session without it would own nothing.
            session.setAppleUserID(cred.user)
            session.login(email: cred.email ?? "member@flowe.app", role: role)
        case .failure(let error):
            if (error as NSError).code == ASAuthorizationError.canceled.rawValue { return }
            errorMessage = "Apple Sign-In failed: \(error.localizedDescription)"
        }
    }
}
