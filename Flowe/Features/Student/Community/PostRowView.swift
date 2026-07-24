import SwiftUI
import UIKit

/// A single Community feed post, laid out the way a photo feed is: author, the photo full-bleed,
/// then the actions, the like count and the caption underneath it.
///
/// The photo is the subject and everything else is annotation, so it is the only element that runs
/// edge to edge. A post without one is still a post — tips usually are — and then the caption
/// carries the row on its own, set larger, because a paragraph indented under an absent image reads
/// like something failed to load.
struct PostRowView: View {
    @Environment(MockDataStore.self) private var data

    let post: FeedPost

    @State private var showComments = false
    @State private var showReport = false
    @State private var confirmDelete = false

    private var isMine: Bool { data.isMine(post) }

    private var hasPhoto: Bool { post.image != nil }

    private var subtitle: String {
        let action: String
        switch post.type {
        case .review:  action = "shouted out \(post.instructor ?? "")"
        case .checkin: action = "checked in with \(post.instructor ?? "")"
        case .tip:     action = "shared a tip"
        }
        return action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            photo
            actions
            likeCount
            caption
            commentsLink
            timestamp
        }
        .padding(.bottom, 14)
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

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            // Students have no listing and so no avatar; the author's instructor photo is the only
            // image a post can carry for its writer.
            AvatarView(id: "", photo: data.authorPhoto(for: post), size: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(post.displayName)
                    .font(FloweFont.sans(13, .medium))
                    .foregroundStyle(Color.floweInk)
                // Assembled from user-entered names, so it stays a plain String; "Posting…" is real
                // copy and is localized.
                Group {
                    if post.pendingUpload { Text("Posting…") } else { Text(subtitle) }
                }
                .font(FloweFont.mono(10))
                .foregroundStyle(Color.floweMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isMine || post.ownerID != nil { moderationMenu }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: - Photo

    @ViewBuilder
    private var photo: some View {
        if let bytes = post.image, let image = UIImage(data: bytes) {
            // Sized by a clear spacer at the target ratio, with the photo filling it. Setting the
            // ratio on the image itself would fight `scaledToFill` for who decides the frame.
            Color.clear
                .aspectRatio(Self.displayRatio(for: image.size), contentMode: .fit)
                .overlay {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
                .contentShape(Rectangle())
                // Double-tap to like, as the gesture is everywhere else. Deliberately one-way: it
                // only ever adds a like, so a mistimed tap on a post you already liked can't
                // silently take it away.
                .onTapGesture(count: 2) {
                    if !post.liked { data.toggleLike(post) }
                }
                .accessibilityIdentifier("post.photo")
        } else if post.hasImage {
            // The record says there is a photo but this device hasn't downloaded it yet (the feed
            // query fetches no assets — see `CommunityService`). A placeholder at a plausible height
            // keeps the row from resizing under the reader's thumb when it lands.
            FlowGradients.grad
                .opacity(0.25)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .overlay(ProgressView().tint(Color.flowePinkDeep))
        }
    }

    /// How tall to draw a photo, as a width∶height ratio.
    ///
    /// Clamped to the range a feed can show without either letterboxing a panorama into a strip or
    /// letting one portrait shot take the whole screen: between 4∶5 (tall) and 1.91∶1 (wide), which
    /// is what photo feeds converge on. Inside that range the picture keeps its own proportions.
    private static func displayRatio(for size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return 1 }
        return min(max(size.width / size.height, 4.0 / 5.0), 1.91)
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 18) {
            Button {
                data.toggleLike(post)
            } label: {
                Image(systemName: post.liked ? "heart.fill" : "heart")
                    .font(.system(size: 21))
                    .foregroundStyle(post.liked ? Color.flowePink : Color.floweInk)
                    // A like is the one action here with a visible state change, so it gets the
                    // small spring the rest don't need.
                    .symbolEffect(.bounce, value: post.liked)
            }
            .accessibilityIdentifier("post.like")
            .accessibilityLabel(post.liked ? Text("Unlike") : Text("Like"))

            Button {
                showComments = true
            } label: {
                Image(systemName: "bubble.right")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.floweInk)
            }
            .accessibilityIdentifier("post.comments")
            .accessibilityLabel(Text("Comments"))

            Spacer()

            Button {
                data.toggleSave(post)
            } label: {
                Image(systemName: post.saved ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 20))
                    .foregroundStyle(post.saved ? Color.flowePinkDeep : Color.floweInk)
            }
            .accessibilityIdentifier("post.save")
            .accessibilityLabel(post.saved ? Text("Remove bookmark") : Text("Save"))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, hasPhoto ? 10 : 12)
        .padding(.bottom, 8)
    }

    // MARK: - Below the fold

    /// Hidden at zero rather than showing "0 likes", which reads as a verdict on the post.
    @ViewBuilder
    private var likeCount: some View {
        if post.likes > 0 {
            // Inflected rather than a bare "\(n) likes", which renders "1 likes". `inflect: true`
            // makes the noun agree with the number, and does so per-language rather than by an
            // English-shaped `n == 1` check that would be wrong in Arabic's six-way plural.
            Text("^[\(post.likes) like](inflect: true)")
                .font(FloweFont.sans(13, .medium))
                .foregroundStyle(Color.floweInk)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
        }
    }

    /// Author name run into the caption, as a photo feed sets it. Without a photo the same text is
    /// the whole post, so it is set larger and the name is left to the header.
    @ViewBuilder
    private var caption: some View {
        if !post.text.isEmpty {
            Group {
                if hasPhoto {
                    Text(post.displayName).font(FloweFont.sans(13, .medium))
                        + Text(verbatim: "  ")
                        + Text(post.text).font(FloweFont.sans(13))
                } else {
                    Text(post.text).font(FloweFont.sans(15))
                }
            }
            .foregroundStyle(Color.floweInk)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private var commentsLink: some View {
        if post.comments > 0 {
            Button {
                showComments = true
            } label: {
                Text("View ^[\(post.comments) comment](inflect: true)")
                    .font(FloweFont.sans(13))
                    .foregroundStyle(Color.floweMuted)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .accessibilityIdentifier("post.viewComments")
        }
    }

    private var timestamp: some View {
        Text(post.relativeTime)
            .font(FloweFont.mono(9))
            .foregroundStyle(Color.floweMuted)
            .padding(.horizontal, 16)
    }

    // MARK: - Moderation

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
}

#Preview {
    // Written through the normal compose path into the in-memory preview store, rather than
    // seeded: nothing here can reach the shared feed, and there is no fixture to mistake for a
    // real post. A photo can't be conjured without a picker, so this previews the text-only row.
    let store = MockDataStore.preview
    // `addPost` needs an author; the real app sets these from the session on sign-in.
    store.currentUserID = FloweConstants.localOwnerID
    store.currentUserName = "Taylor Brooks"
    store.addPost(type: .tip, instructorName: nil,
                  text: "Before you engage your powerhouse, find your exhale first. "
                      + "The breath is the engine — the core follows.")
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
