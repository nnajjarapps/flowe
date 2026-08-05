import Foundation
import CloudKit

/// A peer recommendation as it exists in the shared catalog (plain DTO decoded from a CKRecord).
/// World-readable social proof, like the rest of the public DB. See [[FlowePro]].
struct RemoteRecommendation {
    let id: String       // recordName — "rec-<fromID>-<toID>"
    let fromID: String
    let fromName: String
    let toID: String
    let text: String
    let createdAt: Date

    init?(record: CKRecord) {
        guard let toID = record["toID"] as? String else { return nil }
        id = record.recordID.recordName
        self.toID = toID
        fromID = record["fromID"] as? String ?? ""
        fromName = record["fromName"] as? String ?? ""
        text = record["text"] as? String ?? ""
        createdAt = record["createdAt"] as? Date ?? .distantPast
    }
}

/// Instructor↔instructor peer recommendations over CloudKit's **public** database, mirroring
/// [[OpportunityService]] / [[ReviewService]]: raw `CKRecord` CRUD, `_creator`-write + `_world`-read,
/// deterministic recordName (`rec-<fromID>-<toID>`) so re-writing an endorsement upserts. The author owns
/// the record; a profile queries the ones addressed to it by `toID`. See [[FlowePro]].
@MainActor
final class RecommendationService {
    static let recordType = "InstructorRecommendation"
    /// The field a recommendation addresses its recipient by — drives the recipient's profile query.
    static let recipientField = "toID"

    /// CloudKit rejects an unbounded query; a pilot is nowhere near this.
    private static let fetchLimit = 200

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    static func recordName(from fromID: String, to toID: String) -> String { "rec-\(fromID)-\(toID)" }

    /// Upsert a recommendation under its deterministic name. Returns the saved recordName, or nil when the
    /// write didn't reach the server (offline / not signed in / schema not deployed).
    @discardableResult
    func publish(recordName: String, fromID: String, fromName: String, toID: String,
                 text: String, createdAt: Date) async -> String? {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: recordName)
        let record = (try? await database.record(for: id)) ?? CKRecord(recordType: Self.recordType, recordID: id)
        record["fromID"] = fromID
        record["fromName"] = fromName
        record["toID"] = toID
        record["text"] = text
        if record["createdAt"] == nil { record["createdAt"] = createdAt }   // keep the original write time
        do {
            let saved = try await database.save(record)
            return saved.recordID.recordName
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Recommendations addressed to an instructor — the endorsements shown on their profile. Nil when the
    /// query failed (offline / schema not deployed), distinct from an empty array (genuinely none).
    func fetchFor(toID: String) async -> [RemoteRecommendation]? {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(format: "toID == %@", toID))
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        do {
            let (matches, _) = try await database.records(matching: query, resultsLimit: Self.fetchLimit)
            return matches.compactMap { try? $0.1.get() }.compactMap(RemoteRecommendation.init)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// The signed-in instructor's own written recommendations — which peers they've already endorsed.
    func fetchMine(fromID: String) async -> [RemoteRecommendation]? {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(format: "fromID == %@", fromID))
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        do {
            let (matches, _) = try await database.records(matching: query, resultsLimit: Self.fetchLimit)
            return matches.compactMap { try? $0.1.get() }.compactMap(RemoteRecommendation.init)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Remove a recommendation the author wrote — `_creator`-write lets only its author delete it.
    func delete(recordName: String) async {
        #if CLOUDKIT_ENABLED
        _ = try? await database.deleteRecord(withID: CKRecord.ID(recordName: recordName))
        #endif
    }
}
