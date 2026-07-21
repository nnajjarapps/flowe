import SwiftUI

/// Writes a community post. Deliberately plain: pick what kind of post it is, name the instructor
/// if it's about one, say the thing, publish.
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

    private var types: [PostType] { data.availablePostTypes }
    private var instructors: [Counterpart] { data.postableInstructors }

    private var selectedInstructor: Counterpart? {
        instructors.first { $0.id == instructorID } ?? instructors.first
    }

    private var canPost: Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
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
                    TextField("What's on your mind?", text: $text, axis: .vertical)
                        .lineLimit(4...10)
                        .font(FloweFont.sans(14))
                        .accessibilityIdentifier("compose.text")
                } footer: {
                    Text("Your name and your post are visible to everyone on Flowe.")
                }
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
            .alert("Check your post",
                   isPresented: .init(get: { filterMessage != nil },
                                      set: { if !$0 { filterMessage = nil } })) {
                Button("OK", role: .cancel) { filterMessage = nil }
            } message: {
                Text(filterMessage ?? "")
            }
        }
    }

    private func publish() {
        // A post is public content, so it gets the same screening as a public listing or a review.
        if let rejection = ContentFilter.reject(text) {
            filterMessage = rejection.message
            return
        }
        data.addPost(type: type, instructorName: selectedInstructor?.name, text: text)
        dismiss()
    }
}

#Preview {
    ComposePostSheet()
        .environment(MockDataStore.preview)
}
