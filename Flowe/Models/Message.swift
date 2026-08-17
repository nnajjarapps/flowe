import Foundation
import SwiftData

/// A chat message, cached locally from the shared message store (see `MessagingService`).
///
/// Messages are append-only and each one is written by its sender, so unlike bookings no
/// two-record split is needed — CloudKit's default `_creator`-write security already fits.
@Model
final class Message {
    /// recordName in the public database. Nil while the message is still queued for upload.
    var remoteID: String?
    /// Stable client id, minted once when the message is composed. It derives a DETERMINISTIC
    /// public recordName (`msg-<localID>`) so the upload is idempotent: a re-send (the explicit
    /// upload racing `syncMessages`'s retry loop, or a retry after a crash) upserts the SAME record
    /// instead of creating a duplicate, and `merge` can recognise the fetched-back copy as already
    /// held before the upload even finishes. Legacy rows keep a fresh UUID on migration — harmless,
    /// they already carry a `remoteID`. Same posture as `CommunityEvent.localID`.
    var localID: UUID = UUID()
    /// Deterministic id for the pair of participants — see `Message.conversationID(_:_:)`.
    var conversationID: String = ""
    var senderID: String = ""
    var senderName: String = ""
    var recipientID: String = ""
    var recipientName: String = ""
    var text: String = ""
    var sentAt: Date = Date.distantPast

    /// Recipient-local: whether this message has been seen. Never round-trips to the sender.
    var isRead: Bool = false
    /// The message has not reached the shared store yet; retried on the next sync.
    var pendingUpload: Bool = false
    /// "Deleted for everyone" tombstone — the row is KEPT but rendered as "You deleted a message" /
    /// "This message was deleted" on BOTH sides. Only the sender can set it, only within 24h of `sentAt`.
    /// A plain "delete for me" removes the row locally instead and never touches this flag.
    var deleted: Bool = false

    init(
        remoteID: String? = nil,
        localID: UUID = UUID(),
        conversationID: String = "",
        senderID: String = "",
        senderName: String = "",
        recipientID: String = "",
        recipientName: String = "",
        text: String = "",
        sentAt: Date = Date(),
        isRead: Bool = false,
        pendingUpload: Bool = false
    ) {
        self.remoteID = remoteID
        self.localID = localID
        self.conversationID = conversationID
        self.senderID = senderID
        self.senderName = senderName
        self.recipientID = recipientID
        self.recipientName = recipientName
        self.text = text
        self.sentAt = sentAt
        self.isRead = isRead
        self.pendingUpload = pendingUpload
    }

    /// Text to render. A row whose `text` is still sealed ciphertext (its key wasn't readable when it
    /// synced) shows a neutral placeholder rather than the raw wire value — `MockDataStore.retryStuckMessages`
    /// keeps re-decrypting it every sync, so this resolves to the real text as soon as the key lands.
    var displayText: String {
        MessageCrypto.isSealed(text) ? MessageCrypto.sealedPlaceholder : text
    }

    /// The window in which a sender may still "delete for everyone" (WhatsApp-style).
    static let deleteForEveryoneWindow: TimeInterval = 24 * 60 * 60

    /// Whether this user may still delete THIS message for everyone: it must be their own message, not
    /// already deleted, and within 24h of when it was sent.
    func canDeleteForEveryone(currentUserID: String?) -> Bool {
        senderID == currentUserID && !deleted
            && Date().timeIntervalSince(sentAt) < Self.deleteForEveryoneWindow
    }

    /// Stable id for a pair of participants, independent of who is sending — sorting the two
    /// owner ids means both devices derive the same thread id without coordinating.
    static func conversationID(_ a: String, _ b: String) -> String {
        [a, b].sorted().joined(separator: "~")
    }

    /// The message's deterministic public recordName. The `msg-` prefix keeps it clear of every
    /// other record type (recordName is unique per zone ACROSS types), and deriving it from the
    /// stable `localID` makes the upload idempotent — the whole point of the field.
    static func recordName(localID: UUID) -> String { "msg-\(localID.uuidString)" }
    var recordName: String { Message.recordName(localID: localID) }

    /// The other participant, from the perspective of `me`.
    func counterpart(for me: String) -> Counterpart {
        senderID == me
            ? Counterpart(id: recipientID, name: recipientName)
            : Counterpart(id: senderID, name: senderName)
    }
}

/// The other side of a conversation. Deliberately not an `Instructor`: a student's counterpart is
/// an instructor, but an instructor's counterpart is a student, who has no listing.
struct Counterpart: Identifiable, Hashable {
    let id: String       // ownerID
    let name: String
    /// Optional image id — only instructors have a listing photo.
    var avatarID: String = ""
    /// Uploaded photo when the counterpart is a student (resolved from their public StudentProfile).
    /// Rides alongside `avatarID` so `AvatarView` can show a real image; nil → gradient placeholder.
    var photo: Data? = nil

    var displayName: String { name.isEmpty ? "Someone" : name }
    var firstName: String { displayName.split(separator: " ").first.map(String.init) ?? displayName }
}

/// One row in the inbox: the counterpart plus a preview of the latest message.
struct ConversationSummary: Identifiable {
    let counterpart: Counterpart
    let lastMessage: String
    let lastSentAt: Date
    let unreadCount: Int

    var id: String { counterpart.id }
    var hasUnread: Bool { unreadCount > 0 }
}
