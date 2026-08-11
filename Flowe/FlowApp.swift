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
        // The app is CloudKit-only — no seed/mock/offline mode in any build configuration.
        // App.init runs on the main thread at launch; the store + mainContext are @MainActor.
        let store = MainActor.assumeIsolated {
            MockDataStore(container.mainContext)
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
                // A tapped Universal Link lands here. SwiftUI's `onOpenURL` fires on both cold-start
                // and warm foreground; the UIKit delegate is push-only (implements no
                // `continueUserActivity`), so this is the single supported seam. Parsed inline —
                // robust to both `/i/<id>` and the GitHub project-pages `/flowe-support/i/<id>` shape —
                // then stashed on the session (not a view) so it survives `AppRouter` swapping
                // Onboarding/Quiz → tabs; `StudentTabView` consumes it. Mirrors `PushService.pendingTopic`.
                .onOpenURL { url in
                    let parts = url.pathComponents
                    guard let idx = parts.firstIndex(of: "i"), idx + 1 < parts.count else { return }
                    let id = parts[idx + 1]
                    guard !id.isEmpty else { return }
                    session.pendingInstructorID = id
                }
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
                    } else if session.authState == .student {
                        data.ensureStudentProfile(
                            ownerID: session.ownerID,
                            name: session.currentUser?.fullName ?? "Student",
                            memberSince: session.currentUser?.memberSince ?? Date()
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
                    // Publish my end-to-end messaging key before syncing messages, so counterparts
                    // can encrypt to me and my own sends can be sealed.
                    await data.activateMessaging()
                    await data.syncBookings(asInstructor: isInstructor)
                    await data.syncCoverage(asInstructor: isInstructor)
                    await data.syncMessages()
                    // On a fresh device (same Apple id) the instructor's own row was just created blank
                    // by `ensureInstructorProfile` — `Instructor` is LOCAL-ONLY (Reference .none config)
                    // so it never syncs via the private DB. Pull photo/bio/specialties/etc back from the
                    // public listing before anything renders them. Guarded to the blank-row case inside.
                    if isInstructor { await data.hydrateOwnListingIfNeeded() }
                    // Pre-warm the opposite party's profiles so names + photos are present in
                    // Messages/Bookings before anything is tapped: an instructor caches the students
                    // they transact with; a student caches the instructors they message or booked.
                    if isInstructor { await data.syncStudentProfiles() } else { await data.syncBookedInstructors() }

                    // Re-arm APNs on every sign-in, not just at launch. `tearDown` unregisters the
                    // device token, and signing back in without relaunching would otherwise leave
                    // subscriptions recreated server-side with nothing to deliver to — the app
                    // never backgrounds, so the scenePhase path doesn't cover it either.
                    await PushService.shared.activate()

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
                        // Follow an account-wide role switch made on another device (same Apple ID) BEFORE
                        // the rest of this refresh, so everything below runs against the correct role.
                        await session.reconcileRole()
                        await PushService.shared.activate()
                        await PushService.shared.scheduleSessionReminders()
                        // Re-read the Apple-ID entitlement on every foreground. A subscription is tied to
                        // the Apple ID and shared across devices, but `Transaction.currentEntitlements` is
                        // only sampled at `init` + on `Transaction.updates` — so a purchase (or renewal)
                        // made on another device on the same account wouldn't surface here until a full
                        // relaunch. This closes that gap (cheap local read, no password prompt — unlike
                        // `AppStore.sync()`, which stays reserved for the explicit Restore button).
                        await subscription.refreshEntitlements()
                        // Pull any profile edit made on another device while we were away
                        // (last-writer-wins; throttled + no-clobber guarded inside).
                        if session.authState == .instructor { await data.hydrateOwnListingIfNeeded() }
                        // Pull-to-refresh has been removed app-wide, so foreground is now the async
                        // refresh seam: re-sync the live feeds on every return so the visible tab is
                        // current without a swipe. `.task` covers first load; push keeps it live between.
                        let isInstructor = session.authState == .instructor
                        await data.syncBookings(asInstructor: isInstructor)
                        await data.syncMessages()
                        // Reviews have no push topic on the student side and lesson types have none at
                        // all, so without this foreground pull they'd only refresh on first load / relaunch
                        // now that pull-to-refresh is gone — the two feeds that would otherwise go stale.
                        await data.syncReviews(asInstructor: isInstructor)
                        if isInstructor {
                            await data.syncCoverage(asInstructor: true)
                            await data.syncEvents(asOrganizer: true)
                            if let me = data.currentInstructor { await data.syncLessonTypes(for: me) }
                        } else {
                            await data.syncCatalog()
                            await data.syncCommunity()
                            await data.syncEvents(asOrganizer: false)
                        }
                    }
                }
                // Reflect the instructor's subscription onto their feed listing.
                .onChange(of: subscription.tier) {
                    data.applyVisibility(subscription.tier?.mapsToVisibility ?? .none, for: session.ownerID)
                }
        }
    }
}
