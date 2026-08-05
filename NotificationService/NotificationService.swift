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
        // be verified in Console (subsystem com.flowepilates.app.NotificationService). Marked .public
        // so it isn't redacted — this is a test push; there is no secret here (the DM text stays E2E
        // ciphertext and is never in this payload). Remove or drop to .debug once the path is confirmed.
        nseLog.info("NSE didReceive userInfo: \(String(describing: userInfo), privacy: .public)")

        // --- Parse the CloudKit query-notification payload (ck -> qry -> af). ---
        // NOTE: verify this key path on-device by logging `userInfo` once; if Apple changes it the
        // guards below simply fall through to the plain banner.
        guard let ck  = userInfo["ck"] as? [AnyHashable: Any],
              let qry = ck["qry"] as? [AnyHashable: Any],
              // Only the DM subscription becomes a communication notification. Subscription id
              // format: flowe.<version>.messages.received.<ownerID> (PushService.subscriptionID).
              (qry["sid"] as? String)?.contains(".messages.") == true,
              let af  = qry["af"] as? [AnyHashable: Any],
              let senderID = af["senderID"] as? String, !senderID.isEmpty,
              let conversationID = af["conversationID"] as? String, !conversationID.isEmpty
        else {
            // Ran, but the expected keys weren't found (non-DM push, or the payload path differs from
            // ck -> qry -> af). Compare against the raw dump above and adjust the guard if needed.
            nseLog.info("NSE gate: not a DM / keys absent — shipping plain banner.")
            return contentHandler(request.content)
        }
        let senderName = (af["senderName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Flowe"
        nseLog.info("NSE gate: DM matched — sender=\(senderName, privacy: .public) convo=\(conversationID, privacy: .public)")

        // Avatar: cached JPEG written by the app into the App Group, else a brand monogram.
        // NEVER fetch CloudKit here (guaranteed timeout risk) and NEVER decrypt.
        let avatar = AvatarCache.image(senderID: senderID) ?? AvatarCache.monogram(name: senderName)

        // Thread grouping: conversationID is identical on both devices (sorted owner-id pair),
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
