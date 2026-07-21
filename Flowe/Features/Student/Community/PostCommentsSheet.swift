import SwiftUI

/// Replies on a community post: a scrolling list and a bottom composer, the same shape as a chat
/// thread. Replies live in the shared public database alongside the post (see `CommunityService`),
/// so both the author and every other reader see them.
struct PostCommentsSheet: View {
    let post: FeedPost

    @Environment(\.dismiss) private var dismiss
    @Environment(MockDataStore.self) private var data

    @State private var draft = ""
    @State private var filterMessage: String?
    @State private var reported: PostComment?

    private var comments: [PostComment] { data.comments(for: post) }

    /// A post that hasn't published yet has no id for a reply to hang off.
    private var isLive: Bool { post.remoteID != nil }

    private var canSend: Bool {
        isLive && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        original

                        if comments.isEmpty {
                            EmptyStateView(
                                icon: "bubble.left",
                                title: "No replies yet",
                                message: "Be the first to say something."
                            )
                            .padding(.top, 24)
                        } else {
                            ForEach(comments) { comment in
                                row(comment)
                                Divider().overlay(Color.floweBorder)
                            }
                        }
                    }
                }

                composer
            }
            .background(Color.flowWhite)
            .navigationTitle("Replies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.tint(Color.floweMuted)
                }
            }
            // Deliberately does NOT sync: `syncCommunity` can prune the very post this sheet
            // holds, and reading a deleted SwiftData model traps. The feed behind it already
            // syncs, and replies refresh through `data.comments(for:)`.
            .task { await data.syncComments(for: post) }
            .sheet(item: $reported) { comment in
                ReportSheet(
                    reportedID: comment.authorID,
                    reportedName: comment.authorName,
                    content: .communityComment,
                    contentID: comment.remoteID ?? "",
                    snapshot: comment.text
                )
            }
            .alert("Check your reply",
                   isPresented: .init(get: { filterMessage != nil },
                                      set: { if !$0 { filterMessage = nil } })) {
                Button("OK", role: .cancel) { filterMessage = nil }
            } message: {
                Text(filterMessage ?? "")
            }
        }
    }

    // MARK: - Pieces

    /// The post being replied to, so the sheet has context without going back.
    private var original: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(post.displayName)
                .font(FloweFont.sans(13, .medium))
                .foregroundStyle(Color.floweInk)
            Text(post.text)
                .font(FloweFont.sans(13))
                .foregroundStyle(Color.floweInk)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .floweCard()
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private func row(_ comment: PostComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(comment.displayName)
                        .font(FloweFont.sans(13, .medium))
                        .foregroundStyle(Color.floweInk)
                    // The stamp is a derived string, so it goes through Text(String) unlocalized;
                    // "Sending…" is real copy and must not.
                    Group {
                        if comment.pendingUpload { Text("Sending…") } else { Text(comment.relativeTime) }
                    }
                    .font(FloweFont.mono(10))
                    .foregroundStyle(Color.floweMuted)
                }
                Text(comment.text)
                    .font(FloweFont.sans(13))
                    .foregroundStyle(Color.floweInk)
                    .lineSpacing(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                if data.isMine(comment) {
                    Button("Delete Reply", systemImage: "trash", role: .destructive) {
                        data.deleteComment(comment)
                    }
                } else {
                    Button("Report Reply", systemImage: "flag") { reported = comment }
                    Button("Block \(comment.displayName)", systemImage: "hand.raised",
                           role: .destructive) {
                        data.block(id: comment.authorID, name: comment.authorName)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.floweMuted)
                    .frame(width: 28, height: 28)
            }
            .accessibilityIdentifier("comment.moderation")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if !isLive {
                Text("This post hasn't reached the community yet — replies open once it has.")
                    .font(FloweFont.sans(11))
                    .foregroundStyle(Color.floweMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                TextField("", text: $draft,
                          prompt: Text("Add a reply…").foregroundColor(Color.floweMuted),
                          axis: .vertical)
                    .font(FloweFont.sans(14))
                    .foregroundStyle(Color.floweInk)
                    .lineLimit(1...4)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.floweCardBg)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.floweBorder, lineWidth: 1))
                    .disabled(!isLive)
                    .accessibilityIdentifier("comment.field")

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(canSend ? AnyShapeStyle(FlowGradients.gradDark)
                                            : AnyShapeStyle(Color.flowePinkSoft))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityIdentifier("comment.send")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.flowWhite)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.floweBorder).frame(height: 1)
        }
    }

    private func send() {
        // A reply is public content, screened the same way a post or a listing is.
        if let rejection = ContentFilter.reject(draft) {
            filterMessage = rejection.message
            return
        }
        data.addComment(to: post, text: draft)
        draft = ""
    }
}

#Preview {
    let store = MockDataStore.preview
    return PostCommentsSheet(post: store.posts[0])
        .environment(store)
}
