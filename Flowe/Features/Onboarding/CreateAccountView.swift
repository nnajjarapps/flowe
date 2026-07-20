import SwiftUI
import AuthenticationServices

/// Create an account. Sign in with Apple is the only path — see `LoginView` for why the
/// email/password form was removed rather than repaired.
struct CreateAccountView: View {
    let role: UserRole
    @Environment(AppSession.self) private var session

    @State private var errorMessage: String?

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

                SignInWithAppleButton(.signUp) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    handleApple(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 56)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("createAccount.apple")

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
            // The Apple id must be recorded before the session starts — it is the owner id every
            // booking, message and review is filed under.
            session.setAppleUserID(cred.user)
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

#Preview {
    NavigationStack {
        CreateAccountView(role: .student)
            .environment(AppSession())
    }
}
