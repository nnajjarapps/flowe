import Foundation
import CloudKit

/// A lesson type as it exists in the shared public store (plain DTO decoded from a CKRecord).
struct RemoteLessonType {
    let id: String
    let ownerID: String
    let name: String
    let details: String
    let durationMinutes: Int
    let capacity: Int
    /// Kept optional — a record with no `price` key is "not stated" (nil), a `0` is genuinely free.
    let price: Int?
    let order: Int
    /// No-Show Shield policy, published so the student sees it before booking.
    let cancelWindowHours: Int
    let cancelFee: Int
    let cancelFeeIsPercent: Bool
    /// Whether the record carries a highlight photo, known from the metadata query, which does not
    /// download the asset itself — see `LessonTypeService.lessonTypeMetadataKeys`.
    let hasHighlight: Bool
    let createdAt: Date
    /// Carried so the conflict retry and the merge can resolve last-writer-wins.
    let updatedAt: Date

    init?(record: CKRecord) {
        // `ownerID` is the one field a type cannot be attributed without — everything else has a safe
        // default. Its absence means a record we can't attribute, so it is dropped. Mirrors
        // `RemoteEvent.init` guarding on `organizerID`.
        guard let ownerID = record["ownerID"] as? String else { return nil }
        id = record.recordID.recordName
        self.ownerID = ownerID
        name = record["name"] as? String ?? ""
        details = record["details"] as? String ?? ""
        durationMinutes = record["durationMinutes"] as? Int ?? 0
        capacity = record["capacity"] as? Int ?? 0
        // `as? Int` on a missing key yields nil — exactly the "not stated" state we want to keep.
        price = record["price"] as? Int
        order = record["order"] as? Int ?? 0
        cancelWindowHours = record["cancelWindowHours"] as? Int ?? 0
        cancelFee = record["cancelFee"] as? Int ?? 0
        cancelFeeIsPercent = (record["cancelFeeIsPercent"] as? Int ?? 0) == 1
        hasHighlight = (record["hasHighlight"] as? Int ?? 0) == 1
        createdAt = record["createdAt"] as? Date ?? .distantPast
        updatedAt = record["updatedAt"] as? Date ?? .distantPast
    }
}

/// Instructor-authored lesson types over CloudKit's **public** database, shaped exactly like
/// `EventService`: an author-owned record read by everyone (`_world` read / `_creator` write), keyed
/// deterministically so a re-publish upserts instead of forking. SwiftData can only mirror the
/// *private* database, which is per-iCloud-account, so a type one instructor writes could never reach
/// a student that way — hence the raw public-DB record with a `LessonType` `@Model` cache.
///
/// Unlike an event there is no registration/attendee machinery: a lesson type is 100% descriptive and
/// publishes every field, so there is no live count and no `admitted`-style reconciliation to run.
@MainActor
final class LessonTypeService {
    static let recordType = "LessonType"

    /// How many highlight photos one sync will pull. Matches `EventService`: a hero is the subject of
    /// its row and a per-instructor list is short, so a pass takes the newest slice and the next sync
    /// takes the rest.
    private static let imagesPerSync = 12

    /// Everything on a lesson type *except* the highlight photo.
    ///
    /// The list query asks for exactly these. Passing `desiredKeys: nil` would download every attached
    /// `CKAsset` too — one photo per type on every refresh, most for rows the reader never scrolls to.
    /// Photos come afterwards from `fetchPhotos`, once, per type.
    static let lessonTypeMetadataKeys = [
        "ownerID", "name", "details", "durationMinutes", "capacity", "price",
        "order", "cancelWindowHours", "cancelFee", "cancelFeeIsPercent",
        "hasHighlight", "createdAt", "updatedAt",
    ]

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    /// Create or edit a lesson type — one deterministic upsert, because the recordName is derived from
    /// `localID` and the author is always the record's creator.
    ///
    /// Fetch-then-mutate so an edit preserves fields it doesn't touch and a re-publish overwrites the
    /// same record rather than duplicating it. Returns the remote id, or nil if it didn't reach the
    /// server.
    func upsert(localID: UUID,
                ownerID: String,
                name: String,
                details: String,
                durationMinutes: Int,
                capacity: Int,
                price: Int?,
                order: Int,
                policy: CancellationPolicy,
                createdAt: Date,
                highlight: Data?) async -> String? {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: "lessontype-\(localID.uuidString)")
        let record = (try? await database.record(for: id)) ?? CKRecord(recordType: Self.recordType, recordID: id)

        // A CKAsset uploads from a file, so the photo has to be staged on disk for the save. The
        // staged URL must outlive a possible conflict retry, so `defer` (fires on return) cleans up.
        let staged = highlight.flatMap { Self.stageAsset($0) }
        defer { staged.map { try? FileManager.default.removeItem(at: $0) } }

        Self.apply(
            to: record, ownerID: ownerID, name: name, details: details,
            durationMinutes: durationMinutes, capacity: capacity, price: price,
            order: order, policy: policy, createdAt: createdAt, staged: staged
        )

        do {
            let saved = try await database.save(record)
            return saved.recordID.recordName
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Last-writer-wins: take the server record, re-apply our fields onto it, retry once. The
            // staged file outlives this block (`defer` fires on return), so the retry can reuse it —
            // otherwise a conflicting save would silently drop the new photo.
            guard let server = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord else {
                return nil
            }
            Self.apply(
                to: server, ownerID: ownerID, name: name, details: details,
                durationMinutes: durationMinutes, capacity: capacity, price: price,
                order: order, policy: policy, createdAt: createdAt, staged: staged
            )
            let saved = try? await database.save(server)
            return saved?.recordID.recordName
        } catch {
            return nil   // offline / not signed into iCloud / schema not deployed
        }
        #else
        return nil
        #endif
    }

    /// Delete a lesson type. Only its author can, enforced by the public database. Returns whether the
    /// type is now gone from the server.
    func delete(id: String) async -> Bool {
        #if CLOUDKIT_ENABLED
        return await delete(CKRecord.ID(recordName: id))
        #else
        return false
        #endif
    }

    /// One instructor's own lesson types. No time bound, no visibility filter — a type is a profile
    /// attribute, not broadcast content, so a student viewing that instructor sees all of them.
    func fetch(ownerID: String) async -> [RemoteLessonType] {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.recordType,
                            predicate: NSPredicate(format: "ownerID == %@", ownerID))
        do {
            let (matches, _) = try await database.records(
                matching: query, desiredKeys: Self.lessonTypeMetadataKeys, resultsLimit: 200
            )
            return matches.compactMap { try? $0.1.get() }.compactMap(RemoteLessonType.init)
        } catch {
            return []   // schema not deployed / offline / no records yet
        }
        #else
        return []
        #endif
    }

    /// Download the highlight photos for specific lesson types, capped at `imagesPerSync`.
    ///
    /// Keyed by record name; a type whose fetch failed is simply absent, so the caller keeps whatever
    /// it already had rather than caching an empty image over a good one.
    func fetchPhotos(ids: [String]) async -> [String: Data] {
        #if CLOUDKIT_ENABLED
        let wanted = Array(ids.prefix(Self.imagesPerSync))
        guard !wanted.isEmpty else { return [:] }
        let recordIDs = wanted.map { CKRecord.ID(recordName: $0) }
        guard let results = try? await database.records(for: recordIDs, desiredKeys: ["highlight"]) else {
            return [:]
        }
        var images: [String: Data] = [:]
        for (id, result) in results {
            guard let record = try? result.get(),
                  let url = (record["highlight"] as? CKAsset)?.fileURL,
                  // Read now: CloudKit reclaims the staged copy once this scope ends.
                  let data = try? Data(contentsOf: url) else { continue }
            images[id.recordName] = data
        }
        return images
        #else
        return [:]
        #endif
    }

    /// Remove every lesson type this owner created — the account-deletion sweep, mirroring how
    /// `AccountDeletionService` sweeps events by `organizerID`.
    func removeAll(ownerID: String) async {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.recordType,
                            predicate: NSPredicate(format: "ownerID == %@", ownerID))
        guard let (matches, _) = try? await database.records(
            matching: query, desiredKeys: [], resultsLimit: 200
        ) else { return }
        let ids = matches.map(\.0)
        guard !ids.isEmpty else { return }
        _ = try? await database.modifyRecords(saving: [], deleting: ids)
        #endif
    }

    // MARK: - Shared plumbing

    #if CLOUDKIT_ENABLED

    /// Write every author-owned field onto a record — shared by the create/edit save and the conflict
    /// retry so the two can never apply a different set. `hasHighlight` is derived from whether the
    /// photo actually staged, not from `highlight != nil`: a photo that failed to stage is a type
    /// without one, and claiming otherwise leaves every reader reserving space for an asset that will
    /// never arrive.
    private static func apply(to record: CKRecord,
                              ownerID: String,
                              name: String,
                              details: String,
                              durationMinutes: Int,
                              capacity: Int,
                              price: Int?,
                              order: Int,
                              policy: CancellationPolicy,
                              createdAt: Date,
                              staged: URL?) {
        record["ownerID"] = ownerID
        record["name"] = name
        record["details"] = details
        record["durationMinutes"] = durationMinutes
        record["capacity"] = capacity
        // Assigning nil removes the key, which is how "price not stated" reaches other devices; a
        // free type writes 0.
        record["price"] = price
        record["order"] = order
        // No-Show Shield policy — published so the student sees it pre-booking.
        record["cancelWindowHours"] = policy.windowHours
        record["cancelFee"] = policy.fee
        record["cancelFeeIsPercent"] = policy.feeIsPercent ? 1 : 0
        record["createdAt"] = createdAt
        record["updatedAt"] = Date()
        record["highlight"] = staged.map { CKAsset(fileURL: $0) }
        // CKRecord has no boolean, so `hasHighlight` is an Int 0/1, set from staging success.
        record["hasHighlight"] = staged == nil ? 0 : 1
    }

    /// Write image bytes to a temp file so `CKAsset` can upload them. Nil simply means this save
    /// carries no photo rather than failing the whole publish — the type is still worth creating.
    private static func stageAsset(_ data: Data) -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lessontype-photo-\(UUID().uuidString).jpg")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// A record that is already absent is the goal state, not a failure — a type deleted from another
    /// device, or a delete sent twice.
    private func delete(_ id: CKRecord.ID) async -> Bool {
        do {
            _ = try await database.deleteRecord(withID: id)
            return true
        } catch let error as CKError where error.code == .unknownItem {
            return true
        } catch {
            return false
        }
    }

    #endif
}
