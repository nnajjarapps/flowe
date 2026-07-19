import SwiftUI
import AuthenticationServices

struct CreateAccountView: View {
    let role: UserRole
    @Environment(AppSession.self) private var session

    @State private var fullName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
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

                VStack(spacing: FlowSpacing.md) {
                    FloatingLabelField(title: "Full Name", text: $fullName)
                    FloatingLabelField(title: "Email Address", text: $email)
                    FloatingLabelField(title: "Password", text: $password, isSecure: true)
                    FloatingLabelField(title: "Confirm Password", text: $confirmPassword, isSecure: true)
                }

                if let error = errorMessage {
                    Text(error)
                        .flowFont(.caption)
                        .foregroundStyle(Color.red)
                }

                PrimaryButton(title: "Create Account") {
                    handleCreate()
                }

                HStack {
                    Rectangle().fill(Color.floweBorder).frame(height: 1)
                    Text("or").flowFont(.caption).foregroundStyle(Color.floweMuted)
                    Rectangle().fill(Color.floweBorder).frame(height: 1)
                }

                SignInWithAppleButton(.signUp) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    handleApple(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 56)
                .clipShape(RoundedRectangle(cornerRadius: 14))

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

    private func handleCreate() {
        guard !fullName.isEmpty, !email.isEmpty, !password.isEmpty else {
            errorMessage = "Please fill in all fields."
            return
        }
        guard password == confirmPassword else {
            errorMessage = "Passwords do not match."
            return
        }
        session.signUp(name: fullName, email: email, role: role)
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            let cred = auth.credential as? ASAuthorizationAppleIDCredential
            if let userID = cred?.user { session.setAppleUserID(userID) }
            // Apple only returns name/email on the first authorization; fall back otherwise.
            let name = [cred?.fullName?.givenName, cred?.fullName?.familyName]
                .compactMap { $0 }.joined(separator: " ")
            session.signUp(
                name: name.isEmpty ? "Flowe Member" : name,
                email: cred?.email ?? "member@flowe.app",
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
