import UserNotifications
import Intents
import UIKit
import os.log

/// Console diagnostics for on-device key-path confirmation. Filter Console.app / `log stream`
/// on subsystem "com.flowepilates.app.NotificationService". The `ck -> qry -> af` payload path is
/// undocumented; log the raw `userInfo` once on a real push to confirm it (see `didReceive`).
private let nseLog = Logger(subsystem: "com.flowepilates.app.NotificationService", category: "push")

/// Turns an incoming-DM CloudKit push into an iOS Communication Notification.
///
/// Runs ONLY for the ChatMessage subscription (gated on the subscription id carried in the push
/// `ck` payload). It never decrypts: DM text is E2E ciphertext, so the personalization signal is
/// the plaintext sender name + a locally cached avatar written by the app into the App Group.
/// Every failure path ships the original CloudKit-composed banner — a notification is never dropped.
final class NotificationService: UNNotificationServiceExtension {

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        // Seed the fallback FIRST: this copy already holds the CloudKit-composed localized title/body.
        let mutable = (request.content.mutableCopy() as? UNMutableNotificationContent)
            ?? UNMutableNotificationContent()
        self.bestAttempt = mutable

        let userInfo = request.content.userInfo

        // On-device key-path confirmation: dump the raw payload so the real `ck -> qry -> af` path can
        // be verified in Console (subsystem com.flowepilates.app.NotificationService). DEBUG-ONLY: this
        // carries push metadata (senderID/conversationID/senderName in clear), so it must never reach a
        // shipping build's device logs — it is compiled out of Release entirely. (The DM text itself is
        // E2E ciphertext and is never present in this payload regardless of build.)
        #if DEBUG
        nseLog.debug("NSE didReceive userInfo: \(String(describing: userInfo), privacy: .public)")
        #endif

        // --- Parse the CloudKit query-notification payload (ck -> qry -> af). ---
        // NOTE: verify this key path on-device by logging `userInfo` once; if Apple changes it the
        // guards below simply fall through to the plain banner.
        // Two shapes, because DM delivery moved off CloudKit in 1.1:
        //   * the Worker sends senderID/conversationID at the TOP level, tagged `flowe.topic = messages`;
        //   * CloudKit nested them under ck -> qry -> af, identified by the subscription id.
        // Try the Worker shape first (the only one that fires now) and keep the CloudKit path so a
        // notification still in flight from the old subscription is not mishandled.
        let af: [AnyHashable: Any]? = {
            if userInfo["flowe.topic"] as? String == "messages" { return userInfo }
            guard let ck  = userInfo["ck"] as? [AnyHashable: Any],
                  let qry = ck["qry"] as? [AnyHashable: Any],
                  // Subscription id format: flowe.<version>.messages.received.<ownerID>.
                  (qry["sid"] as? String)?.contains(".messages.") == true
            else { return nil }
            return qry["af"] as? [AnyHashable: Any]
        }()
        guard let af,
              let senderID = af["senderID"] as? String, !senderID.isEmpty,
              let conversationID = af["conversationID"] as? String, !conversationID.isEmpty
        else {
            // Ran, but the expected keys weren't found (non-DM push, or the payload path differs from
            // ck -> qry -> af). Compare against the raw dump above and adjust the guard if needed.
            nseLog.info("NSE gate: not a DM / keys absent — shipping plain banner.")
            return contentHandler(request.content)
        }
        // Prefer the sender's CURRENT cached name (app-written into the App Group) over the message's
        // frozen `senderName`, which can be empty (name unset at send) or stale; then the field, then a default.
        let senderName = AvatarCache.name(senderID: senderID)
            ?? (af["senderName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "Flowe"
        // DEBUG-ONLY: sender name + conversation id are PII — never log them at .public in a shipping build.
        #if DEBUG
        nseLog.debug("NSE gate: DM matched — sender=\(senderName, privacy: .public) convo=\(conversationID, privacy: .public)")
        #endif

        // Avatar: cached JPEG written by the app into the App Group, else a brand monogram.
        // NEVER fetch CloudKit here (guaranteed timeout risk) and NEVER decrypt.
        let avatar = AvatarCache.image(senderID: senderID) ?? AvatarCache.monogram(name: senderName)

        // Thread grouping: conversationID is identical on both devices (sorted owner-id pair),
        // A message from someone the recipient has BLOCKED must not reveal its content. The subscription
        // is CloudKit's (no server-side filter) and an NSE can't fully cancel a push — so ship a
        // contentless banner: no sender, no message, no sound. (The app also stops STORING blocked
        // messages, so nothing lands in the thread either.)
        if AvatarCache.isBlockedSender(senderID) {
            nseLog.info("NSE gate: blocked sender — suppressing content.")
            return contentHandler(UNMutableNotificationContent())
        }

        // so the notification thread lines up with the in-app conversation.
        mutable.threadIdentifier = conversationID

        let handle = INPersonHandle(value: senderID, type: .unknown)
        let sender = INPerson(personHandle: handle,
                              nameComponents: nil,
                              displayName: senderName,
                              image: avatar,
                              contactIdentifier: nil,
                              customIdentifier: senderID)

        let intent = INSendMessageIntent(recipients: nil,
                                         outgoingMessageType: .outgoingMessageText,
                                         content: nil,
                                         speakableGroupName: nil,       // strictly 1:1
                                         conversationIdentifier: conversationID,
                                         serviceName: nil,
                                         sender: sender,
                                         attachments: nil)
        intent.setImage(avatar, forParameterNamed: \.sender)

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)   // fire-and-forget; do not branch on its result

        do {
            let updated = try mutable.updating(from: intent)
            contentHandler(updated)
        } catch {
            // Thrown if the app lacks the communication entitlement — ship the plain banner.
            contentHandler(mutable)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // Mandatory backstop near the ~30s budget: flush whatever we have (at minimum the banner).
        if let handler = contentHandler, let content = bestAttempt {
            handler(content)
        }
    }
}
