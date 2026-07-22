import SwiftUI

struct InstructorTabView: View {
    @Environment(AppSession.self) private var session
    @Environment(MockDataStore.self) private var data
    @Environment(PushService.self) private var push
    @State private var router = InstructorRouter()

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            InstructorDashboardView()
                .tabItem { Label("Dashboard", systemImage: "chart.bar") }.tag(0)

            InstructorCalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }.tag(1)

            MessageListView()
                .tabItem { Label("Messages", systemImage: "message") }.tag(2)
                .badge(data.unreadMessageCount)

            InstructorProfileView()
                .tabItem { Label("Profile", systemImage: "person.circle") }.tag(3)
        }
        .tint(Color.flowePinkDeep)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
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
            }
            push.pendingTopic = nil
        }
        .environment(router)
    }
}

#Preview {
    InstructorTabView()
        .environment(AppSession())
        .environment(MockDataStore.preview)
        .environment(SubscriptionService())
        .environment(AppSettings())
        .environment(PushService.shared)
}
