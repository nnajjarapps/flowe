import SwiftUI

/// A conversation summary shown in the inbox list. `instructorId` links to a
/// real `Instructor` for the avatar and name.
struct Conversation: Identifiable {
    let id: Int
    let instructorId: Int
    let preview: String
    let time: String
    let unread: Bool
}

/// Messages inbox: a searchable list of conversations. Each row shows the
/// instructor avatar, name, last-message preview, time, and an unread dot.
/// Tapping pushes `ConversationView` inside a `NavigationStack`.
struct MessageListView: View {
    @Environment(MockDataStore.self) private var data

    @State private var search = ""
    @State private var showCompose = false

    /// Local mock inbox — maps to the first instructors in the store.
    private static let mockConversations: [Conversation] = [
        Conversation(id: 1, instructorId: 1, preview: "Perfect, we'll add some gentle mobility work at the start.", time: "9:20 AM", unread: true),
        Conversation(id: 2, instructorId: 2, preview: "You: See you at the tower session on Friday 💗", time: "Yesterday", unread: false),
        Conversation(id: 3, instructorId: 3, preview: "Loved your progress this month — really strong core work!", time: "Yesterday", unread: true),
        Conversation(id: 4, instructorId: 4, preview: "You: Thank you! That mat flow was exactly what I needed.", time: "Tue", unread: false),
        Conversation(id: 5, instructorId: 5, preview: "Here's the prenatal sequence we talked about 🌸", time: "Mon", unread: false),
    ]

    private var conversations: [(convo: Conversation, instructor: Instructor)] {
        Self.mockConversations.compactMap { convo in
            guard let ins = data.instructor(id: convo.instructorId) else { return nil }
            return (convo, ins)
        }
    }

    private var filtered: [(convo: Conversation, instructor: Instructor)] {
        guard !search.isEmpty else { return conversations }
        let q = search.lowercased()
        return conversations.filter {
            $0.instructor.name.lowercased().contains(q) ||
            $0.convo.preview.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    searchField
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                        .padding(.bottom, 12)

                    ForEach(filtered, id: \.convo.id) { item in
                        NavigationLink {
                            ConversationView(instructor: item.instructor)
                        } label: {
                            row(convo: item.convo, instructor: item.instructor)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Color.floweBorder).padding(.leading, 78)
                    }

                    if filtered.isEmpty {
                        emptyState
                    }
                }
            }
            .background(Color.flowWhite)
            .safeAreaInset(edge: .top, spacing: 0) { header }
        }
        .sheet(isPresented: $showCompose) { NewMessageSheet() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Messages")
                .font(FloweFont.serif(20))
                .foregroundStyle(Color.floweInk)
            Spacer()
            Button {
                showCompose = true
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(FlowGradients.gradDark)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.flowWhite)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.floweBorder).frame(height: 1)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(Color.floweMuted)
            TextField("", text: $search, prompt: Text("Search messages…").foregroundColor(Color.floweMuted))
                .font(FloweFont.sans(14))
                .foregroundStyle(Color.floweInk)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.floweMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.floweCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.floweBorder, lineWidth: 1))
    }

    // MARK: - Row

    private func row(convo: Conversation, instructor: Instructor) -> some View {
        HStack(spacing: 14) {
            AvatarView(id: instructor.img, size: 50, ring: convo.unread)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(instructor.name)
                        .font(FloweFont.serif(15))
                        .foregroundStyle(Color.floweInk)
                    Spacer()
                    Text(convo.time)
                        .font(FloweFont.mono(10))
                        .foregroundStyle(convo.unread ? Color.flowePinkDeep : Color.floweMuted)
                }

                HStack(spacing: 8) {
                    Text(convo.preview)
                        .font(FloweFont.sans(13, convo.unread ? .medium : .regular))
                        .foregroundStyle(convo.unread ? Color.floweInk : Color.floweMuted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if convo.unread {
                        Circle()
                            .fill(FlowGradients.gradDark)
                            .frame(width: 8, height: 8)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(Color.flowePinkSoft)
            Text("No messages found")
                .font(FloweFont.serif(17))
                .foregroundStyle(Color.floweInk)
            Text("Try a different name or keyword.")
                .font(FloweFont.sans(13))
                .foregroundStyle(Color.floweMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

#Preview {
    MessageListView()
        .environment(MockDataStore.preview)
        .environment(AppSettings())
        .environment(AppSession())
}
