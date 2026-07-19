import SwiftUI

struct InstructorTabView: View {
    @Environment(AppSession.self) private var session
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

            InstructorProfileView()
                .tabItem { Label("Profile", systemImage: "person.circle") }.tag(3)
        }
        .tint(Color.flowePinkDeep)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .environment(router)
    }
}

#Preview {
    InstructorTabView()
        .environment(AppSession())
        .environment(MockDataStore.preview)
        .environment(SubscriptionService())
        .environment(AppSettings())
}
