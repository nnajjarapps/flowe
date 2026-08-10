import SwiftUI
import AuthenticationServices

/// Create an account. Sign in with Apple is the only path — see `LoginView` for why the
/// email/password form was removed rather than repaired.
struct CreateAccountView: View {
    let role: UserRole
    @Environment(AppSession.self) private var session

    @State private var errorMessage: String?
    /// App Store Guideline 1.2: a UGC-app user must affirmatively accept the Terms + Community
    /// Guidelines before an account is created. Sign in with Apple stays disabled until this is true.
    @State private var agreedToTerms = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FlowSpacing.xl) {
                VStack(alignment: .leading, spacing: FlowSpacing.xs) {
                    Text("Join flowe")
                        .flowFont(.displayMedium)
                        .foregroundStyle(Color.floweInk)
                        .italic()

                    Text("Start your Pilates journey today")
                        .flowFont(.bodyMedium)
                        .foregroundStyle(Color.floweMuted)
                }

                if let error = errorMessage {
                    Text(error)
                        .flowFont(.caption)
                        .foregroundStyle(Color.red)
                }

                TermsAcceptanceView(isAgreed: $agreedToTerms)

                SignInWithAppleButton(.signUp) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    handleApple(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 56)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .disabled(!agreedToTerms)
                .opacity(agreedToTerms ? 1 : 0.45)
                .accessibilityIdentifier("createAccount.apple")

                if !agreedToTerms {
                    Text("Please agree to the Terms and Community Guidelines to continue.")
                        .flowFont(.caption)
                        .foregroundStyle(Color.floweMuted)
                }

                Text("Flowe uses your Apple account so your sessions, messages and reviews stay "
                     + "with you across devices. You can hide your email, and we never see a password.")
                    .flowFont(.caption)
                    .foregroundStyle(Color.floweMuted)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: FlowSpacing.xs) {
                    Text("Already have an account?")
                        .flowFont(.bodyMedium)
                        .foregroundStyle(Color.floweMuted)
                    NavigationLink("Log in") {
                        LoginView(role: role)
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
        .navigationTitle("Create Account")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard let cred = auth.credential as? ASAuthorizationAppleIDCredential else {
                errorMessage = "Apple Sign-In didn't return an account. Please try again."
                return
            }
            // The Apple id must be recorded before the session starts — it is the owner id every booking,
            // message and review is filed under, AND the key the per-account terms acceptance is stored under.
            session.setAppleUserID(cred.user)
            // The user agreed on this screen (the button is disabled otherwise) — record it for THIS
            // account so the router's terms gate doesn't re-prompt them.
            session.recordTermsAcceptance()
            // Apple returns name and email only on the *first* authorization, so both are optional
            // on every later sign-in.
            let name = [cred.fullName?.givenName, cred.fullName?.familyName]
                .compactMap { $0 }
                .joined(separator: " ")
            session.signUp(
                name: name.isEmpty ? "Member" : name,
                email: cred.email ?? "",
                role: role
            )
        case .failure(let error):
            if (error as NSError).code == ASAuthorizationError.canceled.rawValue { return }
            errorMessage = "Apple Sign-In failed: \(error.localizedDescription)"
        }
    }
}

/// The App Store Guideline 1.2 acceptance gate for Flowe's user-generated content (community
/// discussions, messages, reviews, posts): the user must affirmatively agree to the Terms of Use,
/// Privacy Policy and Community Guidelines — the last carrying the zero-tolerance-for-objectionable-
/// content-and-abusive-users clause — before an account is created. Reused by the sign-up and (for a
/// not-yet-accepted user) the log-in screens. Sign in with Apple stays disabled until `isAgreed`.
struct TermsAcceptanceView: View {
    @Binding var isAgreed: Bool
    @State private var doc: LegalDoc?

    /// Flowe's Terms of Use = Apple's standard EULA (the same link used in Settings and the paywall).
    private let eula = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Button { isAgreed.toggle() } label: {
                    Image(systemName: isAgreed ? "checkmark.square.fill" : "square")
                        .font(.system(size: 20))
                        .foregroundStyle(isAgreed ? Color.flowePinkDeep : Color.floweMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("I agree to the Terms, Privacy Policy and Community Guidelines")
                .accessibilityValue(isAgreed ? "checked" : "unchecked")
                .accessibilityIdentifier("terms.checkbox")

                Text("I agree to Flowe's Terms of Use, Privacy Policy, and Community Guidelines — including zero tolerance for objectionable content and abusive behaviour.")
                    .flowFont(.caption)
                    .foregroundStyle(Color.floweMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture { isAgreed.toggle() }
            }
            HStack(spacing: 16) {
                Link("Terms of Use", destination: eula)
                Button("Privacy Policy") { doc = .privacy }
                Button("Community Guidelines") { doc = .guidelines }
            }
            .flowFont(.caption)
            .tint(Color.flowePinkDeep)
            .foregroundStyle(Color.flowePinkDeep)
            .padding(.leading, 30)
        }
        .sheet(item: $doc) { LegalDocumentView(resource: $0.resource, title: $0.title) }
        .accessibilityIdentifier("terms.gate")
    }
}
