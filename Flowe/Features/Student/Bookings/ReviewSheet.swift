import SwiftUI

/// Write or edit the review for a completed session.
///
/// Reviews are public and permanent-ish, so the sheet is deliberately plain: pick stars, say why,
/// submit. A review is anchored to this booking, so a student can only write one per session they
/// actually took.
struct ReviewSheet: View {
    let booking: Booking

    @Environment(\.dismiss) private var dismiss
    @Environment(MockDataStore.self) private var data

    @State private var rating = 0
    @State private var text = ""
    @State private var loaded = false
    @State private var filterMessage: String?
    /// ✨ Review-writing assist in flight (Flowe Intelligence).
    @State private var drafting = false

    private var instructorName: String {
        data.instructor(id: booking.instructorId)?.firstName ?? "your instructor"
    }

    private var isEditing: Bool { data.myReview(for: booking) != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    starPicker
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                } header: {
                    Text("How was your session with \(instructorName)?")
                } footer: {
                    Text(LocalizedStringKey(rating == 0 ? "Tap a star to rate." : Self.ratingLabel(rating)))
                }

                Section {
                    TextField("What stood out? (optional)", text: $text, axis: .vertical)
                        .lineLimit(4...8)
                        .font(FloweFont.sans(14))
                        .accessibilityIdentifier("review.text")
                    // ✨ On-device draft, grounded in the chosen rating. Needs a rating first (it anchors
                    // the sentiment) and the model available; otherwise absent. Polishes rough words or
                    // drafts from scratch — the student edits before posting.
                    if FloweAI.isAvailable, rating > 0 {
                        Button {
                            draftReview()
                        } label: {
                            HStack(spacing: 6) {
                                if drafting {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "sparkles")
                                }
                                Text(drafting ? "Writing…"
                                     : (text.trimmingCharacters(in: .whitespaces).isEmpty ? "Help me write this" : "Polish my words"))
                            }
                            .foregroundStyle(Color.flowePinkDeep)
                        }
                        .disabled(drafting)
                        .accessibilityIdentifier("review.aiDraft")
                    }
                } header: {
                    HStack {
                        Text("Your review")
                        Spacer()
                        if FloweAI.isAvailable { AIPrivacyBadge() }
                    }
                } footer: {
                    Text("Your first name and review are shown publicly on \(instructorName)'s profile.")
                }

                Section {
                    Button {
                        submit()
                    } label: {
                        Text(LocalizedStringKey(isEditing ? "Update Review" : "Post Review"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(rating == 0)
                    .accessibilityIdentifier("review.submit")
                }
            }
            .tint(Color.flowePinkDeep)
            .navigationTitle(isEditing ? "Edit Review" : "Leave a Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Color.floweMuted)
                }
            }
            .onAppear(perform: load)
            .floweMessage(
                isPresented: .init(get: { filterMessage != nil },
                                   set: { if !$0 { filterMessage = nil } }),
                title: "Check your review",
                detail: filterMessage
            ) { filterMessage = nil }
        }
    }

    private var starPicker: some View {
        HStack(spacing: 10) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    rating = star
                } label: {
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.system(size: 28))
                        .foregroundStyle(star <= rating ? Color.flowePinkDeep : Color.flowePinkSoft)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("review.star.\(star)")
                .accessibilityLabel(Text("\(star) stars"))
            }
        }
    }

    static func ratingLabel(_ rating: Int) -> String {
        switch rating {
        case 1:  return "Poor"
        case 2:  return "Below average"
        case 3:  return "Good"
        case 4:  return "Great"
        default: return "Excellent"
        }
    }

    private func load() {
        guard !loaded else { return }
        if let existing = data.myReview(for: booking) {
            rating = existing.rating
            text = existing.text
        }
        loaded = true
    }

    /// Draft/polish the review on-device from the rating (+ any rough notes). Fills `text` to edit.
    private func draftReview() {
        guard !drafting, rating > 0 else { return }
        drafting = true
        Task {
            defer { drafting = false }
            if #available(iOS 26, *), FloweAI.isAvailable,
               let draft = try? await FloweIntelligence.shared.draftReview(
                    rating: rating, instructor: instructorName,
                    sessionType: booking.type, notes: text) {
                withAnimation { text = draft }
                Haptic.selection()
            }
        }
    }

    private func submit() {
        // A review is public content, so it gets the same screening as a public listing.
        if let rejection = ContentFilter.reject(text) {
            filterMessage = rejection.message
            return
        }
        // `submitReview` returns nil when the booking can't actually be reviewed — it hasn't synced to
        // the cloud yet (no `remoteID`), or it isn't this signed-in student's own completed session.
        // Surface that instead of dismissing on a silent no-op that reads as success but saves nothing.
        guard data.submitReview(for: booking, rating: rating, text: text) != nil else {
            filterMessage = String(localized: "This session can't be reviewed yet. Give it a moment to sync, then try again.")
            return
        }
        Haptic.selection()
        dismiss()
    }
}
