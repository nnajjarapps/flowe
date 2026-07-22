import SwiftUI

struct StudentTabView: View {
    @Environment(AppSession.self) private var session
    @Environment(MockDataStore.self) private var data
    @Environment(PushService.self) private var push

    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DiscoverView()
                .tabItem { Label("Discover", systemImage: "safari") }.tag(0)

            CommunityView()
                .tabItem { Label("Community", systemImage: "person.3") }.tag(1)

            BookingsView()
                .tabItem { Label("Bookings", systemImage: "calendar") }.tag(2)

            // Messaging needs both sides reachable — students previously had no way in at all.
            MessageListView()
                .tabItem { Label("Messages", systemImage: "message") }.tag(3)
                .badge(data.unreadMessageCount)

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.circle") }.tag(4)
        }
        .tint(Color.flowePinkDeep)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        // A tapped notification lands here: open the tab the alert was about, then clear the
        // request so returning to this screen later doesn't yank the user back to it.
        .onChange(of: push.pendingTopic) { _, topic in
            guard let topic else { return }
            switch topic {
            case .community: selectedTab = 1
            case .bookings:  selectedTab = 2
            case .messages:  selectedTab = 3
            case .reviews:   break   // students receive no review notifications
            }
            push.pendingTopic = nil
        }
    }
}

#Preview {
    StudentTabView()
        .environment(AppSession())
        .environment(MockDataStore.preview)
        .environment(AppSettings())
        .environment(PushService.shared)
}
