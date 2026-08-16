import Foundation
import CloudKit

/// A training program as it exists in the shared public store (plain DTO decoded from a CKRecord).
struct RemoteProgram {
    let id: String
    let ownerID: String
    let title: String
    let summary: String
    let order: Int
    /// Whether the record carries a cover photo, known from the metadata query without downloading it.
    let hasCover: Bool
    let createdAt: Date
    let updatedAt: Date

    init?(record: CKRecord) {
        guard let ownerID = record["ownerID"] as? String else { return nil }
        id = record.recordID.recordName
        self.ownerID = ownerID
        title = record["title"] as? String ?? ""
        summary = record["summary"] as? String ?? ""
        order = record["order"] as? Int ?? 0
        hasCover = (record["hasCover"] as? Int ?? 0) == 1
        createdAt = record["createdAt"] as? Date ?? .distantPast
        updatedAt = record["updatedAt"] as? Date ?? .distantPast
    }
}

/// Instructor-authored training programs over CloudKit's **public** database, shaped exactly like
/// `LessonTypeService`: an author-owned record read by everyone (`_world` read / `_creator` write), keyed
/// deterministically (`program-<localID>`) so a re-publish upserts instead of forking. The `Program`
/// `@Model` in UserData caches it. See [[FloweEducation]].
@MainActor
final class ProgramService {
    static let recordType = "Program"

    private static let coversPerSync = 12

    /// Everything on a program *except* the cover photo (the asset comes afterwards from `fetchCovers`).
    static let programMetadataKeys = ["ownerID", "title", "summary", "order", "hasCover", "createdAt", "updatedAt"]

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    /// Create or edit a program — one deterministic upsert (fetch-then-mutate, last-writer-wins retry).
    func upsert(localID: UUID,
                ownerID: String,
                title: String,
                summary: String,
                order: Int,
                createdAt: Date,
                cover: Data?) async -> String? {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: "program-\(localID.uuidString)")
        let record = (try? await database.record(for: id)) ?? CKRecord(recordType: Self.recordType, recordID: id)

        let staged = cover.flatMap { Self.stageAsset($0) }
        defer { staged.map { try? FileManager.default.removeItem(at: $0) } }

        Self.apply(to: record, ownerID: ownerID, title: title, summary: summary, order: order, createdAt: createdAt, staged: staged)

        do {
            let saved = try await database.save(record)
            return saved.recordID.recordName
        } catch let error as CKError where error.code == .serverRecordChanged {
            guard let server = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord else { return nil }
            Self.apply(to: server, ownerID: ownerID, title: title, summary: summary, order: order, createdAt: createdAt, staged: staged)
            let saved = try? await database.save(server)
            return saved?.recordID.recordName
        } catch {
            return nil   // offline / not signed into iCloud / schema not deployed
        }
        #else
        return nil
        #endif
    }

    /// Delete a program. Only its author can (enforced by the public database).
    func delete(id: String) async -> Bool {
        #if CLOUDKIT_ENABLED
        return await delete(CKRecord.ID(recordName: id))
        #else
        return false
        #endif
    }

    /// One instructor's own programs — a profile attribute, so a student sees all of them.
    func fetch(ownerID: String) async -> [RemoteProgram] {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(format: "ownerID == %@", ownerID))
        do {
            let (matches, _) = try await database.records(
                matching: query, desiredKeys: Self.programMetadataKeys, resultsLimit: 200
            )
            return matches.compactMap { try? $0.1.get() }.compactMap(RemoteProgram.init)
        } catch {
            return []
        }
        #else
        return []
        #endif
    }

    /// Download cover photos for specific programs, capped at `coversPerSync`. Keyed by record name.
    func fetchCovers(ids: [String]) async -> [String: Data] {
        #if CLOUDKIT_ENABLED
        let wanted = Array(ids.prefix(Self.coversPerSync))
        guard !wanted.isEmpty else { return [:] }
        let recordIDs = wanted.map { CKRecord.ID(recordName: $0) }
        guard let results = try? await database.records(for: recordIDs, desiredKeys: ["cover"]) else { return [:] }
        var images: [String: Data] = [:]
        for (id, result) in results {
            guard let record = try? result.get(),
                  let url = (record["cover"] as? CKAsset)?.fileURL,
                  let data = try? Data(contentsOf: url) else { continue }
            images[id.recordName] = data
        }
        return images
        #else
        return [:]
        #endif
    }

    /// Remove every program this owner created — the account-deletion sweep.
    func removeAll(ownerID: String) async {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(format: "ownerID == %@", ownerID))
        guard let (matches, _) = try? await database.records(matching: query, desiredKeys: [], resultsLimit: 200) else { return }
        let ids = matches.map(\.0)
        guard !ids.isEmpty else { return }
        _ = try? await database.modifyRecords(saving: [], deleting: ids)
        #endif
    }

    // MARK: - Shared plumbing
    #if CLOUDKIT_ENABLED
    private static func apply(to record: CKRecord, ownerID: String, title: String, summary: String, order: Int, createdAt: Date, staged: URL?) {
        record["ownerID"] = ownerID
        record["title"] = title
        record["summary"] = summary
        record["order"] = order
        record["createdAt"] = createdAt
        record["updatedAt"] = Date()
        record["cover"] = staged.map { CKAsset(fileURL: $0) }
        record["hasCover"] = staged == nil ? 0 : 1
    }

    private static func stageAsset(_ data: Data) -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("program-cover-\(UUID().uuidString).jpg")
        do { try data.write(to: url); return url } catch { return nil }
    }

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
