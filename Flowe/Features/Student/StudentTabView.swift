import SwiftUI

struct StudentTabView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        TabView {
            Text("Home")
                .tabItem {
                    Label("Home", systemImage: "house")
                }

            Text("Search")
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }

            Text("Community")
                .tabItem {
                    Label("Community", systemImage: "person.3")
                }

            Text("Profile")
                .tabItem {
                    Label("Profile", systemImage: "person.circle")
                }
        }
        .tint(Color.flowEspressoBrown)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
    }
}

#Preview {
    StudentTabView()
        .environment(AppSession())
}
