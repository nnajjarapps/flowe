import SwiftUI
import SwiftData

@main
struct FlowApp: App {
    private let container: ModelContainer

    @State private var session = AppSession()
    @State private var data: MockDataStore
    @State private var settings = AppSettings()
    @State private var subscription = SubscriptionService()

    init() {
        let container = FloweModelContainer.make()
        self.container = container
        // App.init runs on the main thread at launch; the store + mainContext are @MainActor.
        let store = MainActor.assumeIsolated { MockDataStore(container.mainContext) }
        _data = State(initialValue: store)
    }

    var body: some Scene {
        WindowGroup {
            AppRouter()
                .environment(session)
                .environment(data)
                .environment(settings)
                .environment(subscription)
                .modelContainer(container)
                .environment(\.locale, settings.locale)
                .environment(\.layoutDirection, settings.layoutDirection)
                .task { await session.validateAppleCredential() }
                .task(id: session.authState) {
                    data.currentUserID = session.ownerID
                    if session.authState == .instructor {
                        data.ensureInstructorProfile(
                            ownerID: session.ownerID,
                            name: session.currentUser?.fullName ?? "Instructor"
                        )
                    }
                }
                // Reflect the instructor's subscription onto their feed listing.
                .onChange(of: subscription.tier) {
                    data.applyVisibility(subscription.tier?.mapsToVisibility ?? .none, for: session.ownerID)
                }
        }
    }
}
