import SwiftUI

/// App-wide settings hub — language + currency (applied across the whole app), notification
/// preferences, and sign-out. Shared by the student and instructor profiles.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(AppSession.self) private var session

    @State private var showNotifications = false
    @State private var showDeleteAccount = false
    @State private var showBlocked = false
    @State private var showSwitchRole = false
    @State private var switching = false
    @State private var legalDoc: LegalDoc?

    private var isInstructor: Bool { session.authState == .instructor }

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Preferences") {
                    Picker(selection: $settings.language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    } label: {
                        Label("Language", systemImage: "globe")
                    }
                }

                Section("Notifications") {
                    Button {
                        showNotifications = true
                    } label: {
                        HStack {
                            Label("Notification settings", systemImage: "bell")
                            Spacer()
                            Image(systemName: "chevron.forward")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.floweMuted)
                        }
                    }
                    .tint(Color.floweInk)
                }

                Section("Safety") {
                    Button {
                        showBlocked = true
                    } label: {
                        HStack {
                            Label("Blocked users", systemImage: "hand.raised")
                            Spacer()
                            Image(systemName: "chevron.forward")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.floweMuted)
                        }
                    }
                    .tint(Color.floweInk)
                    .accessibilityIdentifier("settings.blockedUsers")
                }

                // Both roles need a support + privacy path; these open the documents bundled in the
                // app (LegalDocumentView), not an external site.
                Section("Support") {
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
                }

                // One Apple ID acts as ONE role at a time, but the account can deliberately switch. The
                // change is account-wide (updates the shared claim), so every signed-in device follows —
                // this is the sanctioned alternative to signing a second device in as the other role,
                // which would corrupt the shared private database. See AccountRoleService.
                Section("Account type") {
                    Button {
                        showSwitchRole = true
                    } label: {
                        HStack {
                            Label(isInstructor ? "Switch to student account" : "Switch to instructor account",
                                  systemImage: "arrow.2.squarepath")
                            Spacer()
                            if switching { ProgressView() }
                        }
                    }
                    .tint(Color.floweInk)
                    .disabled(switching)
                    .accessibilityIdentifier("settings.switchRole")
                }

                Section {
                    Button(role: .destructive) {
                        session.logout()
                    } label: {
                        Text("Log out")
                    }

                    Button(role: .destructive) {
                        showDeleteAccount = true
                    } label: {
                        Text("Delete Account")
                    }
                    .accessibilityIdentifier("account.delete")
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
            .sheet(isPresented: $showNotifications) { NotificationSettingsView() }
            .sheet(isPresented: $showDeleteAccount) { DeleteAccountView() }
            .sheet(isPresented: $showBlocked) { BlockedUsersView() }
            .sheet(item: $legalDoc) { LegalDocumentView(resource: $0.resource, title: $0.title) }
            .confirmationDialog("Switch account type?",
                                isPresented: $showSwitchRole, titleVisibility: .visible) {
                Button(isInstructor ? "Become a student" : "Become an instructor") {
                    switching = true
                    Task {
                        await session.switchRole()
                        switching = false
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your Flowe account acts as one role at a time. Switching changes it on all your devices — your data is kept and comes back if you switch again.")
            }
        }
    }
}
