import SwiftUI

/// App-wide settings hub — language + currency (applied across the whole app), notification
/// preferences, and sign-out. Shared by the student and instructor profiles.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(AppSession.self) private var session

    @State private var showNotifications = false
    @State private var showDeleteAccount = false

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
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppSettings())
        .environment(AppSession())
}
