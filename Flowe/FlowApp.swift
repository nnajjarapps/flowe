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
        // UI tests drive state via launch arguments (debug builds only): reset for isolation,
        // optional seeded sample data, and offline so the public catalog isn't hit.
        #if DEBUG
        let defaults = UserDefaults.standard
        let seed = defaults.bool(forKey: "flowe.uiTestSeed")
        let reset = defaults.bool(forKey: "flowe.uiTestReset")
        let offline = seed || reset
        #else
        let seed = false, reset = false, offline = false
        #endif
        // App.init runs on the main thread at launch; the store + mainContext are @MainActor.
        let store = MainActor.assumeIsolated {
            MockDataStore(container.mainContext, seed: seed, reset: reset, offline: offline)
        }
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
                    data.currentUserName = session.currentUser?.fullName ?? ""
                    let isInstructor = session.authState == .instructor
                    if isInstructor {
                        data.ensureInstructorProfile(
                            ownerID: session.ownerID,
                            name: session.currentUser?.fullName ?? "Instructor"
                        )
                    }
                    guard session.authState != .unauthenticated else { return }
                    await data.syncBookings(asInstructor: isInstructor)
                    await data.syncMessages()
                }
                // Reflect the instructor's subscription onto their feed listing.
                .onChange(of: subscription.tier) {
                    data.applyVisibility(subscription.tier?.mapsToVisibility ?? .none, for: session.ownerID)
                }
        }
    }
}
