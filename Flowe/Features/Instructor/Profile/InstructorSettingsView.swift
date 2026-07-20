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
    @State private var showPaywall = false
    @State private var showNotifications = false
    @State private var showManageSubscriptions = false
    @State private var confirmLogout = false

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

                    Picker(selection: $settings.currency) {
                        ForEach(Currency.allCases) { currency in
                            Text("\(currency.code) · \(currency.name)").tag(currency)
                        }
                    } label: {
                        Label("Currency", systemImage: "coloncurrencysign.circle")
                    }

                    button("Notifications", icon: "bell") { showNotifications = true }
                }

                // MARK: Support
                Section("Support") {
                    Link(destination: URL(string: "https://flowepilates.com/support")!) {
                        Label("Help & Support", systemImage: "questionmark.circle")
                    }
                    Link(destination: URL(string: "https://flowepilates.com/privacy")!) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
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
            .sheet(isPresented: $showPaywall) { PaywallView() }
            .sheet(isPresented: $showNotifications) { NotificationSettingsView() }
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

#Preview {
    InstructorSettingsView()
        .environment(AppSettings())
        .environment(AppSession())
        .environment(SubscriptionService())
        .environment(MockDataStore.preview)
}
