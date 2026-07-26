import SwiftUI
import PhotosUI

/// A student's edit-profile sheet — the counterpart to the instructor's `EditProfileView`, pared
/// down to the fields a student actually owns: a profile photo, their display name, and a short bio.
///
/// A student has no public catalog listing, so there is nothing to republish. Saving updates the
/// signed-in `User` (persisted to UserDefaults by `AppSession`) and refreshes `currentUserName` on
/// the store, so the new name flows into the denormalised copy carried by their bookings, messages,
/// reviews, and community posts. The name and bio are screened before saving because the name is
/// broadcast into the public community feed alongside a student's posts (Guideline 1.2).
struct EditStudentProfileView: View {
    @Environment(AppSession.self) private var session
    @Environment(MockDataStore.self) private var data
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var bio = ""

    @State private var photo: Data?
    @State private var pickerItem: PhotosPickerItem?
    @State private var isLoadingPhoto = false

    @State private var loaded = false
    /// Non-nil when the content filter rejected a field on save.
    @State private var filterMessage: String?

    private var canSave: Bool { !name.trimmed.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FlowSpacing.xl) {
                    photoField

                    field(title: "NAME") {
                        textBox($name, placeholder: "Your name")
                            .accessibilityIdentifier("editStudentProfile.name")
                    }

                    field(title: "BIO") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextEditor(text: $bio)
                                .font(FloweFont.sans(14))
                                .foregroundStyle(Color.floweInk)
                                .frame(minHeight: 120)
                                .scrollContentBackground(.hidden)
                                .padding(10)
                                .boxed()
                                .accessibilityIdentifier("editStudentProfile.bio")
                            Text("A line about your practice. Shown on your profile.")
                                .font(FloweFont.sans(11))
                                .foregroundStyle(Color.floweMuted)
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.flowWhite.ignoresSafeArea())
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Color.floweMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .tint(Color.flowePinkDeep).fontWeight(.semibold)
                        .disabled(!canSave)
                        .accessibilityIdentifier("editStudentProfile.save")
                }
            }
        }
        .onAppear(perform: load)
        .task(id: pickerItem) { await loadPickedPhoto() }
        .alert("Check your profile",
               isPresented: .init(get: { filterMessage != nil },
                                  set: { if !$0 { filterMessage = nil } })) {
            Button("OK", role: .cancel) { filterMessage = nil }
        } message: {
            Text(filterMessage ?? "")
        }
    }

    // MARK: - Photo

    private var photoField: some View {
        VStack(spacing: 12) {
            ZStack {
                EditableAvatarView(id: "", photo: photo, size: 104)
                if isLoadingPhoto {
                    Circle().fill(.black.opacity(0.35)).frame(width: 104, height: 104)
                    ProgressView().tint(.white)
                }
            }

            HStack(spacing: 16) {
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    Text(photo == nil ? "Add Photo" : "Change Photo")
                        .font(FloweFont.sans(13, .medium))
                        .foregroundStyle(Color.flowePinkDeep)
                }
                .accessibilityIdentifier("editStudentProfile.photoPicker")

                if photo != nil {
                    Button("Remove") {
                        photo = nil
                        pickerItem = nil
                    }
                    .font(FloweFont.sans(13))
                    .tint(Color.floweMuted)
                    .accessibilityIdentifier("editStudentProfile.photoRemove")
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func loadPickedPhoto() async {
        guard let pickerItem else { return }
        isLoadingPhoto = true
        defer { isLoadingPhoto = false }
        // Downscale before storing — see `ProfileImage`. A failed decode leaves the old photo alone.
        guard let raw = try? await pickerItem.loadTransferable(type: Data.self),
              let prepared = ProfileImage.prepare(raw) else { return }
        photo = prepared
    }

    // MARK: - Load & save

    /// Seed the fields from the signed-in user, once. Guarded so a re-render mid-edit never clobbers
    /// what the person has typed.
    private func load() {
        guard !loaded else { return }
        loaded = true
        name = session.currentUser?.fullName ?? ""
        bio = session.currentUser?.bio ?? ""
        photo = session.currentUser?.photo
    }

    private func save() {
        // The display name rides along with every community post, comment, and review, so it is
        // screened before saving. Bio is shown on the profile header — screened alongside it.
        if let rejection = ContentFilter.reject(fields: [name, bio]) {
            filterMessage = rejection.message
            return
        }
        session.updateProfile(fullName: name, bio: bio, photo: .some(photo))
        // Refresh the denormalised name the store stamps onto new bookings/messages/posts/reviews.
        if let updated = session.currentUser?.fullName { data.currentUserName = updated }
        // Publish the public profile so instructors can see the student's photo/name/bio.
        data.saveStudentProfile(
            name: name,
            bio: bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : bio,
            photo: photo,
            memberSince: session.currentUser?.memberSince ?? Date()
        )
        dismiss()
    }

    // MARK: - Field helpers (mirrors EditProfileView's shared input surface)

    private func field<Content: View>(title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(text: title)
            content()
        }
    }

    private func textBox(_ text: Binding<String>, placeholder: LocalizedStringKey) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(Color.floweMuted))
            .font(FloweFont.sans(14))
            .foregroundStyle(Color.floweInk)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .boxed()
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

private extension View {
    /// The editor's shared input surface: card fill, rounded, hairline border.
    func boxed() -> some View {
        background(Color.floweCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.floweBorder, lineWidth: 1))
    }
}

#Preview {
    EditStudentProfileView()
        .environment(MockDataStore.preview)
        .environment(AppSession())
}
