import SwiftUI

struct StudentTabView: View {
    @Environment(AppSession.self) private var session
    @Environment(MockDataStore.self) private var data
    @Environment(PushService.self) private var push

    @State private var selectedTab = 0
    @State private var deepLinkedInstructor: Instructor?
    /// Bumped each time the already-selected tab is tapped again; broadcast down
    /// via `\.tabReselectTrigger` so each tab's scroll content can honor it with
    /// `scrollToTopOnTabReselect(trigger:proxy:)` (see ScrollToTop in FloweCommon).
    @State private var reselectTick = 0

    /// Wraps `selectedTab` so a re-tap of the current tab (TabView calls `set`
    /// with the SAME value) becomes a scroll-to-top trigger instead of a no-op.
    private var tabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { newValue in
                if newValue == selectedTab {
                    reselectTick &+= 1
                    Haptic.tap()
                }
                selectedTab = newValue
            }
        )
    }

    var body: some View {
        TabView(selection: tabSelection) {
            // Discover is the NON-account feature — fully browsable by a guest (App Store 5.1.1(v)).
            DiscoverView().floweAdaptiveColumn()
                .tabItem { Label("Discover", systemImage: "safari") }.tag(0)

            // The account-only tabs show a sign-in wall for a guest instead of their real content, so a
            // guest can never reach an account write from here.
            Group {
                if session.isGuest {
                    GuestSignInWall(icon: "person.3", title: "Join the community",
                                    message: "Sign in to see familiar faces, follow practice-friends, and join the discussion.")
                } else {
                    CommunityView().floweAdaptiveColumn()
                }
            }
            .tabItem { Label("Community", systemImage: "person.3") }.tag(1)

            Group {
                if session.isGuest {
                    GuestSignInWall(icon: "calendar", title: "Your bookings",
                                    message: "Sign in to book classes and see your upcoming and past sessions here.")
                } else {
                    BookingsView().floweAdaptiveColumn()
                }
            }
            .tabItem { Label("Bookings", systemImage: "calendar") }.tag(2)

            // Messaging needs both sides reachable — students previously had no way in at all.
            Group {
                if session.isGuest {
                    GuestSignInWall(icon: "message", title: "Messages",
                                    message: "Sign in to message instructors and keep your conversations in one place.")
                } else {
                    MessageListView().floweAdaptiveColumn()
                }
            }
            .tabItem { Label("Messages", systemImage: "message") }.tag(3)
            .badge(data.unreadMessageCount)

            Group {
                if session.isGuest {
                    GuestSignInWall(icon: "person.circle", title: "Your profile",
                                    message: "Sign in to set up your profile, save instructors, and manage your account.")
                } else {
                    ProfileView().floweAdaptiveColumn()
                }
            }
            .tabItem { Label("Profile", systemImage: "person.circle") }.tag(4)
        }
        .sidebarAdaptableIfAvailable()
        .tint(Color.flowePinkDeep)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        // Broadcast the active-tab-reselect trigger to every tab's scroll content.
        .environment(\.tabReselectTrigger, reselectTick)
        // A tapped notification lands here: open the tab the alert was about, then clear the
        // request so returning to this screen later doesn't yank the user back to it.
        .onChange(of: push.pendingTopic) { _, topic in
            guard let topic else { return }
            switch topic {
            case .community: selectedTab = 1
            case .bookings:  selectedTab = 2
            case .messages:  selectedTab = 3
            case .reviews:   break   // students receive no review notifications
            case .coverage:  selectedTab = 2   // "your session will be covered" → Bookings
            }
            push.pendingTopic = nil
        }
        // A shared profile link lands here. `.task(id:)` fires both on first appearance (covering a
        // cold-start link that waited out the login/quiz gate) and on every change of the pending id
        // (warm foreground). Present at the tab level, not from inside Discover — a second sheet
        // stacked on Discover's own `.sheet` would double-present.
        .task(id: session.pendingInstructorID) {
            guard let id = session.pendingInstructorID else { return }
            session.pendingInstructorID = nil          // clear first to avoid re-entry
            selectedTab = 0                            // land on Discover for context
            deepLinkedInstructor = await data.loadInstructor(ownerID: id)
        }
        .fullScreenCover(item: $deepLinkedInstructor) { instructor in
            StudentInstructorProfileView(instructor: instructor) { deepLinkedInstructor = nil }
        }
    }
}

// MARK: Active-tab-reselect → scroll-to-top coordination

/// Value bumped by the tab shell whenever the already-selected tab is re-tapped.
/// A tab's scroll content reads it with `@Environment(\.tabReselectTrigger)` and
/// feeds it to `scrollToTopOnTabReselect(trigger:proxy:)` (see `ScrollToTop`).
/// Injected by both `StudentTabView` and `InstructorTabView`; defined once here.
private struct TabReselectTriggerKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var tabReselectTrigger: Int {
        get { self[TabReselectTriggerKey.self] }
        set { self[TabReselectTriggerKey.self] = newValue }
    }
}
