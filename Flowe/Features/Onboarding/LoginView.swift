import SwiftUI
import AuthenticationServices

struct LoginView: View {
    let role: UserRole
    @Environment(AppSession.self) private var session

    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?

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

                VStack(spacing: FlowSpacing.md) {
                    FloatingLabelField(title: "Email Address", text: $email)
                    FloatingLabelField(title: "Password", text: $password, isSecure: true)
                }

                HStack {
                    Spacer()
                    Button("Forgot Password?") {}
                        .flowFont(.bodyMedium)
                        .foregroundStyle(Color.flowePinkDeep)
                }

                if let error = errorMessage {
                    Text(error)
                        .flowFont(.caption)
                        .foregroundStyle(Color.red)
                }

                PrimaryButton(title: "Log In") {
                    handleLogin()
                }

                HStack {
                    Rectangle().fill(Color.floweBorder).frame(height: 1)
                    Text("or").flowFont(.caption).foregroundStyle(Color.floweMuted)
                    Rectangle().fill(Color.floweBorder).frame(height: 1)
                }

                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    handleApple(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 56)
                .clipShape(RoundedRectangle(cornerRadius: 14))

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

    private func handleLogin() {
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "Please enter your email and password."
            return
        }
        session.login(email: email, role: role)
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            let cred = auth.credential as? ASAuthorizationAppleIDCredential
            if let userID = cred?.user { session.setAppleUserID(userID) }
            session.login(email: cred?.email ?? "member@flowe.app", role: role)
        case .failure(let error):
            if (error as NSError).code == ASAuthorizationError.canceled.rawValue { return }
            errorMessage = "Apple Sign-In failed: \(error.localizedDescription)"
        }
    }
}

#Preview {
    NavigationStack {
        LoginView(role: .student)
            .environment(AppSession())
    }
}
