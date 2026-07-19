import SwiftUI

struct StudentTabView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        TabView {
            DiscoverView()
                .tabItem { Label("Discover", systemImage: "safari") }

            CommunityView()
                .tabItem { Label("Community", systemImage: "person.3") }

            BookingsView()
                .tabItem { Label("Bookings", systemImage: "calendar") }

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.circle") }
        }
        .tint(Color.flowePinkDeep)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
    }
}

#Preview {
    StudentTabView()
        .environment(AppSession())
        .environment(MockDataStore.preview)
        .environment(AppSettings())
}
