import SwiftData
import SwiftUI
import UIKit
import UserNotifications

/// SwiftUI has no entry point for remote notifications, so the push pipeline needs a UIKit delegate.
///
/// It holds no state of its own — every callback decodes the payload into a plain `PushTopic` and
/// hands it to `PushService.shared`, which is the same instance the SwiftUI side puts in the
/// environment. Decoding happens before the hop to the main actor so the notification objects,
/// none of which are `Sendable`, never cross an isolation boundary.
final class FloweAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Must be set before launching finishes: a cold start from a notification tap delivers the
        // response immediately afterwards, and a delegate assigned any later never sees it.
        UNUserNotificationCenter.current().delegate = self
        Task { await PushService.shared.activate() }
        return true
    }

    /// A CloudKit subscription push. `shouldSendContentAvailable` on the subscription is what gets
    /// the app woken for this in the background — the point being that the matching sync runs, so
    /// the data behind the alert is already there when the user opens the app.
    /// The completion-handler form rather than the `async` refinement: the refinement's
    /// non-`Sendable` payload has to cross an isolation boundary whichever side it is implemented
    /// on, while this one is delivered on the main actor and never crosses at all.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let topic = PushService.topic(from: userInfo) else { return completionHandler(.noData) }
        Task { @MainActor in
            let refreshed = await PushService.deliver(topic)
            completionHandler(refreshed ? .newData : .noData)
        }
    }

    /// Foreground arrival. Still shown as a banner: the alert may well be about a screen the user
    /// isn't looking at, and silently swallowing it is how a message goes unnoticed.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let topic = PushService.topic(from: notification.request.content.userInfo)
        completionHandler([.banner, .sound, .list])
        guard let topic else { return }
        Task { @MainActor in await PushService.shared.sync(topic) }
    }

    /// The tap. Recording the topic is enough to open the right tab; `StudentTabView` and
    /// `InstructorTabView` consume it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let topic = PushService.topic(from: response.notification.request.content.userInfo)
        // Answered up front rather than after the sync: the tap has just brought the app to the
        // foreground, so there is no suspension to hold off, and holding the handler open would
        // only delay the very screen the user asked for.
        completionHandler()
        guard let topic else { return }
        Task { @MainActor in
            PushService.shared.pendingTopic = topic
            await PushService.shared.sync(topic)
        }
    }
}

@main
struct FlowApp: App {
    @UIApplicationDelegateAdaptor(FloweAppDelegate.self) private var appDelegate

    private let container: ModelContainer

    @Environment(\.scenePhase) private var scenePhase

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
                .environment(PushService.shared)
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
                    // The delegate is created by UIKit and can't see this environment, so the push
                    // service is handed the store (and the role its syncs need) from here.
                    PushService.shared.attach(store: data, isInstructor: isInstructor)

                    guard session.authState != .unauthenticated else {
                        // Signing out has to take the subscriptions with it. They live on the
                        // server keyed to an ownerID this device no longer holds, so leaving them
                        // would push a stranger's activity at whoever has the phone next.
                        await PushService.shared.tearDown()
                        return
                    }
                    await data.syncBookings(asInstructor: isInstructor)
                    await data.syncMessages()

                    await PushService.shared.refreshSubscriptions(
                        ownerID: session.ownerID, isInstructor: isInstructor
                    )
                    await PushService.shared.requestAuthorizationIfWarranted(
                        hasPendingActivity: !data.bookings.isEmpty || !data.messages.isEmpty
                    )
                    await PushService.shared.scheduleSessionReminders()
                }
                // The moment the user acquires something to wait on — a request just sent, a request
                // just received, a first conversation — is the moment the permission prompt is
                // worth asking. See `requestAuthorizationIfWarranted`.
                .onChange(of: data.bookings.count + data.messages.count) { _, count in
                    guard session.authState != .unauthenticated, count > 0 else { return }
                    Task {
                        await PushService.shared.requestAuthorizationIfWarranted(hasPendingActivity: true)
                        await PushService.shared.scheduleSessionReminders()
                    }
                }
                // Re-arm the APNs token (it isn't persistent) and re-check reminders against
                // whatever changed while the app was away.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active, session.authState != .unauthenticated else { return }
                    Task {
                        await PushService.shared.activate()
                        await PushService.shared.scheduleSessionReminders()
                    }
                }
                // Reflect the instructor's subscription onto their feed listing.
                .onChange(of: subscription.tier) {
                    data.applyVisibility(subscription.tier?.mapsToVisibility ?? .none, for: session.ownerID)
                }
        }
    }
}
