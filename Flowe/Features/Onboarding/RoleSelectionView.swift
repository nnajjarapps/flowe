import SwiftUI

struct RoleSelectionView: View {
    @State private var selectedRole: UserRole? = nil
    @State private var navigateToCreate = false
    @State private var navigateToLogin = false
    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: FlowSpacing.sm) {
                Text("Who are you\njoining as?")
                    .flowFont(.displayMedium)
                    .foregroundStyle(Color.floweInk)

                Text("Choose your role. You can change this later.")
                    .flowFont(.bodyMedium)
                    .foregroundStyle(Color.floweMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, FlowSpacing.xl)
            .padding(.top, FlowSpacing.xxl)
            .padding(.bottom, FlowSpacing.xl)

            // Role cards
            VStack(spacing: FlowSpacing.lg) {
                RoleCard(
                    tag: "Find & Book Classes",
                    title: "I'm here to train",
                    subtitle: "Discover certified instructors, book sessions, join classes and grow your Pilates practice.",
                    imageName: "figure.pilates",
                    tint: Color.flowePinkSoft,
                    isSelected: selectedRole == .student
                ) {
                    withAnimation(.spring(duration: 0.2)) { selectedRole = .student }
                }

                RoleCard(
                    tag: "Grow Your Practice",
                    title: "I'm here to teach",
                    subtitle: "List your services, manage bookings, create events and build your community on flowe.",
                    imageName: "figure.yoga",
                    tint: Color.flowePinkDeep,
                    isSelected: selectedRole == .instructor
                ) {
                    withAnimation(.spring(duration: 0.2)) { selectedRole = .instructor }
                }
            }
            .padding(.horizontal, FlowSpacing.xl)

            Spacer()

            // CTA
            VStack(spacing: FlowSpacing.md) {
                PrimaryButton(title: "Continue as \(selectedRole == .student ? "Student" : selectedRole == .instructor ? "Instructor" : "...")") {
                    navigateToCreate = true
                }
                .disabled(selectedRole == nil)
                .opacity(selectedRole == nil ? 0.5 : 1)

                Button("I already have an account") {
                    navigateToLogin = true
                }
                .flowFont(.bodyMedium)
                .foregroundStyle(Color.flowePinkDeep)
            }
            .padding(.horizontal, FlowSpacing.xl)
            .padding(.bottom, FlowSpacing.xxxl)

        }
        .floweBackground()
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToCreate) {
            CreateAccountView(role: selectedRole ?? .student)
        }
        .navigationDestination(isPresented: $navigateToLogin) {
            LoginView(role: selectedRole ?? .student)
        }
    }
}

private struct RoleCard: View {
    let tag: String
    let title: String
    let subtitle: String
    let imageName: String
    let tint: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 20)
                    .fill(tint.opacity(isSelected ? 1 : 0.55))
                    .frame(height: 160)

                if isSelected {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.flowePinkDeep, lineWidth: 2)
                        .frame(height: 160)
                }

                VStack(alignment: .leading, spacing: FlowSpacing.xs) {
                    Text(tag)
                        .flowFont(.label)
                        .foregroundStyle(Color.flowWhite.opacity(0.85))
                        .padding(.horizontal, FlowSpacing.sm)
                        .padding(.vertical, 3)
                        .background(Color.floweInk.opacity(0.3))
                        .clipShape(Capsule())

                    Text(title)
                        .flowFont(.titleLarge)
                        .foregroundStyle(Color.flowWhite)
                        .italic()

                    Text(subtitle)
                        .flowFont(.caption)
                        .foregroundStyle(Color.flowWhite.opacity(0.85))
                        .multilineTextAlignment(.leading)
                }
                .padding(FlowSpacing.lg)

                if isSelected {
                    HStack {
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Color.flowWhite)
                            .padding(FlowSpacing.lg)
                    }
                    .frame(height: 160, alignment: .top)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        RoleSelectionView()
            .environment(AppSession())
    }
}
