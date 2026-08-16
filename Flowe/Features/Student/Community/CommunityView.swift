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
/// `ScrollView`/`.task`, so the events list is never nested in the feed's edge-to-edge
/// zero-spacing stack.
struct CommunityView: View {
    @Environment(MockDataStore.self) private var data
    /// Bumped by the tab shell when the already-selected Community tab is re-tapped;
    /// drives scroll-to-top on the feed (see `ScrollToTop` in FloweCommon).
    @Environment(\.tabReselectTrigger) private var reselectTick

    @State private var tab: CommunityTab = .feed
    @State private var showCompose = false
    @State private var selectedInstructor: Instructor?   // stories-strip tap → profile

    /// Namespace for the segmented control's sliding selection pill (matchedGeometryEffect).
    @Namespace private var segNS

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
        .fullScreenCover(item: $selectedInstructor) { ins in
            StudentInstructorProfileView(instructor: ins) { selectedInstructor = nil }
        }
    }

    // MARK: - Feed

    private var feedScroll: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: 0) {
                // Top anchor for active-tab-reselect scroll-to-top.
                Color.clear.frame(height: 0).id(ScrollToTop.anchorID)

                // Stories strip — only when there are instructors to show
                if !data.publishedInstructors.isEmpty {
                    storiesStrip
                    Divider().overlay(Color.floweBorder)
                }

                // Feed
                if feed.isEmpty {
                    if data.communityPhase == .loading {
                        // First load with nothing cached: shimmering skeleton rows instead of a
                        // bare spinner, so the feed reads as "arriving" rather than "empty".
                        feedSkeleton
                    } else {
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
                    }
                } else {
                    ForEach(Array(feed.enumerated()), id: \.element.id) { index, post in
                        PostRowView(post: post)
                            .floweAppear(index)
                        Divider().overlay(Color.floweBorder)
                    }
                }
            }
        }
        .scrollToTopOnTabReselect(trigger: reselectTick, proxy: proxy)
        .task {
            await data.syncCatalog()
            await data.syncCommunity()
            // Post any newly-earned practice milestone so the feed opens with it (Flowe Community).
            data.checkMilestones()
        }
        // Manual pull-to-refresh for the feed (posts + stories strip). Mirrors the .task syncs.
        .refreshable {
            await data.syncCatalog()
            await data.syncCommunity()
            data.checkMilestones()
        }
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
                    guard tab != t else { return }
                    Haptic.selection()
                    // The selected pill's background carries a matchedGeometryEffect id, so wrapping
                    // the state change in FloweMotion.pop slides it between segments instead of
                    // cross-fading in place.
                    withAnimation(FloweMotion.pop) { tab = t }
                } label: {
                    Text(LocalizedStringKey(t.label))
                        .font(FloweFont.sans(12, .medium))
                        .foregroundStyle(tab == t ? Color.floweInk : Color.floweMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if tab == t {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.flowWhite)
                                    .shadow(color: Color.flowePink.opacity(0.15), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "segPill", in: segNS)
                            }
                        }
                        // The unselected tab's background is Color.clear, which isn't hit-tested — so
                        // without this only the text was tappable, not the whole pill. Makes the full
                        // framed area the tap target.
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(t.accessibilityID)
            }
        }
        .padding(2)
        .background(Color.floweCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Shimmering placeholder rows shown during the feed's first load (see `feedScroll`).
    private var feedSkeleton: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color.floweCardBg)
                            .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.floweCardBg)
                                .frame(width: 120, height: 10)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.floweCardBg)
                                .frame(width: 80, height: 8)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    Rectangle()
                        .fill(Color.floweCardBg)
                        .frame(height: 220)
                }
                .floweShimmer(true)
                .padding(.bottom, 14)
                Divider().overlay(Color.floweBorder)
            }
        }
    }

    private var storiesStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(data.publishedInstructors.prefix(5)) { ins in
                    // The story-ring avatar reads as tappable (Instagram affordance) — wire it to the
                    // instructor's profile instead of being a dead end.
                    Button {
                        Haptic.selection()
                        selectedInstructor = ins
                    } label: {
                        VStack(spacing: 4) {
                            AvatarView(id: ins.img, photo: ins.photo, size: 52, ring: true)
                            Text(ins.firstName)
                                .font(FloweFont.sans(9))
                                .foregroundStyle(Color.floweInk)
                                .lineLimit(1)
                                .frame(width: 48)
                        }
                    }
                    .buttonStyle(.plain)
                    .flowePressable()
                    .accessibilityLabel(Text(verbatim: ins.firstName))
                    .accessibilityHint("Opens profile")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }
}
