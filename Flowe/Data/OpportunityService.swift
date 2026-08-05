import Foundation
import CloudKit

/// An opportunity as it exists in the shared catalog (plain DTO decoded from a CKRecord). World-readable
/// like the rest of the public DB — the POST is public; an application (a later phase) is what stays
/// private to the poster. See [[FlowePro]].
struct RemoteOpportunity {
    let id: String              // recordName — "opp-<localID>"
    let posterID: String
    let posterName: String
    let kind: Int
    let eligibility: Int
    let status: Int
    let title: String
    let about: String
    let location: String
    let latitude: Double?
    let longitude: Double?
    let payText: String
    let commitment: String
    let startsAt: Date?
    let createdAt: Date

    init?(record: CKRecord) {
        guard let posterID = record["posterID"] as? String else { return nil }
        id = record.recordID.recordName
        self.posterID = posterID
        posterName = record["posterName"] as? String ?? ""
        kind = record["kind"] as? Int ?? 0
        eligibility = record["eligibility"] as? Int ?? 0
        status = record["status"] as? Int ?? 0
        title = record["title"] as? String ?? ""
        about = record["about"] as? String ?? ""
        location = record["location"] as? String ?? ""
        latitude = record["latitude"] as? Double
        longitude = record["longitude"] as? Double
        payText = record["payText"] as? String ?? ""
        commitment = record["commitment"] as? String ?? ""
        startsAt = record["startsAt"] as? Date
        createdAt = record["createdAt"] as? Date ?? .distantPast
    }
}

/// An application to an opportunity as it exists in the shared store (DTO). Addressed to the poster by
/// `posterID`; reveals the applicant (pilot deanon posture, like coverage claims).
struct RemoteOpportunityApplication {
    let id: String              // recordName — "oppapp-<opportunityID>-<applicantID>"
    let opportunityID: String
    let posterID: String
    let applicantID: String
    let applicantName: String
    let applicantRole: Int
    let note: String
    let withdrawn: Bool
    let createdAt: Date

    init?(record: CKRecord) {
        guard let opportunityID = record["opportunityID"] as? String,
              let posterID = record["posterID"] as? String else { return nil }
        id = record.recordID.recordName
        self.opportunityID = opportunityID
        self.posterID = posterID
        applicantID = record["applicantID"] as? String ?? ""
        applicantName = record["applicantName"] as? String ?? ""
        applicantRole = record["applicantRole"] as? Int ?? 1
        note = record["note"] as? String ?? ""
        withdrawn = (record["withdrawn"] as? Int ?? 0) == 1
        createdAt = record["createdAt"] as? Date ?? .distantPast
    }
}

/// A poster's decision on an application (DTO). Addressed to the applicant by `applicantID`.
struct RemoteApplicationDecision {
    let id: String              // recordName — "oppdec-<opportunityID>-<applicantID>"
    let opportunityID: String
    let applicantID: String
    let posterID: String
    let stage: Int
    let updatedAt: Date

    init?(record: CKRecord) {
        guard let applicantID = record["applicantID"] as? String,
              let opportunityID = record["opportunityID"] as? String else { return nil }
        id = record.recordID.recordName
        self.applicantID = applicantID
        self.opportunityID = opportunityID
        posterID = record["posterID"] as? String ?? ""
        stage = record["stage"] as? Int ?? 0
        updatedAt = record["updatedAt"] as? Date ?? .distantPast
    }
}

/// Career-marketplace opportunities over CloudKit's **public** database, mirroring [[CatalogService]] /
/// [[CoverageService]]: raw `CKRecord` CRUD, `_creator`-write + `_world`-read, deterministic recordName
/// (`opp-<localID>`) so re-publishing an edited post upserts rather than duplicates. The poster owns the
/// record; browsers query it by `status`, the poster queries their own by `posterID`.
@MainActor
final class OpportunityService {
    static let recordType = "Opportunity"

    /// CloudKit rejects an unbounded query; a pilot is nowhere near this.
    private static let fetchLimit = 200

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    /// Upsert an opportunity under its deterministic recordName. Returns the saved recordName, or nil
    /// when the write didn't reach the server (offline / not signed in / schema not deployed).
    @discardableResult
    func publish(recordName: String,
                 posterID: String, posterName: String,
                 kind: Int, eligibility: Int, status: Int,
                 title: String, about: String, location: String,
                 latitude: Double?, longitude: Double?,
                 payText: String, commitment: String,
                 startsAt: Date?, createdAt: Date) async -> String? {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: recordName)
        let record = (try? await database.record(for: id)) ?? CKRecord(recordType: Self.recordType, recordID: id)
        record["posterID"] = posterID
        record["posterName"] = posterName
        record["kind"] = kind
        record["eligibility"] = eligibility
        record["status"] = status
        record["title"] = title
        record["about"] = about
        record["location"] = location
        record["latitude"] = latitude
        record["longitude"] = longitude
        record["payText"] = payText
        record["commitment"] = commitment
        record["startsAt"] = startsAt
        if record["createdAt"] == nil { record["createdAt"] = createdAt }   // keep the original post time
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

    /// Open opportunities for the browse feed. Nil when the query failed (offline / schema not deployed),
    /// distinct from an empty array (genuinely none open).
    func fetchOpen() async -> [RemoteOpportunity]? {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(format: "status == 0"))
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        do {
            let (matches, _) = try await database.records(matching: query, resultsLimit: Self.fetchLimit)
            return matches.compactMap { try? $0.1.get() }.compactMap(RemoteOpportunity.init)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// The signed-in poster's own opportunities (any status), for their manage screen.
    func fetchMine(posterID: String) async -> [RemoteOpportunity]? {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(format: "posterID == %@", posterID))
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        do {
            let (matches, _) = try await database.records(matching: query, resultsLimit: Self.fetchLimit)
            return matches.compactMap { try? $0.1.get() }.compactMap(RemoteOpportunity.init)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Flip an opportunity's status (close / mark filled). Only its creator (the poster) can, which the
    /// `_creator`-write role enforces. Returns whether the change reached the server.
    @discardableResult
    func setStatus(recordName: String, status: Int) async -> Bool {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: recordName)
        guard let record = try? await database.record(for: id) else { return false }
        record["status"] = status
        return (try? await database.save(record)) != nil
        #else
        return false
        #endif
    }

    func delete(recordName: String) async {
        #if CLOUDKIT_ENABLED
        _ = try? await database.deleteRecord(withID: CKRecord.ID(recordName: recordName))
        #endif
    }

    // MARK: - Applications (Flowe Pro Phase 4)

    static let applicationRecordType = "OpportunityApplication"
    /// The field an application addresses its recipient (the poster) by — drives the poster's inbox
    /// query and any future push subscription. Never the applicant, who wrote it.
    static let applicationRecipientField = "posterID"

    /// Apply (or update/withdraw) — the applicant's own record, deterministic name so applying twice
    /// upserts rather than duplicates. `_creator`-write fits (the applicant owns it).
    @discardableResult
    func applyToOpportunity(recordName: String, opportunityID: String, posterID: String,
                            applicantID: String, applicantName: String, applicantRole: Int,
                            note: String, withdrawn: Bool, createdAt: Date) async -> String? {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: recordName)
        let record = (try? await database.record(for: id)) ?? CKRecord(recordType: Self.applicationRecordType, recordID: id)
        record["opportunityID"] = opportunityID
        record["posterID"] = posterID
        record["applicantID"] = applicantID
        record["applicantName"] = applicantName
        record["applicantRole"] = applicantRole
        record["note"] = note
        record["withdrawn"] = withdrawn ? 1 : 0
        if record["createdAt"] == nil { record["createdAt"] = createdAt }
        do { let saved = try await database.save(record); return saved.recordID.recordName }
        catch { return nil }
        #else
        return nil
        #endif
    }

    /// Applications the signed-in POSTER has received (their inbox across all their opportunities).
    func fetchApplications(posterID: String) async -> [RemoteOpportunityApplication]? {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.applicationRecordType,
                            predicate: NSPredicate(format: "posterID == %@", posterID))
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        do {
            let (matches, _) = try await database.records(matching: query, resultsLimit: Self.fetchLimit)
            return matches.compactMap { try? $0.1.get() }.compactMap(RemoteOpportunityApplication.init)
        } catch { return nil }
        #else
        return nil
        #endif
    }

    /// The signed-in APPLICANT's own applications (to resolve "did I apply / what's my status").
    func fetchMyApplications(applicantID: String) async -> [RemoteOpportunityApplication]? {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.applicationRecordType,
                            predicate: NSPredicate(format: "applicantID == %@", applicantID))
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        do {
            let (matches, _) = try await database.records(matching: query, resultsLimit: Self.fetchLimit)
            return matches.compactMap { try? $0.1.get() }.compactMap(RemoteOpportunityApplication.init)
        } catch { return nil }
        #else
        return nil
        #endif
    }

    // MARK: - Application decisions (pipeline stage — Flowe Pro Phase 4b)

    static let decisionRecordType = "ApplicationDecision"

    /// Set (upsert) the poster's decision/stage for one application. Poster-owned (`_creator`-write),
    /// deterministic name so advancing the stage updates the same record.
    @discardableResult
    func setDecision(recordName: String, opportunityID: String, applicantID: String,
                     posterID: String, stage: Int, updatedAt: Date) async -> String? {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: recordName)
        let record = (try? await database.record(for: id)) ?? CKRecord(recordType: Self.decisionRecordType, recordID: id)
        record["opportunityID"] = opportunityID
        record["applicantID"] = applicantID
        record["posterID"] = posterID
        record["stage"] = stage
        record["updatedAt"] = updatedAt
        do { let saved = try await database.save(record); return saved.recordID.recordName }
        catch { return nil }
        #else
        return nil
        #endif
    }

    /// Decisions the signed-in POSTER has made (so their applicant rows show the current stage).
    func fetchDecisions(posterID: String) async -> [RemoteApplicationDecision]? {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.decisionRecordType,
                            predicate: NSPredicate(format: "posterID == %@", posterID))
        do {
            let (matches, _) = try await database.records(matching: query, resultsLimit: Self.fetchLimit)
            return matches.compactMap { try? $0.1.get() }.compactMap(RemoteApplicationDecision.init)
        } catch { return nil }
        #else
        return nil
        #endif
    }

    /// Decisions addressed to the signed-in APPLICANT (so they see where they stand).
    func fetchMyDecisions(applicantID: String) async -> [RemoteApplicationDecision]? {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.decisionRecordType,
                            predicate: NSPredicate(format: "applicantID == %@", applicantID))
        do {
            let (matches, _) = try await database.records(matching: query, resultsLimit: Self.fetchLimit)
            return matches.compactMap { try? $0.1.get() }.compactMap(RemoteApplicationDecision.init)
        } catch { return nil }
        #else
        return nil
        #endif
    }
}
