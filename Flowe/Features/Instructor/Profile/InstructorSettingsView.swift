import SwiftUI
import StoreKit

/// Instructor settings — a proper grouped settings screen (replaces the old action-sheet popup).
/// Categories: Profile · Visibility & Plan · Preferences · Support · Account.
struct InstructorSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(AppSession.self) private var session
    @Environment(SubscriptionService.self) private var subscription

    @State private var showEditProfile = false
    @State private var showAvailability = false
    @State private var showShare = false
    @State private var showOutOfStudio = false
    @State private var showPaywall = false
    @State private var showNotifications = false
    @State private var showManageSubscriptions = false
    @State private var confirmLogout = false
    @State private var showDeleteAccount = false
    @State private var showBlocked = false
    @State private var legalDoc: LegalDoc?

    private var planLabel: String {
        switch subscription.tier {
        case .boost:   return "Boost"
        case .visible: return "Visible"
        case nil:      return "Not subscribed"
        }
    }

    private var planColor: Color {
        subscription.isVisible ? .floweSuccess : .floweMuted
    }

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                // MARK: Profile
                Section("Profile") {
                    button("Edit Profile", icon: "person.crop.circle") { showEditProfile = true }
                    button("Availability", icon: "calendar.badge.clock") { showAvailability = true }
                    // Handing a session to another instructor is only meaningful for a bookable listing —
                    // a hidden instructor has no students to cover for and can't be found as cover either.
                    // Gated on visibility for the same reason hosting an event is.
                    if subscription.isVisible {
                        button("Out of Studio", icon: "airplane") { showOutOfStudio = true }
                        // A link to a hidden listing resolves to nothing (no catalog record exists
                        // yet), so gate sharing on visibility like Out of Studio above.
                        button("Share my profile", icon: "square.and.arrow.up") { showShare = true }
                    }
                }

                // MARK: Visibility & plan
                Section {
                    Button {
                        showPaywall = true
                    } label: {
                        HStack {
                            Label("Get Discovered", systemImage: "sparkles")
                            Spacer()
                            Text(planLabel)
                                .font(FloweFont.mono(11))
                                .foregroundStyle(planColor)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.floweMuted)
                        }
                    }
                    .tint(Color.floweInk)

                    if subscription.isVisible {
                        button("Manage Subscription", icon: "creditcard") { showManageSubscriptions = true }
                    }
                } header: {
                    Text("Visibility & Plan")
                } footer: {
                    Text(subscription.isVisible
                         ? "Your profile is discoverable by students."
                         : "Subscribe so students can find and book you.")
                }

                // MARK: Preferences
                Section("Preferences") {
                    Picker(selection: $settings.language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    } label: {
                        Label("Language", systemImage: "globe")
                    }

                    button("Notifications", icon: "bell") { showNotifications = true }
                }

                // MARK: Safety
                Section("Safety") {
                    button("Blocked users", icon: "hand.raised") { showBlocked = true }
                        .accessibilityIdentifier("settings.blockedUsers")
                }

                // MARK: Support
                Section("Support") {
                    // Help & Support and the Privacy Policy open the documents bundled IN the app
                    // (see LegalDocumentView), not an external site, so they work offline and never
                    // dump the user into Safari. Terms of Use stays Apple's standard EULA — the App
                    // Store requires that link for the auto-renewing subscription.
                    Button { legalDoc = .support } label: {
                        Label("Help & Support", systemImage: "questionmark.circle")
                    }
                    .tint(Color.floweInk)
                    .accessibilityIdentifier("settings.help")
                    Button { legalDoc = .privacy } label: {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                    .tint(Color.floweInk)
                    .accessibilityIdentifier("settings.privacy")
                    Button { legalDoc = .guidelines } label: {
                        Label("Community Guidelines", systemImage: "person.2")
                    }
                    .tint(Color.floweInk)
                    .accessibilityIdentifier("settings.guidelines")
                    Link(destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!) {
                        Label("Terms of Use", systemImage: "doc.text")
                    }
                }

                // MARK: Account
                Section {
                    Button(role: .destructive) {
                        confirmLogout = true
                    } label: {
                        Text("Log Out").frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button(role: .destructive) {
                        showDeleteAccount = true
                    } label: {
                        Text("Delete Account").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("account.delete")
                } footer: {
                    if let email = session.currentUser?.email, !email.isEmpty {
                        Text("Signed in as \(email)")
                    }
                }
            }
            .tint(Color.flowePinkDeep)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .tint(Color.flowePinkDeep)
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showEditProfile) { EditProfileView() }
            .sheet(isPresented: $showAvailability) { AvailabilityView() }
            .sheet(isPresented: $showShare) { ShareProfileSheet() }
            .sheet(isPresented: $showOutOfStudio) { OutOfStudioView() }
            .sheet(isPresented: $showPaywall) { PaywallView() }
            .sheet(isPresented: $showNotifications) { NotificationSettingsView() }
            .sheet(isPresented: $showDeleteAccount) { DeleteAccountView() }
            .sheet(isPresented: $showBlocked) { BlockedUsersView() }
            .sheet(item: $legalDoc) { LegalDocumentView(resource: $0.resource, title: $0.title) }
            .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
            .confirmationDialog("Log out of Flowe?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Log Out", role: .destructive) {
                    dismiss()
                    session.logout()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func button(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.floweMuted)
            }
        }
        .tint(Color.floweInk)
    }
}
