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
                        .foregroundStyle(Color.flowDarkBrown)

                    Text("Log in to continue your journey")
                        .flowFont(.bodyMedium)
                        .foregroundStyle(Color.flowTaupeGray)
                }

                VStack(spacing: FlowSpacing.md) {
                    FloatingLabelField(title: "Email Address", text: $email)
                    FloatingLabelField(title: "Password", text: $password, isSecure: true)
                }

                HStack {
                    Spacer()
                    Button("Forgot Password?") {}
                        .flowFont(.bodyMedium)
                        .foregroundStyle(Color.flowDustyRose)
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
                    Rectangle().fill(Color.flowWarmGray).frame(height: 1)
                    Text("or").flowFont(.caption).foregroundStyle(Color.flowTaupeGray)
                    Rectangle().fill(Color.flowWarmGray).frame(height: 1)
                }

                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    switch result {
                    case .success:
                        session.login(email: "apple@privaterelay.com", role: role)
                    case .failure:
                        errorMessage = "Apple Sign-In failed. Please try again."
                    }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                HStack(spacing: FlowSpacing.xs) {
                    Text("Not a member?")
                        .flowFont(.bodyMedium)
                        .foregroundStyle(Color.flowTaupeGray)
                    NavigationLink("Join now") {
                        CreateAccountView(role: role)
                    }
                    .flowFont(.bodyMedium)
                    .foregroundStyle(Color.flowDustyRose)
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
}

#Preview {
    NavigationStack {
        LoginView(role: .student)
            .environment(AppSession())
    }
}
