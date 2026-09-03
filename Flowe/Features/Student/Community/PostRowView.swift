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
    @State private var showZoom = false
    @State private var showLikers = false

    private var isMine: Bool { data.isMine(post) }

    private var hasPhoto: Bool { post.image != nil }

    /// The author's CURRENT identity, resolved live at render time — not the name/photo frozen onto
    /// the post when it was written. Read inside `body` (via the computed prop) so a profile that
    /// lands after `fetchAuthorProfiles` re-renders this row. Falls back to the post's snapshot.
    private var authorIdentity: AuthorIdentity {
        data.displayIdentity(ownerID: post.ownerID, fallbackName: post.authorNameOrEmpty)
    }

    /// Preserves the localized "Someone" fallback of `FeedPost.displayName` while showing the
    /// resolved live name — the resolver returns a plain String, so the guard stays here.
    private var authorNameText: Text {
        authorIdentity.name.isEmpty ? Text("Someone") : Text(authorIdentity.name)
    }

    /// The author's live name for the block affordance, falling back to the localized "Someone" the
    /// rest of the row uses rather than to the stale snapshot.
    private var blockDisplayName: String {
        let live = authorIdentity.name
        return live.isEmpty ? String(localized: "Someone") : live
    }

    private var subtitle: String {
        let action: String
        switch post.type {
        case .review:    action = "shouted out \(post.instructor ?? "")"
        case .checkin:   action = "checked in with \(post.instructor ?? "")"
        case .tip:       action = "shared a tip"
        case .milestone: action = "reached a milestone"
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
        .sheet(isPresented: $showLikers) {
            PostLikesSheet(post: post)
        }
        .sheet(isPresented: $showReport) {
            ReportSheet(
                reportedID: post.ownerID ?? "",
                reportedName: blockDisplayName,
                content: .communityPost,
                contentID: post.remoteID ?? "",
                snapshot: post.text
            )
        }
        .floweConfirm(
            isPresented: $confirmDelete,
            title: "Delete this post?",
            message: "It disappears for everyone. This can't be undone.",
            confirmTitle: "Delete",
            isDestructive: true
        ) { data.deletePost(post) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            // Live-resolved avatar: an instructor author's Unsplash id / uploaded photo, or a
            // student author's uploaded photo — whatever their CURRENT profile carries.
            AvatarView(id: authorIdentity.img, photo: authorIdentity.photo, size: 34)

            VStack(alignment: .leading, spacing: 1) {
                authorNameText
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
                // Double-tap to like, as the gesture is everywhere else. Deliberately one-way: the
                // closure only ever adds a like (it no-ops when already liked), so a mistimed tap on
                // a post you already liked can't silently take it away. Added BEFORE the single tap
                // so the double-tap wins and a lone tap falls through to open the viewer.
                .doubleTapToLike {
                    if !post.liked { data.toggleLike(post) }
                }
                // Single tap opens the full-screen zoomable viewer.
                .onTapGesture { showZoom = true }
                .fullScreenImageZoom(data: post.image, isPresented: $showZoom)
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
                // A like landing is the row's one moment of confirmation — a medium tap when it
                // lands, a lighter tick when taken back.
                if post.liked { Haptic.tap() } else { Haptic.impact() }
                withAnimation(FloweMotion.pop) { data.toggleLike(post) }
            } label: {
                Image(systemName: post.liked ? "heart.fill" : "heart")
                    .font(.system(size: 21))
                    .foregroundStyle(post.liked ? Color.flowePink : Color.floweInk)
                    // A like is the one action here with a visible state change, so it gets the
                    // small pop the rest don't need (symbolEffect self-disables under reduce-motion).
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
        // Standard Flowe press feedback for the row's actions (was `.buttonStyle(.plain)`, which
        // gave none). The like keeps its own bounce on top of the press scale.
        .flowePressable()
        .padding(.horizontal, 16)
        .padding(.top, hasPhoto ? 10 : 12)
        .padding(.bottom, 8)
    }

    // MARK: - Below the fold

    /// Hidden at zero rather than showing "0 likes", which reads as a verdict on the post. Tapping it
    /// opens the "Liked by" list — available to anyone, like Instagram.
    @ViewBuilder
    private var likeCount: some View {
        if post.likes > 0 {
            Button {
                showLikers = true
            } label: {
                // Inflected rather than a bare "\(n) likes", which renders "1 likes". `inflect: true`
                // makes the noun agree with the number, and does so per-language rather than by an
                // English-shaped `n == 1` check that would be wrong in Arabic's six-way plural.
                Text("^[\(post.likes) like](inflect: true)")
                    .font(FloweFont.sans(13, .medium))
                    .foregroundStyle(Color.floweInk)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
            .accessibilityIdentifier("post.likeCount")
            .accessibilityHint(Text("See who liked this"))
        }
    }

    /// Author name run into the caption, as a photo feed sets it. Without a photo the same text is
    /// the whole post, so it is set larger and the name is left to the header.
    @ViewBuilder
    private var caption: some View {
        if !post.text.isEmpty {
            Group {
                if hasPhoto {
                    authorNameText.font(FloweFont.sans(13, .medium))
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
                // LIVE name, matching the row above. `post.displayName`/`post.user` are the snapshot
                // frozen when the post was written, so an author who has since renamed showed one
                // name in the post header and a different one here (and in Blocked Users, which
                // stores whatever is passed). Same frozen-snapshot family as ae3ca3f.
                Button("Block \(blockDisplayName)", systemImage: "hand.raised", role: .destructive) {
                    data.block(id: post.ownerID ?? "", name: blockDisplayName)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16))
                .foregroundStyle(Color.floweMuted)
                .frame(width: 32, height: 32, alignment: .trailing)
        }
        .accessibilityLabel("More options")
        .accessibilityIdentifier("post.moderation")
    }
}

// MARK: - Profile activity tabs ("My posts" / "My events")

/// Which events belong on this profile — the same tab serves both roles, and they mean different
/// things by "my events".
enum ProfileActivityScope {
    /// Instructor: the events they ORGANIZE. Opening one enters management (edit / cancel / delete).
    case organizing
    /// Student: the events they have JOINED. Read-only — a student never manages an event.
    case attending
}

/// The signed-in user's own posts, as a profile sub-tab. Used by both profiles.
///
/// Deliberately a LIST of the real feed rows, not a photo grid: Flowe posts are `tip` / `checkin` /
/// `milestone` / `review` and carry an image only when `hasImage` is set, so a grid would be mostly
/// blank tiles. Reusing `PostRowView` also means a post looks identical here and in the community
/// feed, and every affordance already on that row (like, comment, delete, report) keeps working with
/// no second implementation to keep in sync.
///
/// Lives in this file rather than its own because adding a file means hand-editing
/// `project.pbxproj` — see [[flowe-xcodegen-not-installed]].
struct ProfilePostsList: View {
    @Environment(MockDataStore.self) private var data

    var body: some View {
        let posts = data.myPosts
        if posts.isEmpty {
            EmptyStateView(
                icon: "square.text.square",
                title: "Nothing posted yet",
                message: "Share a tip, a check-in or a milestone and it will show up here."
            )
        } else {
            // Edge-to-edge, exactly as the community feed renders it: `PostRowView` carries its
            // OWN horizontal padding (16) and lets photos bleed, so an outer padding here would
            // double-inset every row. The caller must NOT pad this tab. Dividers match the feed.
            LazyVStack(spacing: 0) {
                ForEach(Array(posts.enumerated()), id: \.element.id) { index, post in
                    PostRowView(post: post)
                    if index < posts.count - 1 {
                        Divider().overlay(Color.floweBorder)
                    }
                }
            }
            .accessibilityIdentifier("profile.activity.posts")
        }
    }
}

/// The signed-in user's own events, as a profile sub-tab — hosted (instructor) or joined (student)
/// depending on `scope`.
struct ProfileEventsList: View {
    let scope: ProfileActivityScope

    @Environment(MockDataStore.self) private var data
    @State private var selectedEvent: CommunityEvent?

    private var events: [CommunityEvent] {
        switch scope {
        case .organizing: return data.myEvents
        case .attending:  return data.myJoinedEvents
        }
    }

    var body: some View {
        Group {
            if events.isEmpty {
                EmptyStateView(
                    icon: "calendar",
                    title: scope == .organizing ? "No events yet" : "No events joined yet",
                    message: scope == .organizing
                        ? "Host a community event and it will appear here."
                        : "Join a community event and it will appear here."
                )
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(events) { event in
                        EventCardView(event: event, style: .compact) { selectedEvent = event }
                    }
                }
                .accessibilityIdentifier("profile.activity.events")
            }
        }
        .sheet(item: $selectedEvent) { event in
            EventDetailView(event: event, manageable: scope == .organizing)
        }
    }
}
