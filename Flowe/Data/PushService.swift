import CloudKit
import Foundation
import Observation
import UIKit
import UserNotifications

/// What a notification is about. One topic drives three things: which existing sync runs when the
/// push lands, which tab a tap opens, and which preference toggle gates it.
enum PushTopic: String, Sendable {
    case bookings
    case messages
    case community
    case reviews
    case coverage

    /// Key a *local* notification carries its topic under. CloudKit pushes have no room for custom
    /// payload, so those are identified by the subscription id that fired instead.
    static let userInfoKey = "flowe.topic"
}

/// The `UserDefaults` keys behind the Notifications screen.
///
/// They live next to the code that *acts* on them rather than inside the view, so a toggle can
/// never drift away from the thing it controls. Every key here gates at least one real
/// subscription or scheduled reminder; a toggle that gates nothing is a lie told to the user.
enum NotificationPreference {
    static let bookings  = "notif.bookings"
    static let messages  = "notif.messages"
    static let reviews   = "notif.reviews"
    static let community = "notif.community"
    static let reminders = "notif.reminders"
    static let coverage  = "notif.coverage"

    /// Everything on by default — but the *system* prompt is still what actually turns alerts on,
    /// and that is asked for separately (see `PushService.requestAuthorizationIfWarranted`).
    /// Typed `[String: Bool]` rather than `[String: Any]` so the constant is `Sendable` — `Any`
    /// values would make this shared mutable state under strict concurrency. It still converts
    /// implicitly at the `register(defaults:)` call site, which wants `[String: Any]`.
    static let defaults: [String: Bool] = [
        bookings: true, messages: true, reviews: true, community: true, reminders: true,
        coverage: true
    ]

    /// Retired keys, removed on launch so a stale `true` can't linger in `UserDefaults`.
    ///
    /// - `notif.payouts` — Flowe collects no session payments at all (students pay their instructor
    ///   directly; see BOOKING-SYSTEM.md § Payments). There is no payout, so there can be no payout
    ///   notification, and a toggle promising one implies a capability the app does not have.
    /// - `notif.marketing` — nothing in the app or the CloudKit container can send a marketing
    ///   push; there is no campaign mechanism of any kind. It was a switch wired to nothing.
    static let retired = ["notif.payouts", "notif.marketing"]
}

/// Push notifications for everything two Flowe users do to each other.
///
/// ## Why `CKQuerySubscription`
///
/// Flowe has no server. Everything shared between users is a raw `CKRecord` in the CloudKit
/// **public** database (see `BookingService`, `MessagingService`, `CommunityService`,
/// `ReviewService`), so the only thing that can notice "someone wrote a record addressed to you"
/// is CloudKit itself. Each subscription below is a standing per-user query: its predicate matches
/// exactly the records that concern *this* user, mirroring the field names the matching service
/// already queries on — if the two ever disagree, the subscription silently never fires.
///
/// ## Never notify someone about their own action
///
/// CloudKit does *not* suppress a notification for the user who wrote the record, so this is
/// guaranteed structurally instead: every predicate targets the *counterpart's* id field, which is
/// never the writer's. A booking notifies `instructorID` but is written by the student; a decision
/// notifies `studentID` but is written by the instructor; a message notifies `recipientID`; a reply
/// notifies `replyTargetID`, which `CommunityService` deliberately leaves empty when the author
/// replies to their own post.
///
/// ## Why the alert text is never a literal string
///
/// `CKNotificationInfo` composes the alert **on the receiving device** from a localization key
/// looked up in that device's copy of the app. A literal string set here would be frozen at write
/// time, in the *sender's* language, and there would be no way to fix it afterwards without a
/// server. Every subscription therefore carries `titleLocalizationKey` / `alertLocalizationKey`
/// plus `alertLocalizationArgs` — which are **record field names**, not values, so CloudKit
/// substitutes the live field contents into the receiver's translation.
@MainActor
@Observable
final class PushService {
    /// The app delegate is created by UIKit and can never reach SwiftUI's environment, so the push
    /// pipeline needs one instance both sides can address.
    static let shared = PushService()

    /// Bumped whenever a predicate, record type or fire-condition below changes. It is part of
    /// every subscription id, so a changed rule ships as a *new* subscription and the previous one
    /// is swept as stale — rather than surviving forever with an outdated predicate, since an
    /// already-existing id is never re-saved (that is what makes registration idempotent).
    // Bumped v1→v2 for Communication Notifications: `refreshSubscriptions` never re-saves an id that
    // already exists, so changing a subscription's NotificationInfo in place would ship nothing to
    // existing installs. A new version mints new ids that get saved WITH mutable-content/desiredKeys,
    // and the sweep deletes the stale v1 set.
    private static let version = "v2"
    /// Namespace for everything this app owns in the user's subscription set. The sweep uses the
    /// bare prefix, not the versioned one, so subscriptions from older builds are cleaned up too.
    private static let idPrefix = "flowe."
    private static let reminderPrefix = "flowe.reminder."
    /// Set once subscriptions exist, so a logged-out launch doesn't hit the network to tear down
    /// subscriptions that were never created.
    private static let registeredKey = "flowe.push.registered"

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Set when a notification is tapped; the tab views consume it and clear it.
    var pendingTopic: PushTopic?

    /// The store to refresh when a push lands. Weak, and injected by `FlowApp`, because the app
    /// delegate has no other way to reach it — `PushService` never touches SwiftData itself.
    private weak var store: MockDataStore?
    private var isInstructor = false

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    private init() {
        let defaults = UserDefaults.standard
        // `@AppStorage(…) = true` only defaults the *view*; `UserDefaults.bool` would read false for
        // an untouched key, so the service would disagree with the switch the user is looking at.
        defaults.register(defaults: NotificationPreference.defaults)
        for key in NotificationPreference.retired { defaults.removeObject(forKey: key) }
    }

    // MARK: - Wiring

    func attach(store: MockDataStore, isInstructor: Bool) {
        self.store = store
        self.isInstructor = isInstructor
    }

    func isEnabled(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    // MARK: - Authorization

    func refreshAuthorizationStatus() async {
        authorizationStatus = await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus
    }

    /// Re-arm the APNs token on every launch — it is not persistent, and CloudKit cannot deliver a
    /// subscription's push to an app that never registered.
    func activate() async {
        await refreshAuthorizationStatus()
        if authorizationStatus == .authorized || authorizationStatus == .provisional {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
        await refreshAuthorizationStatus()
        if granted { UIApplication.shared.registerForRemoteNotifications() }
        return granted
    }

    /// Ask for permission at the first moment the answer obviously matters to the user.
    ///
    /// Not on first launch: at that point the user has not seen an instructor, made a request or
    /// sent a message, so "Flowe would like to send you notifications" is a question about nothing —
    /// and a denial there is effectively permanent, because iOS never asks twice. `hasPendingActivity`
    /// is passed by `FlowApp` the instant the user acquires something to wait on: a session request
    /// they have just sent, a request sitting in an instructor's queue, or a conversation. That is
    /// when the prompt answers a question the user is already asking.
    func requestAuthorizationIfWarranted(hasPendingActivity: Bool) async {
        guard hasPendingActivity else { return }
        await refreshAuthorizationStatus()
        guard authorizationStatus == .notDetermined else { return }
        await requestAuthorization()
    }

    // MARK: - Incoming

    /// The topic a payload belongs to, decoded off the main actor so the app delegate can hand over
    /// a plain `Sendable` value instead of the notification dictionary.
    nonisolated static func topic(from userInfo: [AnyHashable: Any]) -> PushTopic? {
        if let raw = userInfo[PushTopic.userInfoKey] as? String, let topic = PushTopic(rawValue: raw) {
            return topic
        }
        #if CLOUDKIT_ENABLED
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              let id = notification.subscriptionID else { return nil }
        return topic(forSubscriptionID: id)
        #else
        return nil
        #endif
    }

    /// `flowe.<version>.<topic>.<event>.<ownerID>`. Indexed from the front on purpose: an Apple user
    /// id contains dots ("001234.abcdef…"), so counting back from the end would decode garbage.
    nonisolated static func topic(forSubscriptionID id: String) -> PushTopic? {
        let parts = id.split(separator: ".")
        guard parts.count >= 4, parts[0] == "flowe" else { return nil }
        return PushTopic(rawValue: String(parts[2]))
    }

    /// Main-actor entry point for the app delegate, whose callbacks run outside any isolation.
    /// Only the `Sendable` topic crosses the boundary — never the notification payload, and never
    /// the service itself.
    @discardableResult
    static func deliver(_ topic: PushTopic) async -> Bool {
        await shared.sync(topic)
    }

    /// Run the sync that makes the notification true in the UI. A badge without the underlying data
    /// is how an app ends up showing "1 new message" over an empty inbox.
    @discardableResult
    func sync(_ topic: PushTopic) async -> Bool {
        guard let store else { return false }
        switch topic {
        case .bookings:
            await store.syncBookings(asInstructor: isInstructor)
            // A newly confirmed session is a session worth reminding the user about.
            await scheduleSessionReminders()
        case .messages:
            await store.syncMessages()
        case .community:
            await store.syncCommunity()
        case .reviews:
            await store.syncReviews(asInstructor: isInstructor)
        case .coverage:
            // Both roles have coverage state to reconcile: an instructor resolves the two-sided
            // approval and materialises the 50% ledger, a student picks up the `CoverageSession`
            // that tells them who is standing in. `syncCoverage` branches on the flag internally.
            await store.syncCoverage(asInstructor: isInstructor)
        }
        return true
    }

    // MARK: - Subscriptions

    /// One standing query in the public database.
    private struct Plan {
        let id: String
        let recordType: String
        let predicate: NSPredicate
        let options: CKQuerySubscription.Options
        let titleKey: String
        let titleArgs: [String]
        let bodyKey: String
        let bodyArgs: [String]
        /// DM plans only. Opts the push into the Notification Service Extension (adds
        /// 'mutable-content':1) so it can be re-authored as a Communication Notification.
        var mutableContent = false
        /// Fields the extension reads off the push 'ck' payload to build the INSendMessageIntent.
        /// Only meaningful when `mutableContent` is true. Never includes the E2E ciphertext `text`.
        var desiredKeys: [String] = []
    }

    private static func subscriptionID(_ topic: PushTopic, _ event: String, _ ownerID: String) -> String {
        "\(idPrefix)\(version).\(topic.rawValue).\(event).\(ownerID)"
    }

    /// Exactly the subscriptions this user should have right now, given their role and their
    /// toggles. Anything absent from this list is deleted by `refreshSubscriptions`, which is what
    /// makes switching a toggle off actually stop the alerts instead of merely hiding a row.
    private func plans(ownerID: String, isInstructor: Bool) -> [Plan] {
        var plans: [Plan] = []

        if isEnabled(NotificationPreference.bookings) {
            if isInstructor {
                // Mirrors `BookingService.fetchForInstructor`: requests are addressed by
                // `instructorID`, and the student is the record's creator, so this can never fire
                // for the instructor's own write.
                plans.append(Plan(
                    id: Self.subscriptionID(.bookings, "requested", ownerID),
                    recordType: BookingService.bookingRecordType,
                    predicate: NSPredicate(
                        format: "\(BookingService.bookingRecipientField) == %@", ownerID
                    ),
                    options: [.firesOnRecordCreation],
                    titleKey: "push.booking.requested.title", titleArgs: [],
                    bodyKey: "push.booking.requested.body", bodyArgs: ["studentName"]
                ))
                // A cancellation is an *update* to that same record — `BookingService.cancel` flips
                // `cancelled`, and the student is the only person who can write to a booking they
                // created, so an update to a booking addressed to me is a cancellation.
                plans.append(Plan(
                    id: Self.subscriptionID(.bookings, "cancelled", ownerID),
                    recordType: BookingService.bookingRecordType,
                    predicate: NSPredicate(
                        format: "\(BookingService.bookingRecipientField) == %@", ownerID
                    ),
                    options: [.firesOnRecordUpdate],
                    titleKey: "push.booking.cancelled.title", titleArgs: [],
                    bodyKey: "push.booking.cancelled.body", bodyArgs: ["studentName"]
                ))
            } else {
                // Accept and decline need different words, and one subscription can carry only one
                // alert, so they are two subscriptions split on `confirmed`. `studentID` is
                // denormalised onto the decision by `BookingService.respond` precisely so a
                // predicate can address the student at all.
                plans.append(Plan(
                    id: Self.subscriptionID(.bookings, "confirmed", ownerID),
                    recordType: BookingService.decisionRecordType,
                    predicate: NSPredicate(
                        format: "\(BookingService.decisionRecipientField) == %@ AND confirmed == 1",
                        ownerID
                    ),
                    options: [.firesOnRecordCreation, .firesOnRecordUpdate],
                    titleKey: "push.booking.confirmed.title", titleArgs: [],
                    bodyKey: "push.booking.confirmed.body", bodyArgs: []
                ))
                plans.append(Plan(
                    id: Self.subscriptionID(.bookings, "declined", ownerID),
                    recordType: BookingService.decisionRecordType,
                    predicate: NSPredicate(
                        format: "\(BookingService.decisionRecipientField) == %@ AND confirmed == 0",
                        ownerID
                    ),
                    options: [.firesOnRecordCreation, .firesOnRecordUpdate],
                    titleKey: "push.booking.declined.title", titleArgs: [],
                    bodyKey: "push.booking.declined.body", bodyArgs: []
                ))
            }
        }

        // Both roles message, and `MessagingService` addresses by `recipientID` — the sender is the
        // creator, so this never fires for the user's own message.
        if isEnabled(NotificationPreference.messages) {
            plans.append(Plan(
                id: Self.subscriptionID(.messages, "received", ownerID),
                recordType: MessagingService.recordType,
                predicate: NSPredicate(format: "\(MessagingService.recipientField) == %@", ownerID),
                options: [.firesOnRecordCreation],
                titleKey: "push.message.title", titleArgs: ["senderName"],
                // Generic static body (NOT the "%@"-bound ciphertext `text` field): the extension
                // replaces title/body in the happy path, but a fallback banner must never show
                // ciphertext. The extension personalizes from senderID/senderName/conversationID.
                bodyKey: "push.message.body.generic", bodyArgs: [],
                mutableContent: true,
                desiredKeys: ["senderID", "senderName", "conversationID"]
            ))
        }

        // Reviews are written by students *about* instructors, so only an instructor has any.
        if isInstructor && isEnabled(NotificationPreference.reviews) {
            plans.append(Plan(
                id: Self.subscriptionID(.reviews, "received", ownerID),
                recordType: ReviewService.recordType,
                predicate: NSPredicate(format: "\(ReviewService.recipientField) == %@", ownerID),
                // Creation only: `ReviewService` reuses `review-<bookingID>`, so an update is the
                // same student editing the same review — not news.
                options: [.firesOnRecordCreation],
                titleKey: "push.review.title", titleArgs: [],
                bodyKey: "push.review.body", bodyArgs: ["studentName"]
            ))
        }

        // Both roles now have a Community tab and can post to the feed, so both subscribe to replies
        // addressed to them.
        if isEnabled(NotificationPreference.community) {
            plans.append(Plan(
                id: Self.subscriptionID(.community, "reply", ownerID),
                recordType: CommunityService.commentRecordType,
                predicate: NSPredicate(format: "\(CommunityService.replyTargetField) == %@", ownerID),
                options: [.firesOnRecordCreation],
                titleKey: "push.community.reply.title", titleArgs: [],
                bodyKey: "push.community.reply.body", bodyArgs: ["authorName"]
            ))
        }

        // Out-of-Studio coverage. The auto-fan matcher writes a record addressed to each party in
        // turn, and — exactly like every predicate above — each subscription targets the *recipient*
        // field the counterpart wrote, never a field the receiver could have written themselves.
        // Each predicate is a single equality on a QUERYABLE field: CloudKit has no geo predicate,
        // so "near you" is decided on-device by the matcher, not here.
        if isEnabled(NotificationPreference.coverage) {
            if isInstructor {
                // An addressed offer from someone else's OOS report. `candidateID` is the covering
                // instructor; the requester is the record's creator, so this never self-fires.
                plans.append(Plan(
                    id: Self.subscriptionID(.coverage, "offer", ownerID),
                    recordType: CoverageService.offerRecordType,
                    predicate: NSPredicate(
                        format: "\(CoverageService.offerRecipientField) == %@", ownerID
                    ),
                    options: [.firesOnRecordCreation],
                    titleKey: "push.coverage.offer.title", titleArgs: [],
                    bodyKey: "push.coverage.offer.body", bodyArgs: ["sessionType", "sessionDate"]
                ))
                // A candidate claimed my OOS window. `requesterID` addresses me, the OOS owner, and
                // `accepted == 1` keeps a withdrawn claim (0) from alerting — the same split the
                // booking decision uses on `confirmed`.
                plans.append(Plan(
                    id: Self.subscriptionID(.coverage, "claim", ownerID),
                    recordType: CoverageService.claimRecordType,
                    predicate: NSPredicate(
                        format: "\(CoverageService.claimRecipientField) == %@ AND accepted == 1",
                        ownerID
                    ),
                    options: [.firesOnRecordCreation],
                    titleKey: "push.coverage.claim.title", titleArgs: [],
                    bodyKey: "push.coverage.claim.body", bodyArgs: ["replacerName"]
                ))
                // The OOS owner awarded me the slot by writing my id into `filledByID` on the
                // request they own — an *update*, since the request already existed open.
                plans.append(Plan(
                    id: Self.subscriptionID(.coverage, "confirmed", ownerID),
                    recordType: CoverageService.requestRecordType,
                    predicate: NSPredicate(
                        format: "\(CoverageService.requestRecipientField) == %@", ownerID
                    ),
                    options: [.firesOnRecordUpdate],
                    titleKey: "push.coverage.confirmed.title", titleArgs: [],
                    bodyKey: "push.coverage.confirmed.body", bodyArgs: []
                ))
            } else {
                // The one Coverage* record a student ever receives: an informational note that their
                // session will be taught by someone else. It carries `coveringInstructorName` for the
                // alert; the student's own booking is never touched (see COVERAGE-SYSTEM.md).
                plans.append(Plan(
                    id: Self.subscriptionID(.coverage, "covered", ownerID),
                    recordType: CoverageService.sessionRecordType,
                    predicate: NSPredicate(
                        format: "\(CoverageService.sessionRecipientField) == %@", ownerID
                    ),
                    options: [.firesOnRecordCreation],
                    titleKey: "push.coverage.covered.title", titleArgs: [],
                    bodyKey: "push.coverage.covered.body", bodyArgs: ["coveringInstructorName"]
                ))
            }
        }

        return plans
    }

    /// Bring the user's subscription set in line with `plans` — create what is missing, delete what
    /// no longer belongs.
    ///
    /// Idempotent by construction: an id that already exists is left completely alone rather than
    /// re-saved. Re-saving is what produces either a "subscription already exists" error or, worse,
    /// a second subscription firing a second copy of every alert.
    func refreshSubscriptions(ownerID: String, isInstructor: Bool) async {
        self.isInstructor = isInstructor
        #if CLOUDKIT_ENABLED
        let desired = plans(ownerID: ownerID, isInstructor: isInstructor)
        let desiredIDs = Set(desired.map(\.id))

        guard let existing = try? await database.allSubscriptions() else { return }
        let existingIDs = Set(existing.map(\.subscriptionID))

        let toSave = desired.filter { !existingIDs.contains($0.id) }.map(Self.makeSubscription)
        // Only ever sweep inside Flowe's own namespace: the public database's subscription set
        // belongs to the user, and SwiftData's private-database sync keeps its own entries there.
        let toDelete = existing.map(\.subscriptionID).filter {
            $0.hasPrefix(Self.idPrefix) && !desiredIDs.contains($0)
        }
        guard !toSave.isEmpty || !toDelete.isEmpty else {
            UserDefaults.standard.set(true, forKey: Self.registeredKey)
            return
        }
        // Swallowed like every other CloudKit call in Flowe: no iCloud account, no network, or a
        // schema that hasn't been deployed must degrade to "no notifications", never to an error.
        _ = try? await database.modifySubscriptions(saving: toSave, deleting: toDelete)
        UserDefaults.standard.set(true, forKey: Self.registeredKey)
        #endif
    }

    #if CLOUDKIT_ENABLED
    /// `nonisolated`: it reads nothing isolated, and it is passed to `map` as a plain function.
    nonisolated private static func makeSubscription(_ plan: Plan) -> CKQuerySubscription {
        let subscription = CKQuerySubscription(
            recordType: plan.recordType,
            predicate: plan.predicate,
            subscriptionID: plan.id,
            options: plan.options
        )
        let info = CKSubscription.NotificationInfo()
        // Keys, never literals — the alert is built on the receiver's device from *their* catalog.
        info.titleLocalizationKey = plan.titleKey
        info.titleLocalizationArgs = plan.titleArgs
        info.alertLocalizationKey = plan.bodyKey
        info.alertLocalizationArgs = plan.bodyArgs
        info.soundName = "default"
        // Also wake the app in the background so the matching sync runs and the UI is genuinely up
        // to date by the time the user opens it, instead of only being badged.
        info.shouldSendContentAvailable = true
        // No server keeps a running unread total, so an app-icon badge could only ever be wrong.
        info.shouldBadge = false
        if plan.mutableContent {
            // 'mutable-content':1 — the ONLY thing that lets the Notification Service Extension
            // intercept this remote push and re-author it as a Communication Notification.
            info.shouldSendMutableContent = true
            // Inline sender identity + thread into the push 'ck' payload so the extension reads
            // them locally (never fetches, never decrypts). Ciphertext `text` is excluded.
            info.desiredKeys = plan.desiredKeys
        }
        subscription.notificationInfo = info
        return subscription
    }
    #endif

    /// Remove every Flowe subscription and every scheduled reminder.
    ///
    /// Called on log out and on account deletion. A user who deleted their account and still gets
    /// Flowe pushes has been failed twice: the alerts are unwanted, and they prove data they were
    /// told was gone is still being matched.
    func tearDown() async {
        cancelAllReminders()
        UIApplication.shared.unregisterForRemoteNotifications()

        #if CLOUDKIT_ENABLED
        let defaults = UserDefaults.standard
        // Nothing was ever registered on this device — don't spend a round trip proving it.
        guard defaults.bool(forKey: Self.registeredKey) else { return }
        guard let existing = try? await database.allSubscriptions() else { return }
        let mine = existing.map(\.subscriptionID).filter { $0.hasPrefix(Self.idPrefix) }
        guard !mine.isEmpty else {
            defaults.set(false, forKey: Self.registeredKey)
            return
        }
        if (try? await database.modifySubscriptions(saving: [], deleting: mine)) != nil {
            defaults.set(false, forKey: Self.registeredKey)
        }
        #endif
    }

    // MARK: - Session reminders

    /// One hour is enough to leave for a studio and short enough that the session is still the next
    /// thing on the user's mind.
    private static let reminderLeadTime: TimeInterval = 60 * 60

    /// How far ahead a reminder may be scheduled. The booking flow only offers days inside the
    /// coming week, so anything beyond this is not a future session — it is a *past* one whose
    /// year-less date string ("Mon, Jul 7") resolved to next year's July when read months later.
    /// Nothing moves a stale `confirmed` booking to `completed`, so without this bound the app
    /// would eventually promise a reminder for a session that already happened.
    private static let reminderHorizon: TimeInterval = 8 * 24 * 60 * 60

    /// iOS keeps at most 64 pending local notifications per app and silently drops the rest. Cap
    /// well under that so Flowe's reminders never starve, and — if a user ever has more confirmed
    /// sessions in the horizon than this — keep the *nearest* ones, since a reminder for tomorrow
    /// matters more than one for next week. The 8-day horizon keeps this from binding in practice.
    private static let reminderMaxPending = 60

    /// Re-schedule local reminders for every confirmed upcoming session.
    ///
    /// These are local notifications, not pushes: the trigger is a time, not another user's action,
    /// and a serverless app has nothing that could send them from the outside. Existing reminders
    /// are cleared first, so a cancelled or declined session stops reminding and re-running this
    /// can never stack duplicates.
    func scheduleSessionReminders() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.reminderPrefix) }
        if !pending.isEmpty { center.removePendingNotificationRequests(withIdentifiers: pending) }

        guard isEnabled(NotificationPreference.reminders), let store else { return }

        // Build the DESIRED set first: every confirmed session whose reminder still lies in the
        // future and inside the horizon. Then keep only the nearest `reminderMaxPending` so a user
        // with many standing weeks can never blow past iOS's 64-pending ceiling and lose the soonest.
        let now = Date()
        let candidates = store.bookings
            // Not a waitlisted overflow seat — don't tell someone their class "starts soon" when they
            // hold no admitted seat. No-op on the instructor side (their rows have no seat index).
            .filter { $0.status == .confirmed && !store.isWaitlisted($0) }
            .compactMap { booking -> (booking: Booking, fireDate: Date)? in
                guard let start = booking.sessionStart(now: now) else { return nil }
                let fireDate = start.addingTimeInterval(-Self.reminderLeadTime)
                guard fireDate > now, start < now.addingTimeInterval(Self.reminderHorizon) else { return nil }
                return (booking, fireDate)
            }
            .sorted { $0.fireDate < $1.fireDate }
            .prefix(Self.reminderMaxPending)

        for (booking, fireDate) in candidates {
            let content = UNMutableNotificationContent()
            // Resolved when the notification is *delivered*, so a language change between scheduling
            // and the session doesn't leave a stale translation sitting in the queue.
            content.title = NSString.localizedUserNotificationString(
                forKey: "push.reminder.title", arguments: nil
            )
            // Re-render the time for the device's current language (Arabic/Hebrew digits + 24h),
            // never the raw en_US_POSIX "9:00 AM" that was stored for cross-user matching.
            let time = booking.localizedTime(.current)
            // Name the counterpart when it's known — the instructor sees the student, the student
            // sees the instructor. If the name isn't cached (e.g. profiles not yet pre-warmed), fall
            // back to the time-only body rather than printing an empty name into the sentence.
            let counterpart = isInstructor
                ? booking.studentName
                : (store.instructors.first { $0.legacyId == booking.instructorId }?.name ?? "")
            if counterpart.isEmpty {
                content.body = NSString.localizedUserNotificationString(
                    forKey: "push.reminder.body", arguments: [time]
                )
            } else {
                content.body = NSString.localizedUserNotificationString(
                    forKey: "push.reminder.body.named", arguments: [counterpart, time]
                )
            }
            content.sound = .default
            content.userInfo = [PushTopic.userInfoKey: PushTopic.bookings.rawValue]

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: fireDate
            )
            let request = UNNotificationRequest(
                identifier: Self.reminderIdentifier(for: booking),
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            try? await center.add(request)
        }
    }

    private func cancelAllReminders() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    /// Stable per booking, so re-scheduling replaces rather than duplicates.
    private static func reminderIdentifier(for booking: Booking) -> String {
        "\(reminderPrefix)\(booking.remoteID ?? "local-\(booking.legacyId)")"
    }
}
