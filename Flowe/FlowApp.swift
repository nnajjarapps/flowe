import SwiftData
import SwiftUI
import UIKit
import UserNotifications

/// Extract the instructor `ownerID` from a Flowe share link `…/i/<ownerID>` — host/prefix agnostic,
/// so it also matches the GitHub project-pages `/flowe-support/i/<id>` shape. Shared by BOTH
/// universal-link seams in `FloweApp`.
private func floweInstructorID(from url: URL?) -> String? {
    guard let parts = url?.pathComponents,
          let idx = parts.firstIndex(of: "i"), idx + 1 < parts.count else { return nil }
    let id = parts[idx + 1]
    return id.isEmpty ? nil : id
}

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

    /// The APNs device token arrived — hand it to the booking backend so it can push booking alerts to
    /// this device. Before the backend, CloudKit delivered its own subscription pushes and this token
    /// was never captured; the booking backend needs it explicitly.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in await FloweBackendClient.shared.registerAPNs(token: hex) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Non-fatal: booking pushes just won't reach this device until registration next succeeds.
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
    /// Branded cold-start splash, shown once per launch (this state is created with the app) then faded.
    @State private var showSplash = true

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

    /// Shown when the USER's iCloud storage is full.
    ///
    /// Flowe keeps working: on detection the private-DB mirror is dropped for the next launch, because
    /// a mirror that cannot export repeatedly resets and DISCARDS committed local writes. Local-only is
    /// strictly better than broken-mirror — everything saves, nothing reverts. The only loss is
    /// cross-device sync, so the copy says that rather than implying data is at risk.
    @ViewBuilder private var iCloudFullBanner: some View {
        if data.iCloudStorageFull {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.icloud.fill")
                    .font(.system(size: 16, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud storage is full")
                        .flowFont(.titleMedium)
                    Text("Flowe paused iCloud sync so everything keeps saving on this device. Free up space in Settings, then restart Flowe to sync again.")
                        .flowFont(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Resume") { data.resumeICloudSync() }
                    .flowFont(.label)
                    .foregroundStyle(Color.flowePinkDeep)
            }
            .foregroundStyle(Color.floweInk)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.floweCardBg)
            .overlay(alignment: .bottom) { Divider().overlay(Color.floweBorder) }
        }
    }

    var body: some Scene {
        WindowGroup {
            AppRouter()
                .safeAreaInset(edge: .top, spacing: 0) { iCloudFullBanner }
                .task { data.observeCloudKitHealth() }
                .environment(session)
                .environment(data)
                .environment(settings)
                .environment(subscription)
                .environment(PushService.shared)
                // A scanned/tapped Universal Link (…/flowe-support/i/<ownerID>) lands here. CRITICAL:
                // with a `UIApplicationDelegateAdaptor` present (Flowe has one for push), iOS delivers a
                // universal link as a BROWSING `NSUserActivity` — it does NOT arrive through `onOpenURL`,
                // which in this setup only catches custom URL schemes. Handling ONLY `onOpenURL` was the
                // bug: the QR opened the app but the instructor id was never delivered, so the profile
                // never showed (for every scanner — student or instructor). The real seam is
                // `onContinueUserActivity(NSUserActivityTypeBrowsingWeb)` (fires cold-start AND warm);
                // `onOpenURL` stays as belt-and-suspenders. The id is stashed on the session (not a view)
                // so it survives `AppRouter` swapping Onboarding/Quiz → tabs; `StudentTabView` consumes it.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let id = floweInstructorID(from: activity.webpageURL) { session.pendingInstructorID = id }
                }
                .onOpenURL { url in
                    if let id = floweInstructorID(from: url) { session.pendingInstructorID = id }
                }
                .modelContainer(container)
                .environment(\.locale, settings.locale)
                .environment(\.layoutDirection, settings.layoutDirection)
                // Dynamic Type: the whole type scale now grows with the user's text-size setting
                // (FlowTypography moved from fixedSize: to relativeTo: text styles). Clamp the CEILING to
                // accessibility1 for v1 — Flowe's layouts are fixed-frame-heavy, so the largest AX sizes
                // would clip until each screen gets a large-size pass on device; raise/remove this after
                // that TestFlight QA.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .task { await session.validateAppleCredential() }
                .task(id: session.authState) {
                    // Leave the store OWNERLESS for a guest (unauthenticated): with no currentUserID
                    // every owner-keyed publish/mutator self-aborts, so a missed UI gate can't write
                    // account data under the placeholder owner. Real identity is set only once signed in.
                    data.currentUserID = session.authState == .unauthenticated ? nil : session.ownerID
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
                    // Client notes + block list now live on the backend, so they follow this Apple ID
                    // across devices and no longer depend on the private-DB mirror (or on the user
                    // having iCloud space). Before `syncMessages`, so a block is in force before any
                    // message from that sender can land.
                    await data.syncPrivateState()
                    // Language, coverage radius and Out-of-Studio hours follow the Apple ID too, so a
                    // second device inherits the user's setup instead of resetting to defaults.
                    await settings.restoreFromBackend()
                    await data.syncBookings(asInstructor: isInstructor)
                    await data.syncCoverage(asInstructor: isInstructor)
                    await data.syncMessages()
                    // On a fresh device (same Apple id) the instructor's own row was just created blank
                    // by `ensureInstructorProfile` — `Instructor` is LOCAL-ONLY (Reference .none config)
                    // so it never syncs via the private DB. Pull photo/bio/specialties/etc back from the
                    // public listing before anything renders them. Guarded to the blank-row case inside.
                    if isInstructor { await data.hydrateOwnListingIfNeeded() }
                    // Lesson types are a SEPARATE public record type — the listing hydrate above does
                    // not carry them, and the only other `syncLessonTypes` call sits on the scenePhase
                    // foreground path, which a cold launch that never backgrounds may not hit at all.
                    // Missing them is not cosmetic: `myVisibilityBlocker` reads
                    // `startingPrice(from: ownedLessonTypes(for: me))`, so a fully-configured
                    // instructor on a fresh install was told they had no priced lesson type and sent
                    // back to the studio wizard. See [[flowe-app-store-submission]].
                    if isInstructor, let me = data.currentInstructor {
                        await data.syncLessonTypes(for: me)
                    }
                    // Pre-warm the opposite party's profiles so names + photos are present in
                    // Messages/Bookings before anything is tapped: an instructor caches the students
                    // they transact with; a student caches the instructors they message or booked.
                    if isInstructor { await data.syncStudentProfiles() } else { await data.syncBookedInstructors() }

                    // A signed-out→signed-in student (or a fresh device on the same Apple id) has a
                    // `currentUser` rebuilt from Apple — no name after the first authorization, never a
                    // photo — so "My Profile" reads blank while the instructor still sees the intact
                    // public record. Restore name/photo/bio from that same public profile, mirroring the
                    // instructor's `hydrateOwnListingIfNeeded` above.
                    if session.authState == .student, let mine = await data.hydrateOwnStudentProfileIfNeeded() {
                        session.restoreProfileFromDirectory(name: mine.name, bio: mine.bio,
                                                            photo: mine.photo, memberSince: mine.memberSince)
                        data.currentUserName = session.currentUser?.fullName ?? data.currentUserName
                    }
                    // Quiz answers are the last piece of a student's profile with no local copy after a
                    // reinstall (UserDefaults is wiped, unlike the Keychain). Without this the returning
                    // student is routed straight back into the 6-step quiz and their match profile —
                    // disciplines, budget, distance — is silently rebuilt from scratch.
                    if session.authState == .student { await session.restoreStudentPreferencesIfNeeded() }

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
                        // Foreground is a refresh seam alongside pull-to-refresh: re-sync the live feeds
                        // on every return so the visible tab is current without a swipe. `.task` covers
                        // first load; push keeps it live between; a swipe-down is the manual override.
                        let isInstructor = session.authState == .instructor
                        await data.syncBookings(asInstructor: isInstructor)
                        await data.syncMessages()
                        // Reviews have no push topic on the student side and lesson types have none at
                        // all, so without this foreground pull they'd only refresh on first load / relaunch
                        // or a manual swipe — the two feeds that would otherwise go stale.
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
                    // Only an instructor owns a listing to reveal — never publish visibility for a guest
                    // or student under the placeholder owner. (The one write-capable onChange lacking a guard.)
                    guard session.authState == .instructor else { return }
                    data.applyVisibility(subscription.tier?.mapsToVisibility ?? .none, for: session.ownerID)
                }
                // Branded cold-start moment: a short animated-logo splash over the app while the first
                // frame settles, then a gentle fade to content. Replaces the blank system launch screen
                // (empty UILaunchScreen). Fires once per launch — `showSplash` is created with the app.
                .overlay {
                    if showSplash {
                        FloweLoadingView()
                            .transition(.opacity)
                            .task {
                                try? await Task.sleep(for: .seconds(2))
                                withAnimation(FloweMotion.gentle) { showSplash = false }
                            }
                    }
                }
        }
    }
}
