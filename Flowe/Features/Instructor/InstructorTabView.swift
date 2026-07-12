import SwiftUI

struct InstructorTabView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        TabView {
            Text("Dashboard")
                .tabItem {
                    Label("Dashboard", systemImage: "chart.bar")
                }

            Text("Calendar")
                .tabItem {
                    Label("Calendar", systemImage: "calendar")
                }

            Text("Community")
                .tabItem {
                    Label("Community", systemImage: "person.3")
                }

            Text("Messages")
                .tabItem {
                    Label("Messages", systemImage: "message")
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
    InstructorTabView()
        .environment(AppSession())
}
