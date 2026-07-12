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
                        .foregroundStyle(Color.flowDarkBrown)
                        .italic()

                    Text("Start your Pilates journey today")
                        .flowFont(.bodyMedium)
                        .foregroundStyle(Color.flowTaupeGray)
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
                    Rectangle().fill(Color.flowWarmGray).frame(height: 1)
                    Text("or").flowFont(.caption).foregroundStyle(Color.flowTaupeGray)
                    Rectangle().fill(Color.flowWarmGray).frame(height: 1)
                }

                SignInWithAppleButton(.signUp) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    switch result {
                    case .success:
                        session.signUp(name: "Apple User", email: "apple@privaterelay.com", role: role)
                    case .failure:
                        errorMessage = "Apple Sign-In failed. Please try again."
                    }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                HStack(spacing: FlowSpacing.xs) {
                    Text("Already have an account?")
                        .flowFont(.bodyMedium)
                        .foregroundStyle(Color.flowTaupeGray)
                    NavigationLink("Log in") {
                        LoginView(role: role)
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
}

#Preview {
    NavigationStack {
        CreateAccountView(role: .student)
            .environment(AppSession())
    }
}
