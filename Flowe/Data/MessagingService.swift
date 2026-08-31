import Foundation

/// A message as it exists in the shared store.
///
/// No `senderName` / `recipientName`. The CloudKit record denormalised both, which froze a copy of a
/// name at write time — the same defect that showed a renamed user by her OLD name in the block menu.
/// `MockDataStore.conversations` already prefers the live listing / StudentProfile name in every
/// message surface, so the snapshot was only ever a last-resort fallback, and a store whose whole point
/// is not leaking who-talks-to-whom has no business retaining names either.
struct RemoteMessage: Decodable {
    let id: String
    let conversationID: String
    let senderID: String
    let recipientID: String
    let text: String
    let sentAt: Date
    let deleted: Bool

    private enum CodingKeys: String, CodingKey {
        case id, conversationID, senderID, recipientID, text, sentAt, deleted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        senderID = try c.decode(String.self, forKey: .senderID)
        recipientID = try c.decode(String.self, forKey: .recipientID)
        text = try c.decode(String.self, forKey: .text)
        sentAt = Date(msEpoch: try c.decodeIfPresent(Double.self, forKey: .sentAt) ?? 0)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

/// A per-conversation, per-reader "read up to `lastReadAt`" marker — the sender reads the counterpart's
/// to render "Seen". Carries only a conversationID, the reader's id and a timestamp: no message content.
struct RemoteReadReceipt: Decodable {
    let conversationID: String
    let readerID: String
    let lastReadAt: Date

    private enum CodingKeys: String, CodingKey { case found, conversationID, readerID, lastReadAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decodeIfPresent(Bool.self, forKey: .found) ?? false else {
            throw DecodingError.dataCorruptedError(forKey: .found, in: c, debugDescription: "no receipt")
        }
        conversationID = try c.decode(String.self, forKey: .conversationID)
        readerID = try c.decode(String.self, forKey: .readerID)
        lastReadAt = Date(msEpoch: try c.decodeIfPresent(Double.self, forKey: .lastReadAt) ?? 0)
    }
}

/// Direct-message exchange, **behind the authorization backend** as of 1.1.
///
/// It used to live on CloudKit's public database. The message TEXT was safe there — end-to-end
/// encrypted, and it still is; the same `enc.v1.` ciphertext simply travels here instead — but
/// `ChatMessage` was `GRANT READ TO "_world"` with senderID, senderName, recipientID, recipientName and
/// sentAt all QUERYABLE, so the SOCIAL GRAPH was public: anyone could enumerate who messages whom, by
/// name, with timestamps. That metadata cannot be encrypted away, because the recipient has to query by
/// their own id — the only fix is per-request authorization, which the public database cannot do at all.
///
/// Every route here is scoped to the caller server-side: the sender is taken from the session token and
/// never from the request, and reads return only rows the caller is party to. `PublicKey` deliberately
/// stays on CloudKit — a public key is meant to be world-readable.
@MainActor
final class MessagingService {
    /// Legacy CloudKit constants, kept ONLY so `AccountDeletionService` can still sweep a user's
    /// pre-cutover records out of the public database. Nothing writes, reads or subscribes to these
    /// record types any more — the DM push subscription was retired with the delivery move.
    static let recordType = "ChatMessage"
    static let readReceiptRecordType = "ReadReceipt"

    private let backend = FloweBackendClient.shared

    /// Publish a message. Returns the remote id, or nil if it didn't reach the server.
    ///
    /// `recordName` is the caller's DETERMINISTIC id (`Message.recordName`), which makes this an
    /// idempotent create: a re-send (the explicit upload racing the sync retry loop, or a retry after a
    /// crash) targets the same row instead of minting a duplicate. The server's `ON CONFLICT DO NOTHING`
    /// means a repeat is success, not a second message — and cannot rewrite the original's content.
    ///
    /// The sender is NOT a parameter: the server takes it from the session token, so a message can never
    /// be forged as coming from someone else.
    func send(recordName: String,
              conversationID: String,
              recipientID: String,
              text: String,
              sentAt: Date) async -> String? {
        struct Req: Encodable {
            let id: String; let conversationID: String; let recipientID: String
            let text: String; let sentAt: Double
        }
        let body = Req(id: recordName, conversationID: conversationID, recipientID: recipientID,
                       text: text, sentAt: sentAt.timeIntervalSince1970 * 1000)
        guard (try? await backend.authorized("/messages", method: "POST", body: body)) != nil else {
            return nil    // offline / no session — caller keeps it pendingUpload and retries
        }
        return recordName
    }

    /// Remove MY OWN message from the shared store — the "delete conversation" path, matching what
    /// CloudKit's `deleteRecord` did, so a deleted thread doesn't linger as a wall of tombstones.
    /// Sender-only and unwindowed, enforced server-side. Best-effort: a failure leaves the row, which
    /// the caller tolerates because its local tombstone is durable regardless.
    func delete(remoteID: String) async {
        _ = try? await backend.authorized("/messages/\(remoteID)?hard=1", method: "DELETE")
    }

    /// "Delete for everyone" — a SOFT delete: the row stays, flagged `deleted` with the ciphertext
    /// stripped, so the recipient's next sync flips their copy to a tombstone instead of the message
    /// silently vanishing. Sender-only AND inside the 24h window, both enforced server-side now; on the
    /// client alone that was never a rule, just a hidden button.
    func deleteForEveryone(remoteID: String) async {
        _ = try? await backend.authorized("/messages/\(remoteID)", method: "DELETE")
    }

    /// Publish (upsert) the signed-in reader's "read up to `lastReadAt`" marker for a conversation.
    /// `readerID` is accepted for call-site symmetry but NOT sent — the server stamps the authenticated
    /// caller, so nobody can mark someone else's thread as seen.
    @discardableResult
    func publishReadReceipt(conversationID: String, readerID: String, lastReadAt: Date) async -> Bool {
        struct Req: Encodable { let conversationID: String; let lastReadAt: Double }
        let body = Req(conversationID: conversationID, lastReadAt: lastReadAt.timeIntervalSince1970 * 1000)
        return (try? await backend.authorized("/messages/read", method: "POST", body: body)) != nil
    }

    /// Fetch the counterpart's read marker for a conversation. Nil if they've never read, or offline.
    func fetchReadReceipt(conversationID: String, readerID: String) async -> RemoteReadReceipt? {
        guard let data = try? await backend.authorized("/messages/read", query: [
            URLQueryItem(name: "conversationID", value: conversationID),
            URLQueryItem(name: "readerID", value: readerID),
        ]) else { return nil }
        return try? JSONDecoder().decode(RemoteReadReceipt.self, from: data)
    }

    /// Every message involving this user, in both directions. `ownerID` is accepted for call-site
    /// symmetry but NOT sent: the server answers only for the authenticated caller, which is precisely
    /// the authorization the CloudKit version could not express.
    func fetchMessages(for ownerID: String) async -> [RemoteMessage] {
        await fetch(query: [])
    }

    /// A single thread — used when opening a conversation, so it refreshes without a full sync.
    func fetchThread(conversationID: String) async -> [RemoteMessage] {
        await fetch(query: [URLQueryItem(name: "conversationID", value: conversationID)])
    }

    private func fetch(query: [URLQueryItem]) async -> [RemoteMessage] {
        struct Resp: Decodable { let messages: [RemoteMessage] }
        guard let data = try? await backend.authorized("/messages", query: query),
              let resp = try? JSONDecoder().decode(Resp.self, from: data) else { return [] }
        return resp.messages
    }
}
