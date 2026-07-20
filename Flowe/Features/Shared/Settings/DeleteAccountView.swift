import SwiftUI

/// In-app account deletion, required by App Store Review Guideline 5.1.1(v).
///
/// Removes every record the user created in the shared store, wipes the local cache, and signs out.
///
/// Sign in with Apple cannot be revoked from inside the app — the REST revoke endpoint needs a
/// client-secret JWT that can't ship in a binary, and Flowe never retains the `authorizationCode`
/// needed to obtain a refresh token. Apple's TN3194 documents this exact case: delete the user's
/// data, then tell them how to revoke the credential themselves, which the footer below does.
struct DeleteAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MockDataStore.self) private var data
    @Environment(AppSession.self) private var session

    @State private var confirming = false
    @State private var isDeleting = false
    @State private var failed = false

    private var isInstructor: Bool { session.authState == .instructor }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(removedItems, id: \.self) { item in
                        Label(item, systemImage: "xmark.circle")
                            .font(FloweFont.sans(14))
                            .foregroundStyle(Color.floweInk)
                    }
                } header: {
                    Text("What gets deleted")
                } footer: {
                    Text("This is permanent and cannot be undone.")
                }

                Section {
                    Text("Messages other people sent you stay on their device, and stay owned by "
                         + "them — we can't remove those on your behalf.")
                        .font(FloweFont.sans(13))
                        .foregroundStyle(Color.floweMuted)
                }

                Section {
                    Button(role: .destructive) {
                        confirming = true
                    } label: {
                        HStack {
                            if isDeleting {
                                ProgressView().controlSize(.small)
                            }
                            Text(LocalizedStringKey(isDeleting ? "Deleting…" : "Delete Account"))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(isDeleting)
                    .accessibilityIdentifier("account.delete.confirm")
                } footer: {
                    Text("After deleting, open Settings › your name › Sign in with Apple › Flowe "
                         + "and choose Stop Using Apple ID to fully revoke Flowe's access.")
                }
            }
            .tint(Color.flowePinkDeep)
            .navigationTitle("Delete Account")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isDeleting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(Color.floweMuted)
                        .disabled(isDeleting)
                }
            }
            .confirmationDialog("Delete your Flowe account?",
                                isPresented: $confirming, titleVisibility: .visible) {
                Button("Delete Permanently", role: .destructive) { performDelete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes your data. It cannot be undone.")
            }
            .alert("Couldn't delete your account", isPresented: $failed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your account is unchanged. Check your connection and make sure you're "
                     + "signed in to iCloud, then try again.")
            }
        }
    }

    /// Phrased per role — a student has no listing, an instructor has no booking history as a client.
    private var removedItems: [String] {
        var items = ["Your profile and account details"]
        items.append(isInstructor ? "Your public instructor listing" : "Your bookings")
        if isInstructor { items.append("Your session requests and responses") }
        items.append("Messages you sent")
        return items
    }

    private func performDelete() {
        isDeleting = true
        Task {
            let erased = await data.deleteAccount()
            isDeleting = false
            guard erased else { return failed = true }
            dismiss()
            session.deleteAccount()
        }
    }
}

#Preview {
    DeleteAccountView()
        .environment(MockDataStore.preview)
        .environment(AppSession())
}
