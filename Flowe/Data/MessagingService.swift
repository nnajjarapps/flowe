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

/// A per-conversation, per-reader "read up to `lastReadAt`" marker — the sender reads the counterpart's
/// to render "Seen". Carries only a conversationID (a hash of the two owner ids), the reader's id and a
/// timestamp: no message content, so nothing here needs the E2E encryption the messages themselves get.
struct RemoteReadReceipt {
    let conversationID: String
    let readerID: String
    let lastReadAt: Date

    init?(record: CKRecord) {
        guard let conversationID = record["conversationID"] as? String,
              let readerID = record["readerID"] as? String else { return nil }
        self.conversationID = conversationID
        self.readerID = readerID
        lastReadAt = record["lastReadAt"] as? Date ?? .distantPast
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

    /// Read receipts (the "Seen" indicator). A separate record type; fetched by deterministic
    /// recordName so NO field needs to be queryable in the CloudKit schema.
    static let readReceiptRecordType = "ReadReceipt"

    /// Deterministic recordName so a reader's receipt for a conversation UPSERTS (exactly one row, always
    /// current) and the counterpart fetches it by name without a query. The `read-` prefix namespaces it
    /// away from every other record type — recordName is unique per zone ACROSS record types.
    static func readReceiptRecordName(conversationID: String, readerID: String) -> String {
        "read-\(conversationID)-\(readerID)"
    }

    /// Per-page size for the cursor sweep. Completeness comes from following the cursor, not this.
    private static let pageSize = 400

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    /// Publish a message. Returns the remote id, or nil if it didn't reach the server.
    /// `recordName` is the caller's DETERMINISTIC id for the message (`Message.recordName`), which makes
    /// this an idempotent create: a re-send of the same message (the explicit upload racing the sync
    /// retry loop, or a retry after a crash) targets the same record instead of minting a duplicate.
    /// A conflict on the already-created record is therefore SUCCESS — the message is on the server —
    /// so we return the name rather than nil (which would keep it flagged pending and re-tried forever).
    func send(recordName: String,
              conversationID: String,
              senderID: String,
              senderName: String,
              recipientID: String,
              recipientName: String,
              text: String,
              sentAt: Date) async -> String? {
        #if CLOUDKIT_ENABLED
        let record = CKRecord(recordType: Self.recordType,
                              recordID: CKRecord.ID(recordName: recordName))
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
        } catch let error as CKError where error.code == .serverRecordChanged {
            // The record already exists (a concurrent/duplicate send won the race). That IS the
            // record we wanted written — treat it as delivered, don't create a second copy.
            return recordName
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

    /// Publish (upsert) the signed-in reader's "read up to `lastReadAt`" marker for a conversation.
    /// Creator-owned by the reader; the deterministic recordName makes a re-read an UPDATE, not a dup.
    @discardableResult
    func publishReadReceipt(conversationID: String, readerID: String, lastReadAt: Date) async -> Bool {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: Self.readReceiptRecordName(conversationID: conversationID, readerID: readerID))
        let record = (try? await database.record(for: id))
            ?? CKRecord(recordType: Self.readReceiptRecordType, recordID: id)
        record["conversationID"] = conversationID
        record["readerID"] = readerID
        record["lastReadAt"] = lastReadAt
        return (try? await database.save(record)) != nil
        #else
        return false
        #endif
    }

    /// Fetch the counterpart's read marker for a conversation (direct record read by recordName — works
    /// with no queryable index). Nil if they've never read, offline, or the type isn't deployed yet.
    func fetchReadReceipt(conversationID: String, readerID: String) async -> RemoteReadReceipt? {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: Self.readReceiptRecordName(conversationID: conversationID, readerID: readerID))
        guard let record = try? await database.record(for: id) else { return nil }
        return RemoteReadReceipt(record: record)
        #else
        return nil
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
