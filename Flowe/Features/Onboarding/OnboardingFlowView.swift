import SwiftUI

struct OnboardingFlowView: View {
    @Environment(AppSession.self) private var session
    @State private var showRoleSelection = false

    var body: some View {
        NavigationStack {
            if showRoleSelection {
                RoleSelectionView()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                WelcomeView(
                    onGetStarted: { advance() },
                    onSignIn: { advance() },
                    onBrowse: { session.enterGuest() }   // 5.1.1(v): browse Discover without an account
                )
                .transition(.opacity)
            }
        }
    }

    private func advance() {
        withAnimation(.spring(duration: 0.4, bounce: 0.1)) {
            showRoleSelection = true
        }
    }
}

// MARK: - Guest sign-in (App Store 5.1.1(v))

/// The sign-in prompt a guest sees when they tap an account action or open a walled tab. Reuses the real
/// Sign-in-with-Apple + terms flow, defaulting to the student role (a browsing guest is implicitly a
/// student). `adoptExistingRole: true` means a guest whose Apple ID is actually an INSTRUCTOR is signed
/// into their instructor account (not blocked by the role guard) — `AppRouter` then renders the correct
/// shell. On success `startSession` clears `isGuest` and this sheet goes away with the shell swap.
struct GuestSignInSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CreateAccountView(role: .student, adoptExistingRole: true)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Not now") { dismiss() }.tint(Color.floweMuted)
                    }
                }
        }
    }
}

/// A full-tab placeholder shown to a guest in place of an account-only tab (Bookings, Messages,
/// Community, Profile). Explains what signing in unlocks and offers the sign-in prompt.
struct GuestSignInWall: View {
    let icon: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @State private var showSignIn = false

    var body: some View {
        EmptyStateView(icon: icon, title: title, message: message, actionTitle: "Sign in") {
            showSignIn = true
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.flowWhite)
        .sheet(isPresented: $showSignIn) { GuestSignInSheet() }
    }
}
