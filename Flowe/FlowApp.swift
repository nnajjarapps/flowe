import SwiftUI

@main
struct FlowApp: App {
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            AppRouter()
                .environment(session)
        }
    }
}
