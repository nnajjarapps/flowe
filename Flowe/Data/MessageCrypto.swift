import Foundation
import CryptoKit
import OSLog
import CloudKit

/// A world-readable directory of users' X25519 public keys. Two users look each other up here, derive
/// a shared secret, and exchange end-to-end-encrypted messages over the public database — so the
/// message text is opaque to everyone else who can query that same public record type.
///
/// The record is `recordName == "pubkey-<ownerID>"` — NAMESPACED, not the bare ownerID. CloudKit
/// recordNames are unique per zone across ALL record types, and `InstructorListing` already keys its
/// record on the bare `ownerID` (see `CatalogService`); an instructor is also a messaging user, so a
/// bare-ownerID `PublicKey` would occupy that recordName first (published on every login by
/// `activateMessaging`) and make the later listing write COLLIDE ("cannot use an empty list … in record
/// type 'PublicKey'"), silently leaving every messaging-enabled instructor unpublishable/undiscoverable.
/// The `pubkey-` prefix keeps the two records distinct. The default `_creator`-write role still means
/// only a user can publish their own key (the prefix is derived from the same authenticated ownerID).
@MainActor
final class PublicKeyService {
    static let recordType = "PublicKey"

    /// Namespaced recordName — see the type doc. Publish and fetch MUST agree, so both route through here.
    static func recordName(for ownerID: String) -> String { "pubkey-\(ownerID)" }

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    /// Upsert my public key. A no-op when it's already the stored value, so this can run on every
    /// launch without churning the record.
    func publish(ownerID: String, publicKey: Data) async {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: Self.recordName(for: ownerID))
        let record = (try? await database.record(for: id)) ?? CKRecord(recordType: Self.recordType, recordID: id)
        if let existing = record["key"] as? Data, existing == publicKey { return }
        record["key"] = publicKey
        _ = try? await database.save(record)
        #endif
    }

    /// Fetch a user's published public key, or nil if they've never published one.
    func fetch(ownerID: String) async -> Data? {
        #if CLOUDKIT_ENABLED
        guard let record = try? await database.record(for: CKRecord.ID(recordName: Self.recordName(for: ownerID))) else { return nil }
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
    /// Records when we FIRST saw "no local private key, but this account has a published one" — i.e. a
    /// key exists somewhere and the iCloud Keychain has not delivered it to this device yet.
    private static func keyWaitKey(_ ownerID: String) -> String { "flowe.dm.keyWaitSince.\(ownerID)" }
    /// How long to wait for the iCloud Keychain before accepting the previous key is unrecoverable and
    /// minting a new one. Sync normally lands in seconds; this bounds the outage for someone who has
    /// iCloud Keychain switched off, who will never receive the old key and still needs a working one.
    private static let keySyncGrace: TimeInterval = 15 * 60
    /// Wire prefix marking a sealed value. `nonisolated` so the model/display layer can recognise a
    /// not-yet-decrypted message without hopping to the main actor.
    private nonisolated static let tag = "enc.v1."
    /// Shown in place of a message whose ciphertext we currently can't open (the sealed value is kept in
    /// storage and re-attempted every sync — see `retryStuckMessages` — so this is transient, not final).
    nonisolated static let sealedPlaceholder = "🔒 Message unavailable"

    /// Whether a stored value is still sealed ciphertext we haven't decrypted (vs plaintext for display).
    nonisolated static func isSealed(_ stored: String) -> Bool { stored.hasPrefix(tag) }

    private let directory = PublicKeyService()
    private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    private var publicKeyCache: [String: Curve25519.KeyAgreement.PublicKey] = [:]
    private var symmetricCache: [String: SymmetricKey] = [:]
    /// Captured by `activate` so the lazy seal/open paths can verify before ever minting a key.
    private var myOwnerID: String?

    // MARK: - Keypair

    /// This device's private key IF it already exists — memory cache, then Keychain. NEVER mints.
    private func existingPrivateKey() -> Curve25519.KeyAgreement.PrivateKey? {
        if let key = privateKey { return key }
        guard let stored = KeychainStore.get(Self.privateKeyKeychainKey, synchronizable: true),
              let data = Data(base64Encoded: stored),
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) else { return nil }
        privateKey = key
        return key
    }

    /// Create and persist a fresh keypair. Only ever reached from `resolvedPrivateKey(ownerID:)`, which
    /// establishes first that this account has no key already.
    private func mintPrivateKey() -> Curve25519.KeyAgreement.PrivateKey {
        let key = Curve25519.KeyAgreement.PrivateKey()
        KeychainStore.set(key.rawRepresentation.base64EncodedString(),
                          for: Self.privateKeyKeychainKey, synchronizable: true)
        privateKey = key
        return key
    }

    /// The private key to use, minting one ONLY when this account has never had one.
    ///
    /// A nil Keychain read is NOT evidence of that. The key is `synchronizable: true`, so on a fresh
    /// install it arrives from the iCloud Keychain asynchronously — and minting inside that window
    /// overwrites the real key and permanently orphans every message ever sealed against it: ECDH with
    /// the new key derives a different shared secret, so the old ciphertext cannot be opened by anyone,
    /// ever. This is the same hazard `NoteOpen.locked` guards for client notes, one layer down.
    ///
    /// A published `PublicKey` record is the evidence that a private key exists somewhere, so when one
    /// is found we WAIT instead of minting, bounded by `keySyncGrace`. Account deletion is unaffected:
    /// `AccountDeletionService` deletes the `pubkey-` record, so a genuinely fresh identity finds none
    /// here and mints immediately.
    ///
    /// Returns nil while waiting — callers must treat that as "locked, retry later", never as "no key".
    private func resolvedPrivateKey(ownerID: String) async -> Curve25519.KeyAgreement.PrivateKey? {
        let defaults = UserDefaults.standard
        let waitKey = Self.keyWaitKey(ownerID)
        if let key = existingPrivateKey() {
            defaults.removeObject(forKey: waitKey)
            return key
        }
        // Ask BOTH sources before concluding no key has ever existed, and mint only if BOTH say no.
        // The CloudKit `PublicKey` record is per-CONTAINER: a debug build queries Development, so on a
        // fresh device it would find nothing and mint — destroying the production key it shares through
        // the iCloud Keychain. The backend marker is environment-independent and closes that hole.
        var keyExistsElsewhere = await directory.fetch(ownerID: ownerID) != nil
        if !keyExistsElsewhere {
            keyExistsElsewhere = await FloweBackendClient.shared.fetchMyProfile()?.dmKeyAt != nil
        }
        guard keyExistsElsewhere else {
            defaults.removeObject(forKey: waitKey)
            return mintPrivateKey()
        }
        guard let since = defaults.object(forKey: waitKey) as? Date else {
            defaults.set(Date(), forKey: waitKey)
            return nil
        }
        guard Date().timeIntervalSince(since) >= Self.keySyncGrace else { return nil }
        defaults.removeObject(forKey: waitKey)
        return mintPrivateKey()
    }

    /// Private key for the lazy seal/open paths. Never mints blind: without a known ownerID there is no
    /// way to check whether a key already exists, so it reports "locked" rather than risk destroying one.
    private func usablePrivateKey() async -> Curve25519.KeyAgreement.PrivateKey? {
        if let key = existingPrivateKey() { return key }
        guard let ownerID = myOwnerID else { return nil }
        return await resolvedPrivateKey(ownerID: ownerID)
    }

    /// True once this device holds its own private key — false only in the narrow window where a key
    /// exists for this account but the iCloud Keychain has not delivered it yet. Callers about to fall
    /// back to sending PLAINTEXT must check this: a miss here is ours, not the recipient's.
    var hasLocalKey: Bool { existingPrivateKey() != nil }

    /// Ensure my keypair exists and my public key is published so others can message me. Cheap to call
    /// on every sign-in — the publish no-ops when unchanged.
    func activate(ownerID: String) async {
        myOwnerID = ownerID
        // nil = a key exists for this account but hasn't synced yet; publishing a freshly minted one
        // here is exactly the overwrite this guards against, so do nothing and retry next activation.
        guard let key = await resolvedPrivateKey(ownerID: ownerID) else {
            // Waiting for the iCloud Keychain to deliver an existing key. Legitimate, but it means no
            // key marker and no published public key this launch, so it must not be silent.
            FloweLog.sync.notice("DM key not available yet — waiting for iCloud Keychain, messaging is inactive this launch")
            return
        }
        // Report BEFORE publishing, deliberately. `publish` is a CloudKit round-trip that can stall or
        // fail — a bad account state, no network, an unhealthy container — and when it did, this line
        // never ran. That is why `dm_key_at` stayed NULL on a device whose key demonstrably existed:
        // the marker was gated behind an unrelated network call. Its whole job is to record that a key
        // EXISTS, and that is true the moment we hold one.
        await FloweBackendClient.shared.reportDMKeyPublished()
        await directory.publish(ownerID: ownerID, publicKey: key.publicKey.rawRepresentation)
    }

    /// Erase this device's DM identity on ACCOUNT DELETION. The private key lives in the iCloud Keychain
    /// (`synchronizable: true`), so without this it survives deletion + reinstall and syncs back on
    /// re-signin — `activate` would then re-publish the SAME public key, making the "new" account
    /// cryptographically the old one and leaving old sealed messages decryptable. Dropping the key (and
    /// the derived caches) forces a fresh keypair the next time messaging is used.
    func wipeIdentity() {
        KeychainStore.set(nil, for: Self.privateKeyKeychainKey, synchronizable: true)
        privateKey = nil
        publicKeyCache.removeAll()
        symmetricCache.removeAll()
        if let ownerID = myOwnerID { UserDefaults.standard.removeObject(forKey: Self.keyWaitKey(ownerID)) }
        myOwnerID = nil
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
              let mine = await usablePrivateKey(),
              let shared = try? mine.sharedSecretFromKeyAgreement(with: theirs) else { return nil }
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

    /// Decrypt a wire value into plaintext. An untagged value (legacy or plaintext fallback) passes
    /// through unchanged. Returns `nil` ONLY for a sealed value we couldn't open *right now* — the caller
    /// keeps the sealed wire value and retries later, so a transient miss (key-propagation lag, a flaky
    /// read, or the sender rotating keys) never gets frozen as a lost placeholder. On such a miss we also
    /// drop this counterpart's cached key so a rotated / late-published key is re-fetched next attempt.
    func decrypt(_ stored: String, conversationID: String, counterpartID: String) async -> String? {
        guard stored.hasPrefix(Self.tag) else { return stored }
        let encoded = String(stored.dropFirst(Self.tag.count))
        if let combined = Data(base64Encoded: encoded),
           let key = await symmetricKey(counterpartID: counterpartID, conversationID: conversationID),
           let box = try? ChaChaPoly.SealedBox(combined: combined),
           let opened = try? ChaChaPoly.open(box, using: key),
           let text = String(data: opened, encoding: .utf8) {
            return text
        }
        symmetricCache[counterpartID] = nil
        publicKeyCache[counterpartID] = nil
        return nil
    }
}

/// The outcome of opening a sealed value. `.locked` (ciphertext present but the key isn't on this device
/// yet — e.g. the note rows synced before the iCloud-Keychain key did) MUST NOT be treated as `.empty`
/// and overwritten, or real health data is destroyed.
enum NoteOpen<T> { case value(T), empty, locked }

/// Encryption-at-rest for the instructor's PRIVATE ClientNotes (health-adjacent data). One symmetric key
/// per instructor lives in their **iCloud Keychain** (`synchronizable` — E2E-protected by Apple, syncs
/// across the instructor's own devices, and is SEPARATE from the CloudKit data path). The CloudKit private
/// mirror therefore stores only ciphertext, so iCloud never holds readable health information (App Store
/// Guideline 5.1.3). Wiped on account deletion.
@MainActor
final class NoteCrypto {
    private static let keyKeychainKey = "flowe.clientnote.key.v1"
    private var cached: SymmetricKey?

    /// The key IF it already exists — NEVER mints one. Reads use this, so a key that is merely mid-sync
    /// can't be clobbered by this device lazily generating a fresh one and racing it into iCloud Keychain.
    private func existingKey() -> SymmetricKey? {
        if let k = cached { return k }
        guard let stored = KeychainStore.get(Self.keyKeychainKey, synchronizable: true),
              let data = Data(base64Encoded: stored) else { return nil }
        let k = SymmetricKey(data: data); cached = k; return k
    }

    /// The key, minting + persisting one only if none exists. Used ONLY for writes (an active save), where
    /// a brand-new instructor legitimately needs their first key.
    private func orCreateKey() -> SymmetricKey {
        if let k = existingKey() { return k }
        let k = SymmetricKey(size: .bits256)
        KeychainStore.set(k.withUnsafeBytes { Data($0) }.base64EncodedString(),
                          for: Self.keyKeychainKey, synchronizable: true)
        cached = k
        return k
    }

    /// Seal a Codable value → base64 ciphertext ("" only on an encode/seal failure; a blank note still
    /// seals to non-empty ciphertext of an empty payload).
    func seal<T: Encodable>(_ value: T) -> String {
        guard let plain = try? JSONEncoder().encode(value),
              let box = try? ChaChaPoly.seal(plain, using: orCreateKey()) else { return "" }
        return box.combined.base64EncodedString()
    }

    /// Open base64 ciphertext. `.empty` = nothing stored; `.locked` = ciphertext present but the key is
    /// absent/undecryptable on this device (caller must NOT overwrite it); `.value` = decrypted.
    func open<T: Decodable>(_ stored: String, as type: T.Type) -> NoteOpen<T> {
        if stored.isEmpty { return .empty }
        guard let key = existingKey(),
              let data = Data(base64Encoded: stored),
              let box = try? ChaChaPoly.SealedBox(combined: data),
              let plain = try? ChaChaPoly.open(box, using: key),
              let value = try? JSONDecoder().decode(type, from: plain) else { return .locked }
        return .value(value)
    }

    /// Drop the key on account deletion so a re-created account gets a fresh one (old ciphertext is unreadable).
    func wipe() {
        KeychainStore.set(nil, for: Self.keyKeychainKey, synchronizable: true)
        cached = nil
    }
}
