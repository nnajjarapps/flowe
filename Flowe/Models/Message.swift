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

    init(
        remoteID: String? = nil,
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

    /// Stable id for a pair of participants, independent of who is sending — sorting the two
    /// owner ids means both devices derive the same thread id without coordinating.
    static func conversationID(_ a: String, _ b: String) -> String {
        [a, b].sorted().joined(separator: "~")
    }

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
