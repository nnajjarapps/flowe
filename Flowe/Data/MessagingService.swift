import Foundation
import CloudKit

/// A message as it exists in the shared store (plain DTO decoded from a CKRecord).
struct RemoteMessage {
    let id: String
    let conversationID: String
    let senderID: String
    let senderName: String
    let recipientID: String
    let recipientName: String
    let text: String
    let sentAt: Date

    init?(record: CKRecord) {
        guard let conversationID = record["conversationID"] as? String,
              let senderID = record["senderID"] as? String,
              let recipientID = record["recipientID"] as? String,
              let text = record["text"] as? String else { return nil }
        id = record.recordID.recordName
        self.conversationID = conversationID
        self.senderID = senderID
        self.recipientID = recipientID
        self.text = text
        senderName = record["senderName"] as? String ?? ""
        recipientName = record["recipientName"] as? String ?? ""
        sentAt = record["sentAt"] as? Date ?? .distantPast
    }
}

/// Message exchange over CloudKit's **public** database, for the same reason bookings live there:
/// SwiftData can only mirror the *private* database, which is per-iCloud-account, so a message
/// written by one user would never reach the other.
///
/// Messages are append-only and each is written by its sender, so the default `_creator`-write
/// security role is a natural fit — no two-record split like `BookingService` needs.
///
/// CloudKit query predicates do **not** support `OR`, so the inbox is assembled from two equality
/// queries (messages I sent, messages I received) rather than one compound query.
@MainActor
final class MessagingService {
    static let recordType = "ChatMessage"

    /// The field a message addresses its reader by — never the sender, so a `CKQuerySubscription`
    /// on it can't notify someone about their own message. Shared with `PushService` so the query
    /// and the subscription predicate can't drift apart.
    static let recipientField = "recipientID"

    /// Per-page size for the cursor sweep. Completeness comes from following the cursor, not this.
    private static let pageSize = 400

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    /// Publish a message. Returns the remote id, or nil if it didn't reach the server.
    func send(conversationID: String,
              senderID: String,
              senderName: String,
              recipientID: String,
              recipientName: String,
              text: String,
              sentAt: Date) async -> String? {
        #if CLOUDKIT_ENABLED
        let record = CKRecord(recordType: Self.recordType)
        record["conversationID"] = conversationID
        record["senderID"] = senderID
        record["senderName"] = senderName
        record["recipientID"] = recipientID
        record["recipientName"] = recipientName
        record["text"] = text
        record["sentAt"] = sentAt
        do {
            let saved = try await database.save(record)
            return saved.recordID.recordName
        } catch {
            return nil   // offline / not signed into iCloud / schema not deployed
        }
        #else
        return nil
        #endif
    }

    /// Delete a message from the shared store. Only the message's own sender can do this — the
    /// public database grants write to `_creator`, so deleting someone else's message is rejected.
    /// Best-effort: a failure (offline, not mine) just leaves the record, which the caller tolerates.
    func delete(remoteID: String) async {
        #if CLOUDKIT_ENABLED
        _ = try? await database.deleteRecord(withID: CKRecord.ID(recordName: remoteID))
        #endif
    }

    /// Every message involving this user, in both directions.
    func fetchMessages(for ownerID: String) async -> [RemoteMessage] {
        #if CLOUDKIT_ENABLED
        async let sent = fetch(NSPredicate(format: "senderID == %@", ownerID))
        async let received = fetch(NSPredicate(format: "recipientID == %@", ownerID))
        return await sent + received
        #else
        return []
        #endif
    }

    /// A single thread — used when opening a conversation, so it refreshes without a full sync.
    func fetchThread(conversationID: String) async -> [RemoteMessage] {
        await fetch(NSPredicate(format: "conversationID == %@", conversationID))
    }

    private func fetch(_ predicate: NSPredicate) async -> [RemoteMessage] {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "sentAt", ascending: true)]
        var messages: [RemoteMessage] = []
        do {
            var page = try await database.records(
                matching: query, desiredKeys: nil, resultsLimit: Self.pageSize
            )
            messages += page.matchResults.compactMap { try? $0.1.get() }.compactMap(RemoteMessage.init)
            // Follow the cursor so a thread (or an inbox) past one page keeps updating. Without this,
            // the ascending sort returns the OLDEST page and the newest messages are silently dropped
            // forever once the record set crosses `pageSize` — an active conversation stops updating.
            while let cursor = page.queryCursor {
                page = try await database.records(
                    continuingMatchFrom: cursor, desiredKeys: nil, resultsLimit: Self.pageSize
                )
                messages += page.matchResults.compactMap { try? $0.1.get() }.compactMap(RemoteMessage.init)
            }
            return messages
        } catch {
            return []
        }
        #else
        return []
        #endif
    }
}
