import SwiftUI

/// A single Community feed post: header, optional instructor image band,
/// body text, optional tip banner, and the like / comment / save actions row.
struct PostRowView: View {
    @Environment(MockDataStore.self) private var data

    let post: FeedPost

    @State private var showComments = false
    @State private var showReport = false
    @State private var confirmDelete = false

    private var isMine: Bool { data.isMine(post) }

    private var subtitle: String {
        let action: String
        switch post.type {
        case .review:  action = "shouted out \(post.instructor ?? "")"
        case .checkin: action = "checked in with \(post.instructor ?? "")"
        case .tip:     action = "shared a tip"
        }
        return "\(action) · \(post.relativeTime)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                // `userImg` is only ever set for seeded listings; a real uploaded photo
                // lives in `Instructor.photo`, so resolve the author before falling back.
                AvatarView(id: post.userImg, photo: data.authorPhoto(for: post), size: 36)

                VStack(alignment: .leading, spacing: 1) {
                    Text(post.displayName)
                        .font(FloweFont.sans(13, .medium))
                        .foregroundStyle(Color.floweInk)
                    // The subtitle is assembled from user-entered names, so it stays a plain String;
                    // "Posting…" is real copy and is localized.
                    Group {
                        if post.pendingUpload { Text("Posting…") } else { Text(subtitle) }
                    }
                    .font(FloweFont.mono(11))
                    .foregroundStyle(Color.floweMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // A seeded preview row has no author to report or block, and no menu is better
                // than one offering actions that would go nowhere.
                if isMine || post.ownerID != nil { moderationMenu }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            // Instructor image band
            if let instImg = post.instImg {
                ZStack(alignment: .topTrailing) {
                    RemoteImage(id: instImg, width: 600, height: 280)
                        .frame(height: 140)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .overlay(FlowGradients.grad.opacity(0.5))

                    if let rating = post.rating {
                        HStack(spacing: 2) {
                            ForEach(0..<rating, id: \.self) { _ in
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            // Body text
            Text(post.text)
                .font(FloweFont.sans(13))
                .foregroundStyle(Color.floweInk)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            // Tip banner
            if post.type == .tip {
                HStack(spacing: 8) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.flowePinkDeep)
                    Text("Community Tip")
                        .font(FloweFont.sans(11, .medium))
                        .foregroundStyle(Color.flowePinkDeep)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.flowePink.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.flowePink.opacity(0.19), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            actions
        }
        .sheet(isPresented: $showComments) {
            PostCommentsSheet(post: post)
        }
        .sheet(isPresented: $showReport) {
            ReportSheet(
                reportedID: post.ownerID ?? "",
                reportedName: post.user,
                content: .communityPost,
                contentID: post.remoteID ?? "",
                snapshot: post.text
            )
        }
        .confirmationDialog("Delete this post?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { data.deletePost(post) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It disappears for everyone. This can't be undone.")
        }
    }

    // MARK: - Pieces

    /// Report/block for someone else's post, delete for the author's own. An author is the record's
    /// creator, which is the only reason the delete can work at all (see `CommunityService`).
    private var moderationMenu: some View {
        Menu {
            if isMine {
                Button("Delete Post", systemImage: "trash", role: .destructive) {
                    confirmDelete = true
                }
            } else {
                Button("Report Post", systemImage: "flag") { showReport = true }
                Button("Block \(post.displayName)", systemImage: "hand.raised", role: .destructive) {
                    data.block(id: post.ownerID ?? "", name: post.user)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16))
                .foregroundStyle(Color.floweMuted)
                .frame(width: 32, height: 32, alignment: .trailing)
        }
        .accessibilityIdentifier("post.moderation")
    }

    private var actions: some View {
        HStack(spacing: 16) {
            Button {
                data.toggleLike(post)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: post.liked ? "heart.fill" : "heart")
                        .font(.system(size: 17))
                        .foregroundStyle(post.liked ? Color.flowePink : Color.floweMuted)
                    Text("\(post.likes)")
                        .font(FloweFont.sans(12))
                        .foregroundStyle(post.liked ? Color.flowePink : Color.floweMuted)
                }
            }
            .accessibilityIdentifier("post.like")

            Button {
                showComments = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.floweMuted)
                    Text("\(post.comments)")
                        .font(FloweFont.sans(12))
                        .foregroundStyle(Color.floweMuted)
                }
            }
            .accessibilityIdentifier("post.comments")

            Spacer()

            Button {
                data.toggleSave(post)
            } label: {
                Image(systemName: post.saved ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 17))
                    .foregroundStyle(post.saved ? Color.flowePinkDeep : Color.floweMuted)
            }
            .accessibilityIdentifier("post.save")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }
}

#Preview {
    let store = MockDataStore.preview
    return ScrollView {
        VStack(spacing: 0) {
            ForEach(store.posts) { post in
                PostRowView(post: post)
                Divider()
            }
        }
    }
    .background(Color.flowWhite)
    .environment(store)
}
