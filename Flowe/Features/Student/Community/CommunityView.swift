import SwiftUI

/// Community tab: a header, a horizontal Stories strip of the top instructors,
/// and the scrolling feed of posts.
///
/// The feed is shared — posts live in the CloudKit public database (see `CommunityService`) and are
/// cached locally so the tab still renders offline.
struct CommunityView: View {
    @Environment(MockDataStore.self) private var data

    @State private var showCompose = false

    /// Blocked authors are already filtered out here, so an empty feed really is empty.
    private var feed: [FeedPost] { data.visiblePosts }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Stories strip — only when there are instructors to show
                if !data.publishedInstructors.isEmpty {
                    storiesStrip
                    Divider().overlay(Color.floweBorder)
                }

                // Feed
                if feed.isEmpty {
                    EmptyStateView(
                        icon: "bubble.left.and.bubble.right",
                        title: "Nothing here yet",
                        message: "Reviews, tips and check-ins from the community will show up here.",
                        actionTitle: "Write the first post",
                        action: { showCompose = true }
                    )
                    .padding(.top, 80)
                } else {
                    ForEach(feed) { post in
                        PostRowView(post: post)
                        Divider().overlay(Color.floweBorder)
                    }
                }
            }
        }
        .background(Color.flowWhite)
        .safeAreaInset(edge: .top, spacing: 0) {
            header
        }
        .refreshable { await data.syncCommunity() }
        .task {
            await data.syncCatalog()
            await data.syncCommunity()
        }
        .sheet(isPresented: $showCompose) {
            ComposePostSheet()
        }
    }

    private var header: some View {
        HStack {
            Text("Community")
                .font(FloweFont.serif(20))
                .foregroundStyle(Color.floweInk)

            Spacer()

            Button {
                showCompose = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(FlowGradients.gradDark)
                    .clipShape(Circle())
            }
            .accessibilityIdentifier("community.compose")
            .accessibilityLabel(Text("New Post"))
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(Color.flowWhite)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.floweBorder)
                .frame(height: 1)
        }
    }

    private var storiesStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(data.publishedInstructors.prefix(5)) { ins in
                    VStack(spacing: 4) {
                        AvatarView(id: ins.img, photo: ins.photo, size: 52, ring: true)
                        Text(ins.firstName)
                            .font(FloweFont.sans(9))
                            .foregroundStyle(Color.floweInk)
                            .lineLimit(1)
                            .frame(width: 48)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }
}

#Preview {
    CommunityView()
        .environment(MockDataStore.preview)
        .environment(AppSettings())
        .environment(AppSession())
}
