import SwiftUI

/// "New message" composer — pick a recipient to start a thread. Tapping one pushes the
/// conversation inside this sheet's own navigation stack.
///
/// Who you can write to depends on your role: a student writes to instructors they can see in the
/// feed, an instructor writes to students who have booked them.
struct NewMessageSheet: View {
    @Environment(MockDataStore.self) private var data
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""

    private var people: [Counterpart] {
        data.addressBook(asInstructor: session.authState == .instructor)
    }

    private var results: [Counterpart] {
        guard !search.isEmpty else { return people }
        let q = search.lowercased()
        return people.filter { $0.displayName.lowercased().contains(q) }
    }

    private var emptyMessage: LocalizedStringKey {
        session.authState == .instructor
            ? "Students who book a session with you will appear here."
            : "Instructors you can book will appear here."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { person in
                        NavigationLink {
                            ConversationView(counterpart: person)
                        } label: {
                            row(person)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Color.floweBorder).padding(.leading, 74)
                    }

                    if people.isEmpty {
                        EmptyStateView(
                            icon: "person.2",
                            title: "No one to message yet",
                            message: emptyMessage
                        )
                        .padding(.top, 60)
                    }
                }
                .padding(.top, 4)
            }
            .background(Color.flowWhite.ignoresSafeArea())
            .searchable(text: $search, prompt: "Search people")
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Color.floweMuted)
                }
            }
        }
    }

    private func row(_ person: Counterpart) -> some View {
        HStack(spacing: 14) {
            AvatarView(id: person.avatarID, size: 46)
            Text(person.displayName)
                .font(FloweFont.serif(15))
                .foregroundStyle(Color.floweInk)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13))
                .foregroundStyle(Color.floweMuted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

#Preview {
    NewMessageSheet()
        .environment(MockDataStore.preview)
        .environment(AppSettings())
        .environment(AppSession())
}
