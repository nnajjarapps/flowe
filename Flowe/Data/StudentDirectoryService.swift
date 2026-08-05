import Foundation
import CloudKit

/// A student's public profile fetched from CloudKit (plain DTO, decoded from a CKRecord). The read
/// counterpart to `CatalogListing`. `ownerID` is the recordName; `name` is the one required field.
struct StudentListing {
    let ownerID: String
    let name: String
    let bio: String?
    let memberSince: Date
    let updatedAt: Date
    let photo: Data?

    init?(record: CKRecord) {
        guard let name = record["name"] as? String else { return nil }   // name is required, else nil
        // recordName is namespaced `student-<ownerID>` (see StudentDirectoryService.recordName(for:));
        // strip the prefix so `ownerID` stays the BARE id every caller matches on.
        let rn = record.recordID.recordName
        ownerID = rn.hasPrefix("student-") ? String(rn.dropFirst("student-".count)) : rn
        self.name = name
        bio = record["bio"] as? String
        memberSince = record["memberSince"] as? Date ?? .distantPast
        updatedAt = record["updatedAt"] as? Date ?? .distantPast
        // CloudKit stages an asset as a local file; read it now, before the temp copy is reclaimed.
        photo = (record["photo"] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
    }
}

/// Shared student directory over CloudKit's **public** database. The exact counterpart to
/// `CatalogService`, minus the visibility query. SwiftData can't mirror a public DB, so this is raw
/// CloudKit: a student publishes their own profile (recordName == ownerID, so only the creator can
/// edit it), and an instructor fetches the SPECIFIC students they already transact with, by ownerID.
///
/// CRITICAL: there is no broad query here — students are NEVER enumerable or discoverable. Every read
/// is a direct record fetch by recordName (`records(for:)`), so a `StudentProfile` can only be
/// resolved by someone who already knows the exact ownerID.
@MainActor
final class StudentDirectoryService {
    static let recordType = "StudentProfile"

    /// Namespaced recordName — `student-<ownerID>`, NOT the bare ownerID. `InstructorListing`
    /// (CatalogService) already keys its record on the bare ownerID in this same public default zone,
    /// and CloudKit recordNames are unique per zone across ALL record types. A dual-role user (one Apple
    /// id that publishes both an InstructorListing and a StudentProfile — role is chosen per sign-in with
    /// no guard) would otherwise collide: the second publish fetches the wrong-typed record by that
    /// shared name, stamps foreign fields, and the locked Production schema rejects the save, leaving one
    /// role silently unpublishable (identical to the fixed PublicKey/InstructorListing collision). The
    /// `student-` prefix keeps the two records distinct; publish/fetch/remove MUST all route through here.
    static func recordName(for ownerID: String) -> String { "student-\(ownerID)" }

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    /// Upsert the student's own profile into the public directory.
    @discardableResult
    func publish(_ profile: StudentProfile) async -> Bool {
        #if CLOUDKIT_ENABLED
        guard let ownerID = profile.ownerID, !profile.name.isEmpty else { return false }
        let id = CKRecord.ID(recordName: Self.recordName(for: ownerID))
        let record = (try? await database.record(for: id)) ?? CKRecord(recordType: Self.recordType, recordID: id)

        record["name"] = profile.name
        record["bio"] = profile.bio
        record["memberSince"] = profile.memberSince
        record["updatedAt"] = Date()

        // A CKAsset is uploaded from a file, so the image has to be staged on disk for the save.
        let staged = profile.photo.flatMap { Self.stageAsset($0, name: "student-photo") }
        record["photo"] = staged.map { CKAsset(fileURL: $0) }
        defer {
            staged.map { try? FileManager.default.removeItem(at: $0) }
        }

        do {
            _ = try await database.save(record)
            return true
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Last-writer-wins: take the server record, re-apply our fields, retry once.
            if let server = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                server["name"] = profile.name
                server["bio"] = profile.bio
                server["memberSince"] = profile.memberSince
                server["updatedAt"] = Date()
                // The staged file outlives this block (`defer` fires on return), so the retry can
                // reuse it — re-applied including a nil, so a photo removal survives the conflict.
                server["photo"] = staged.map { CKAsset(fileURL: $0) }
                return (try? await database.save(server)) != nil
            }
            return false
        } catch {
            // Offline / not signed into iCloud / schema not deployed — non-fatal.
            return false
        }
        #else
        return false
        #endif
    }

    /// Fetch specific students by ownerID. CRITICAL: this is a DIRECT record fetch, never a `CKQuery`,
    /// so students stay non-enumerable — only the ones the caller already knows about come back.
    func fetch(ownerIDs: [String]) async -> [StudentListing] {
        #if CLOUDKIT_ENABLED
        guard !ownerIDs.isEmpty else { return [] }
        do {
            let results = try await database.records(for: ownerIDs.map { CKRecord.ID(recordName: Self.recordName(for: $0)) })
            return results.values.compactMap { try? $0.get() }.compactMap(StudentListing.init)
        } catch {
            return []   // schema not deployed / offline / no records yet
        }
        #else
        return []
        #endif
    }

    /// Single-record convenience over `fetch(ownerIDs:)` — used to refresh one open profile.
    func fetch(ownerID: String) async -> StudentListing? {
        #if CLOUDKIT_ENABLED
        return await fetch(ownerIDs: [ownerID]).first
        #else
        return nil
        #endif
    }

    #if CLOUDKIT_ENABLED
    /// Write image bytes to a temp file so `CKAsset` can upload them. Returns nil if the write
    /// fails, which simply means this save carries no image rather than failing outright.
    private static func stageAsset(_ data: Data, name: String) -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name)-\(UUID().uuidString).jpg")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
    #endif

    /// Remove the student's profile (e.g. account deletion).
    func remove(ownerID: String) async {
        #if CLOUDKIT_ENABLED
        _ = try? await database.deleteRecord(withID: CKRecord.ID(recordName: Self.recordName(for: ownerID)))
        #endif
    }
}
