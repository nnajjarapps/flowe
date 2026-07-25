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
    @State private var legalDoc: LegalDoc?

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

                    Picker(selection: $settings.currency) {
                        ForEach(Currency.allCases) { currency in
                            Text("\(currency.code) · \(currency.name)").tag(currency)
                        }
                    } label: {
                        Label("Currency", systemImage: "coloncurrencysign.circle")
                    }
                }

                Section("Notifications") {
                    Button {
                        showNotifications = true
                    } label: {
                        HStack {
                            Label("Notification settings", systemImage: "bell")
                            Spacer()
                            Image(systemName: "chevron.right")
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
                            Image(systemName: "chevron.right")
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
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppSettings())
        .environment(AppSession())
}
