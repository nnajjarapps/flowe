import SwiftUI

/// Messages inbox: a searchable list of conversations, shared by both roles. Each row shows the
/// counterpart's avatar and name, the last-message preview, when it arrived, and an unread dot.
/// Tapping pushes `ConversationView`.
///
/// Conversations are derived from real messages rather than from a list of instructors: a student's
/// counterpart is an instructor, but an instructor's counterpart is a student, who has no listing.
struct MessageListView: View {
    @Environment(MockDataStore.self) private var data
    @Environment(AppSession.self) private var session

    @State private var search = ""
    @State private var showCompose = false

    private var conversations: [ConversationSummary] { data.conversations }

    private var filtered: [ConversationSummary] {
        guard !search.isEmpty else { return conversations }
        let q = search.lowercased()
        return conversations.filter {
            $0.counterpart.displayName.lowercased().contains(q) ||
            $0.lastMessage.lowercased().contains(q)
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

                    ForEach(filtered) { summary in
                        NavigationLink {
                            ConversationView(counterpart: summary.counterpart)
                        } label: {
                            row(summary)
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Color.floweBorder).padding(.leading, 78)
                    }

                    if conversations.isEmpty {
                        EmptyStateView(
                            icon: "bubble.left.and.bubble.right",
                            title: "No messages yet",
                            message: "Conversations with your instructors and students will appear here."
                        )
                        .padding(.top, 60)
                    } else if filtered.isEmpty {
                        searchEmptyState
                    }
                }
            }
            .background(Color.flowWhite)
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .refreshable { await data.syncMessages() }
        }
        .task { await data.syncMessages() }
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
            .accessibilityIdentifier("messages.compose")
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

    private func row(_ summary: ConversationSummary) -> some View {
        HStack(spacing: 14) {
            AvatarView(id: summary.counterpart.avatarID, size: 50, ring: summary.hasUnread)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(summary.counterpart.displayName)
                        .font(FloweFont.serif(15))
                        .foregroundStyle(Color.floweInk)
                    Spacer()
                    Text(Self.relativeTime(summary.lastSentAt))
                        .font(FloweFont.mono(10))
                        .foregroundStyle(summary.hasUnread ? Color.flowePinkDeep : Color.floweMuted)
                }

                HStack(spacing: 8) {
                    Text(summary.lastMessage)
                        .font(FloweFont.sans(13, summary.hasUnread ? .medium : .regular))
                        .foregroundStyle(summary.hasUnread ? Color.floweInk : Color.floweMuted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if summary.hasUnread {
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

    /// "Now" / "4m" / "3h" / "Tue" / "12 Mar" — compact enough for the trailing slot.
    static func relativeTime(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "Now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        let formatter = DateFormatter()
        formatter.dateFormat = seconds < 7 * 86_400 ? "EEE" : "d MMM"
        return formatter.string(from: date)
    }

    private var searchEmptyState: some View {
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
