import SwiftUI
import PhotosUI

/// Writes a community post: a photo, a caption, or both, plus what kind of post it is.
///
/// A shout-out and a check-in name an instructor, and the picker only offers instructors this user
/// has actually had a session with — anyone able to name anyone would make the feed a place to
/// manufacture endorsements, which is exactly what anchoring reviews to bookings was meant to stop.
/// With no sessions behind them, a user can still write a tip.
struct ComposePostSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MockDataStore.self) private var data

    @State private var type: PostType = .tip
    @State private var instructorID: String = ""
    @State private var text = ""
    @State private var filterMessage: String?
    /// A soft on-device moderation concern (Flowe Intelligence) → "post anyway / edit?" dialog.
    @State private var moderationConcern: String?

    @State private var image: Data?
    @State private var pickerItem: PhotosPickerItem?
    @State private var isLoadingImage = false

    private var types: [PostType] { data.availablePostTypes }
    private var instructors: [Counterpart] { data.postableInstructors }

    private var selectedInstructor: Counterpart? {
        instructors.first { $0.id == instructorID } ?? instructors.first
    }

    /// A photo alone is a post, and so is a caption alone — only an entirely empty one isn't.
    private var canPost: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText || image != nil else { return false }
        return !type.needsInstructor || selectedInstructor != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Post type", selection: $type) {
                        ForEach(types) { Text($0.composerLabel).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("compose.type")
                } header: {
                    Text("What are you posting?")
                } footer: {
                    Text(LocalizedStringKey(types.count == 1
                         ? "Book a session to check in with an instructor or shout one out."
                         : "A tip stands on its own. A check-in or shout-out names your instructor."))
                }

                if type.needsInstructor {
                    Section {
                        Picker("Instructor", selection: $instructorID) {
                            ForEach(instructors) { Text($0.displayName).tag($0.id) }
                        }
                        .accessibilityIdentifier("compose.instructor")
                    } header: {
                        Text("Which instructor?")
                    } footer: {
                        Text(LocalizedStringKey(type == .review
                             ? "Star ratings live on your instructor's profile — leave one from Bookings."
                             : "Only instructors you've had a session with."))
                    }
                }

                Section {
                    photoRow
                } header: {
                    Text("Photo")
                } footer: {
                    Text("Optional. A photo on its own is a post — the caption can wait.")
                }

                Section {
                    TextField("What's on your mind?", text: $text, axis: .vertical)
                        .lineLimit(4...10)
                        .font(FloweFont.sans(14))
                        .accessibilityIdentifier("compose.text")
                } footer: {
                    Text("Your name, your photo and your post are visible to everyone on Flowe.")
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task { await load(item) }
            }
            .tint(Color.flowePinkDeep)
            .navigationTitle("New Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Color.floweMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") { publish() }
                        .disabled(!canPost)
                        .accessibilityIdentifier("compose.post")
                }
            }
            .onAppear {
                if let first = instructors.first, instructorID.isEmpty { instructorID = first.id }
            }
            .floweMessage(
                isPresented: .init(get: { filterMessage != nil },
                                   set: { if !$0 { filterMessage = nil } }),
                title: "Check your post",
                detail: filterMessage
            ) { filterMessage = nil }
            // Soft AI second pass: surfaces a concern but lets the author decide (the model can be wrong).
            // Soft AI pass: `moderationConcern` is a RUNTIME string from the model, so it goes
            // through `detail:` — as a LocalizedStringKey it would become a catalog lookup key.
            .floweDialog(
                isPresented: .init(get: { moderationConcern != nil },
                                   set: { if !$0 { moderationConcern = nil } }),
                titleText: Text("A quick check"),
                messageText: moderationConcern.map { Text(verbatim: $0) },
                actions: [
                    FloweDialogAction("Post anyway") {
                        moderationConcern = nil; finishPublish()
                    },
                    FloweDialogAction("Edit", role: .cancel) { moderationConcern = nil },
                ]
            )
        }
    }

    // MARK: - Photo

    @ViewBuilder
    private var photoRow: some View {
        if let image, let ui = UIImage(data: image) {
            // Shown at the shape it was taken in, matching how the feed row will render it, so the
            // author is choosing the picture they will actually see rather than a square preview.
            Image(uiImage: ui)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .listRowInsets(EdgeInsets())
                .padding(.vertical, 8)
        }

        HStack(spacing: 16) {
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Text(image == nil ? "Add Photo" : "Change Photo")
                    .font(FloweFont.sans(13, .medium))
                    .foregroundStyle(Color.flowePinkDeep)
            }
            .accessibilityIdentifier("compose.photoPicker")

            if image != nil {
                Button("Remove") {
                    image = nil
                    pickerItem = nil
                }
                .font(FloweFont.sans(13))
                .foregroundStyle(Color.floweMuted)
                .accessibilityIdentifier("compose.photoRemove")
            }

            if isLoadingImage {
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
        .buttonStyle(.plain)
    }

    private func load(_ item: PhotosPickerItem) async {
        isLoadingImage = true
        defer { isLoadingImage = false }
        // Downscaled before it is ever stored — see `ProfileImage.preparePost`. Every one of these
        // is an asset other people's phones download. A failed decode leaves the old choice alone.
        guard let raw = try? await item.loadTransferable(type: Data.self),
              let prepared = ProfileImage.preparePost(raw) else { return }
        image = prepared
    }

    private func publish() {
        // A post is public content, so it gets the same screening as a public listing or a review.
        // The photo is not screened — nothing here can look at an image — which is why an attached
        // one is reportable from the feed like any other content.
        if let rejection = ContentFilter.reject(text) {
            filterMessage = rejection.message
            return
        }
        // Non-AI devices (the majority) stay fully synchronous; only the on-device slice does the check.
        guard FloweAI.isAvailable else { finishPublish(); return }
        Task {
            if let concern = await FloweAI.moderationConcern(text) {
                moderationConcern = concern
                return
            }
            finishPublish()
        }
    }

    private func finishPublish() {
        data.addPost(type: type, instructorName: selectedInstructor?.name, text: text, image: image)
        dismiss()
    }
}
