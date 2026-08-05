import SwiftUI

/// A single peer recommendation on an instructor profile: the author (a fellow instructor), when it was
/// written, and the endorsement body. The Flowe Pro counterpart to `ReviewRow` — see [[FlowePro]].
struct RecommendationRow: View {
    @Environment(MockDataStore.self) private var data

    let recommendation: InstructorRecommendation

    /// The author's cached listing (they're an instructor) — for their live name + photo. Nil when the
    /// viewer hasn't cached them, in which case the denormalised `fromName` + a monogram stand in.
    private var author: Instructor? { data.instructor(ownerID: recommendation.fromID) }
    private var authorName: String {
        let live = author?.name ?? ""
        return live.isEmpty ? recommendation.displayName : live
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                // The author is a fellow instructor — show their listing photo when we have it, else a monogram.
                if let author, author.photo != nil || !author.img.isEmpty {
                    AvatarView(id: author.img, photo: author.photo, size: 40)
                } else {
                    InitialAvatar(name: authorName, size: 40)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(authorName)
                        .font(FloweFont.serif(15, .medium))
                        .foregroundStyle(Color.floweInk)
                    // The "INSTRUCTOR" tag is the whole point — it's a *peer* endorsement, not a student review.
                    Text("INSTRUCTOR · \(recommendation.relativeTime)")
                        .font(FloweFont.mono(9))
                        .foregroundStyle(Color.floweMuted)
                }

                Spacer(minLength: 0)

                Image(systemName: "quote.closing")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.flowePink.opacity(0.5))
            }

            if !recommendation.text.isEmpty {
                Text(recommendation.text)
                    .font(FloweFont.sans(13))
                    .foregroundStyle(Color.floweInk.opacity(0.85))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floweCard(cornerRadius: 16)
    }
}

/// Write, edit, or remove a peer recommendation of another instructor. Reached from a DM thread with a
/// fellow instructor (the ⋯ menu). Public content, so it's content-screened like any listing. The store
/// guards self-recommendation + non-instructor authors; this is the composer. See [[FlowePro]].
struct RecommendationComposeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MockDataStore.self) private var data

    /// Recipient — the instructor being recommended.
    let toID: String
    let toName: String

    @State private var text = ""
    @State private var filterMessage: String?
    @State private var confirmDelete = false
    /// Soft on-device moderation concern (Flowe Intelligence) → "post anyway / edit?" dialog.
    @State private var moderationConcern: String?

    private var existing: InstructorRecommendation? { data.myRecommendation(for: toID) }
    private var canSave: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var firstName: String { toName.split(separator: " ").first.map(String.init) ?? toName }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What makes \(firstName) great to work with?", text: $text, axis: .vertical)
                        .lineLimit(4...10)
                } header: {
                    Text("Your recommendation")
                } footer: {
                    Text("Shown publicly on \(firstName)'s profile as a peer endorsement, with your name.")
                }

                if existing != nil {
                    Section {
                        Button("Remove recommendation", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .tint(Color.flowePinkDeep)
            .navigationTitle(existing == nil ? "Recommend \(firstName)" : "Edit recommendation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Color.floweMuted)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Post" : "Save") { save() }.disabled(!canSave)
                        .accessibilityIdentifier("recommendation.post")
                }
            }
            .alert("Check your recommendation",
                   isPresented: .init(get: { filterMessage != nil }, set: { if !$0 { filterMessage = nil } })) {
                Button("OK", role: .cancel) { filterMessage = nil }
            } message: {
                Text(filterMessage ?? "")
            }
            .confirmationDialog("Remove your recommendation?", isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) { data.deleteRecommendation(to: toID); dismiss() }
                Button("Keep it", role: .cancel) {}
            }
            .confirmationDialog("A quick check",
                                isPresented: .init(get: { moderationConcern != nil },
                                                   set: { if !$0 { moderationConcern = nil } }),
                                titleVisibility: .visible,
                                presenting: moderationConcern) { _ in
                Button("Post anyway") { moderationConcern = nil; finishSave() }
                Button("Edit", role: .cancel) { moderationConcern = nil }
            } message: { concern in
                Text(concern)
            }
            // Prefill when editing an existing recommendation.
            .onAppear { if let existing { text = existing.text } }
        }
    }

    private func save() {
        // Public content, screened like a listing (Guideline 1.2).
        if let rejection = ContentFilter.reject(text) {
            filterMessage = rejection.message
            return
        }
        guard FloweAI.isAvailable else { finishSave(); return }
        Task {
            if let concern = await FloweAI.moderationConcern(text) {
                moderationConcern = concern
                return
            }
            finishSave()
        }
    }

    private func finishSave() {
        data.writeRecommendation(to: toID, text: text)
        dismiss()
    }
}
