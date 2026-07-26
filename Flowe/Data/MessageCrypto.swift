import Foundation
import CryptoKit
import CloudKit

/// A world-readable directory of users' X25519 public keys. Two users look each other up here, derive
/// a shared secret, and exchange end-to-end-encrypted messages over the public database — so the
/// message text is opaque to everyone else who can query that same public record type.
///
/// `recordName == ownerID`, so the default `_creator`-write role already means only a user can publish
/// their own key. The public key is meant to be world-readable — that's the whole point of a directory.
@MainActor
final class PublicKeyService {
    static let recordType = "PublicKey"

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    /// Upsert my public key. A no-op when it's already the stored value, so this can run on every
    /// launch without churning the record.
    func publish(ownerID: String, publicKey: Data) async {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: ownerID)
        let record = (try? await database.record(for: id)) ?? CKRecord(recordType: Self.recordType, recordID: id)
        if let existing = record["key"] as? Data, existing == publicKey { return }
        record["key"] = publicKey
        _ = try? await database.save(record)
        #endif
    }

    /// Fetch a user's published public key, or nil if they've never published one.
    func fetch(ownerID: String) async -> Data? {
        #if CLOUDKIT_ENABLED
        guard let record = try? await database.record(for: CKRecord.ID(recordName: ownerID)) else { return nil }
        return record["key"] as? Data
        #else
        return nil
        #endif
    }
}

/// End-to-end encryption for direct messages.
///
/// Messages live on the world-readable public database (SwiftData can only mirror the private,
/// per-account database, so cross-user data has to go somewhere both people can read). That makes the
/// `text` field readable by anyone who can query the record type — so it is sealed here instead.
///
/// Scheme: each user holds a Curve25519 key-agreement keypair; the private half lives in the iCloud
/// Keychain (so it follows the Apple ID across devices and reinstalls), the public half is published to
/// `PublicKeyService`. For a conversation between two users, ECDH over (my private, their public) yields
/// a shared secret that is *identical* on both sides; HKDF over it — salted with the order-independent
/// `conversationID` — derives one symmetric key per thread, and `ChaChaPoly` seals each message with it.
///
/// Limits worth stating plainly: this protects message *text*, not the `senderName`/`recipientName`
/// metadata (a follow-up); a user with iCloud Keychain disabled who reinstalls gets a new key and can no
/// longer read their old messages; and if a counterpart has never published a key yet, a message to them
/// falls back to plaintext for that one send until their key propagates.
@MainActor
final class MessageCrypto {
    private static let privateKeyKeychainKey = "flowe.dm.x25519.private.v1"
    private static let tag = "enc.v1."
    private static let placeholder = "🔒 Message unavailable"

    private let directory = PublicKeyService()
    private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    private var publicKeyCache: [String: Curve25519.KeyAgreement.PublicKey] = [:]
    private var symmetricCache: [String: SymmetricKey] = [:]

    // MARK: - Keypair

    private func myPrivateKey() -> Curve25519.KeyAgreement.PrivateKey {
        if let key = privateKey { return key }
        if let stored = KeychainStore.get(Self.privateKeyKeychainKey, synchronizable: true),
           let data = Data(base64Encoded: stored),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            privateKey = key
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        KeychainStore.set(key.rawRepresentation.base64EncodedString(),
                          for: Self.privateKeyKeychainKey, synchronizable: true)
        privateKey = key
        return key
    }

    /// Ensure my keypair exists and my public key is published so others can message me. Cheap to call
    /// on every sign-in — the publish no-ops when unchanged.
    func activate(ownerID: String) async {
        let key = myPrivateKey()
        await directory.publish(ownerID: ownerID, publicKey: key.publicKey.rawRepresentation)
    }

    // MARK: - Shared key per conversation

    private func publicKey(for ownerID: String) async -> Curve25519.KeyAgreement.PublicKey? {
        if let cached = publicKeyCache[ownerID] { return cached }
        guard let data = await directory.fetch(ownerID: ownerID),
              let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data) else { return nil }
        publicKeyCache[ownerID] = key
        return key
    }

    /// The per-thread symmetric key: ECDH(my private, counterpart's public) → HKDF salted with the
    /// conversation id. Cached per counterpart. Nil when the counterpart has no published key.
    private func symmetricKey(counterpartID: String, conversationID: String) async -> SymmetricKey? {
        if let cached = symmetricCache[counterpartID] { return cached }
        guard let theirs = await publicKey(for: counterpartID),
              let shared = try? myPrivateKey().sharedSecretFromKeyAgreement(with: theirs) else { return nil }
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(conversationID.utf8),
            sharedInfo: Data("flowe-dm-v1".utf8),
            outputByteCount: 32
        )
        symmetricCache[counterpartID] = key
        return key
    }

    // MARK: - Seal / open

    /// Encrypt for the wire. Returns tagged ciphertext, or nil if the counterpart's key isn't available
    /// yet — the caller then falls back to sending plaintext for that one message.
    func encrypt(_ text: String, conversationID: String, counterpartID: String) async -> String? {
        guard let key = await symmetricKey(counterpartID: counterpartID, conversationID: conversationID),
              let sealed = try? ChaChaPoly.seal(Data(text.utf8), using: key) else { return nil }
        return Self.tag + sealed.combined.base64EncodedString()
    }

    /// Decrypt a wire value into plaintext for local display. An untagged value (legacy or plaintext
    /// fallback) passes through unchanged; a tagged value we can't open becomes a neutral placeholder
    /// rather than garbage.
    func decrypt(_ stored: String, conversationID: String, counterpartID: String) async -> String {
        guard stored.hasPrefix(Self.tag) else { return stored }
        let encoded = String(stored.dropFirst(Self.tag.count))
        guard let combined = Data(base64Encoded: encoded),
              let key = await symmetricKey(counterpartID: counterpartID, conversationID: conversationID),
              let box = try? ChaChaPoly.SealedBox(combined: combined),
              let opened = try? ChaChaPoly.open(box, using: key),
              let text = String(data: opened, encoding: .utf8) else {
            return Self.placeholder
        }
        return text
    }
}
