import SwiftUI

struct InstructorTabView: View {
    @Environment(AppSession.self) private var session
    @Environment(MockDataStore.self) private var data
    @Environment(SubscriptionService.self) private var subscription
    @Environment(PushService.self) private var push
    @State private var router = InstructorRouter()

    /// The "Set up your studio" wizard, presented full-screen over all tabs for a brand-new instructor.
    @State private var showStudioWizard = false
    /// Auto-launch is evaluated once per appearance; manual re-entry is via the dashboard tile.
    @State private var didEvaluateAutoLaunch = false
    /// Bumped each time the already-selected tab is tapped again; broadcast down
    /// via `\.tabReselectTrigger` so each tab's scroll content can honor it with
    /// `scrollToTopOnTabReselect(trigger:proxy:)` (see ScrollToTop in FloweCommon).
    @State private var reselectTick = 0

    private let maxTab = 4   // tags 0…4 (Dashboard, Calendar, Messages, Profile, Students)

    /// Defensive Instagram-style swipe between tabs — see `StudentTabView` for the
    /// rationale. Rides as a `.simultaneousGesture`, acts only on a decisive END.
    private func handleTabSwipe(_ value: DragGesture.Value) {
        let dx = value.translation.width
        let dy = value.translation.height
        guard abs(dx) > 80, abs(dx) > abs(dy) * 2 else { return }
        let next = router.selectedTab + (dx < 0 ? 1 : -1)   // swipe left → next tab; no wrap
        guard next >= 0, next <= maxTab, next != router.selectedTab else { return }
        router.selectedTab = next
        Haptic.tap()
    }

    var body: some View {
        @Bindable var router = router
        // Wraps `router.selectedTab` so a re-tap of the current tab (TabView calls `set`
        // with the SAME value) becomes a scroll-to-top trigger instead of a no-op.
        let tabSelection = Binding<Int>(
            get: { router.selectedTab },
            set: { newValue in
                if newValue == router.selectedTab {
                    reselectTick &+= 1
                    Haptic.tap()
                }
                router.selectedTab = newValue
            }
        )
        TabView(selection: tabSelection) {
            InstructorDashboardView().floweAdaptiveColumn()
                .tabItem { Label("Dashboard", systemImage: "chart.bar") }.tag(0)

            InstructorCalendarView().floweAdaptiveColumn()
                .tabItem { Label("Calendar", systemImage: "calendar") }.tag(1)

            MessageListView().floweAdaptiveColumn()
                .tabItem { Label("Messages", systemImage: "message") }.tag(2)
                .badge(data.unreadMessageCount)

            InstructorProfileView().floweAdaptiveColumn()
                .tabItem { Label("Profile", systemImage: "person.circle") }.tag(3)

            StudentsListView().floweAdaptiveColumn()
                .tabItem { Label("Students", systemImage: "person.2") }.tag(4)
        }
        .sidebarAdaptableIfAvailable()
        .tint(Color.flowePinkDeep)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        // Instagram-style swipe between tabs. `.simultaneousGesture` so it never steals
        // taps, vertical scrolls, or the in-page horizontal scrollers (e.g. the calendar
        // day-strip); the threshold in `handleTabSwipe` keeps it conservative.
        .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded(handleTabSwipe))
        // Broadcast the active-tab-reselect trigger to every tab's scroll content.
        .environment(\.tabReselectTrigger, reselectTick)
        // A tapped notification lands here: open the tab the alert was about, then clear the
        // request so returning to this screen later doesn't yank the user back to it.
        .onChange(of: push.pendingTopic) { _, topic in
            guard let topic else { return }
            switch topic {
            case .bookings:
                router.selectedTab = 1        // Calendar — where requests are answered
            case .messages:
                router.openMessages()
            case .reviews:
                router.profileTab = .reviews
                router.selectedTab = 3
            case .community:
                break                          // no Community tab on the instructor side
            case .coverage:
                router.selectedTab = 0         // Dashboard — the coverage cards live there
            }
            push.pendingTopic = nil
        }
        // A profile share link is student-facing and has no destination here. Drop it so it can't
        // linger on the app-lifetime session and resurface if this account later signs in as a student.
        .task(id: session.pendingInstructorID) {
            if session.pendingInstructorID != nil { session.pendingInstructorID = nil }
        }
        // Auto-launch the studio wizard for a brand-new instructor. Evaluated once, AFTER a short
        // settle so `FlowApp`'s authState task (`ensureInstructorProfile` + `hydrateOwnListingIfNeeded`)
        // can pull a returning device's listing first — otherwise a fully-set-up instructor could
        // briefly see it before hydrate lands. Completion is derived + the dismiss flag makes any
        // spurious present one-tap-dismissable, so this only genuinely fires for a new instructor.
        .task {
            guard !didEvaluateAutoLaunch else { return }
            didEvaluateAutoLaunch = true
            try? await Task.sleep(for: .seconds(0.8))
            guard session.authState == .instructor,
                  !StudioWizard.isDismissed(data.currentInstructor?.ownerID ?? session.ownerID),
                  StudioSetupState(data: data, subscription: subscription).incompleteCoreSteps
            else { return }
            showStudioWizard = true
        }
        .fullScreenCover(isPresented: $showStudioWizard) { StudioSetupWizard() }
        .environment(router)
    }
}
