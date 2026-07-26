import SwiftUI

/// The two sub-tabs Community is split into. Local to this screen — nothing else segments on it.
private enum CommunityTab: CaseIterable {
    case feed, events

    var label: String {
        switch self {
        case .feed:   return "Feed"
        case .events: return "Events"
        }
    }

    var accessibilityID: String {
        switch self {
        case .feed:   return "community.tab.feed"
        case .events: return "community.tab.events"
        }
    }
}

/// Community tab: a header with a Feed/Events segmented control, then either the post feed (a header,
/// a Stories strip of top instructors, and the scrolling posts) or the events list.
///
/// Both the feed and the events live in the CloudKit public database (see `CommunityService` /
/// `EventService`) and are cached locally so the tab still renders offline. Each sub-tab owns its own
/// `ScrollView`/`.task`/`.refreshable`, so the events list is never nested in the feed's edge-to-edge
/// zero-spacing stack.
struct CommunityView: View {
    @Environment(MockDataStore.self) private var data

    @State private var tab: CommunityTab = .feed
    @State private var showCompose = false

    /// Blocked authors are already filtered out here, so an empty feed really is empty.
    private var feed: [FeedPost] { data.visiblePosts }

    var body: some View {
        Group {
            switch tab {
            case .feed:   feedScroll
            case .events: EventsListView()
            }
        }
        .background(Color.flowWhite)
        .safeAreaInset(edge: .top, spacing: 0) {
            header
        }
        .sheet(isPresented: $showCompose) {
            ComposePostSheet()
        }
    }

    // MARK: - Feed

    private var feedScroll: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Stories strip — only when there are instructors to show
                if !data.publishedInstructors.isEmpty {
                    storiesStrip
                    Divider().overlay(Color.floweBorder)
                }

                // Feed
                if feed.isEmpty {
                    FeedPlaceholder(phase: data.communityPhase,
                                    retry: { Task { await data.syncCommunity() } }) {
                        EmptyStateView(
                            icon: "camera",
                            title: "Nothing here yet",
                            message: "Photos, tips and check-ins from the community will show up here.",
                            actionTitle: "Share the first post",
                            action: { showCompose = true }
                        )
                    }
                    .padding(.top, 80)
                } else {
                    ForEach(feed) { post in
                        PostRowView(post: post)
                        Divider().overlay(Color.floweBorder)
                    }
                }
            }
        }
        .refreshable { await data.syncCommunity() }
        .task {
            await data.syncCatalog()
            await data.syncCommunity()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Community")
                    .font(FloweFont.serif(20))
                    .foregroundStyle(Color.floweInk)

                Spacer()

                // A student has no event-create affordance, so the compose button belongs to the feed
                // only. It would also make Events read as a filtered feed.
                if tab == .feed {
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
            }

            segmented
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

    // Copied from `BookingsView.segmented`: floweCardBg track, a flowWhite selected pill with a soft
    // pink shadow. `Text(LocalizedStringKey(t.label))` (never `Text(t.rawValue)`) so it translates.
    private var segmented: some View {
        HStack(spacing: 0) {
            ForEach(CommunityTab.allCases, id: \.self) { t in
                Button {
                    tab = t
                } label: {
                    Text(LocalizedStringKey(t.label))
                        .font(FloweFont.sans(12, .medium))
                        .foregroundStyle(tab == t ? Color.floweInk : Color.floweMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(tab == t ? Color.flowWhite : Color.clear)
                                .shadow(
                                    color: tab == t ? Color.flowePink.opacity(0.15) : .clear,
                                    radius: 3, y: 1
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(t.accessibilityID)
            }
        }
        .padding(2)
        .background(Color.floweCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
