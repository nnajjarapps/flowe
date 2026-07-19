import SwiftUI
import SwiftData

@main
struct FlowApp: App {
    private let container: ModelContainer

    @State private var session = AppSession()
    @State private var data: MockDataStore
    @State private var settings = AppSettings()

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
                .modelContainer(container)
                .environment(\.locale, settings.locale)
                .environment(\.layoutDirection, settings.layoutDirection)
                .task { await session.validateAppleCredential() }
        }
    }
}
