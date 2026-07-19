import Foundation
import CloudKit

/// A public instructor listing fetched from CloudKit (plain DTO, decoded from a CKRecord).
struct CatalogListing {
    let ownerID: String
    let name: String
    let city: String
    let bio: String?
    let price: Int
    let specialties: [String]
    let sessionTypes: [String]
    let available: [String]
    let rating: Double
    let reviews: Int
    let img: String
    let cert: String
    let visibility: Int
    let updatedAt: Date

    init?(record: CKRecord) {
        guard let name = record["name"] as? String else { return nil }
        ownerID = record.recordID.recordName
        self.name = name
        city = record["city"] as? String ?? ""
        bio = record["bio"] as? String
        price = record["price"] as? Int ?? 0
        specialties = record["specialties"] as? [String] ?? []
        sessionTypes = record["sessionTypes"] as? [String] ?? []
        available = record["available"] as? [String] ?? []
        rating = record["rating"] as? Double ?? 0
        reviews = record["reviews"] as? Int ?? 0
        img = record["img"] as? String ?? ""
        cert = record["cert"] as? String ?? ""
        visibility = record["visibility"] as? Int ?? 0
        updatedAt = record["updatedAt"] as? Date ?? .distantPast
    }
}

/// Shared instructor catalog over CloudKit's **public** database. SwiftData can't mirror a public DB,
/// so this is raw CloudKit: instructors publish their listing (recordName == ownerID, so only the
/// creator can edit it), students query the visible ones. All fields are world-readable — no PII.
@MainActor
final class CatalogService {
    static let recordType = "InstructorListing"

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    /// Upsert the instructor's own listing into the public catalog.
    func publish(_ instructor: Instructor) async {
        #if CLOUDKIT_ENABLED
        guard let ownerID = instructor.ownerID, !instructor.name.isEmpty else { return }
        let id = CKRecord.ID(recordName: ownerID)
        let record = (try? await database.record(for: id)) ?? CKRecord(recordType: Self.recordType, recordID: id)

        record["name"] = instructor.name
        record["city"] = instructor.city
        record["bio"] = instructor.bio
        record["price"] = instructor.price
        record["specialties"] = instructor.specialties
        record["sessionTypes"] = instructor.sessionTypes
        record["available"] = instructor.available
        record["rating"] = instructor.rating
        record["reviews"] = instructor.reviews
        record["img"] = instructor.img
        record["cert"] = instructor.cert
        record["visibility"] = instructor.visibilityRaw
        record["updatedAt"] = Date()

        do {
            _ = try await database.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Last-writer-wins: take the server record, re-apply our fields, retry once.
            if let server = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                server["visibility"] = instructor.visibilityRaw
                server["price"] = instructor.price
                server["updatedAt"] = Date()
                _ = try? await database.save(server)
            }
        } catch {
            // Offline / not signed into iCloud / schema not deployed — non-fatal.
        }
        #endif
    }

    /// Fetch all currently-visible listings (Boost + Visible).
    func fetchVisibleListings() async -> [CatalogListing] {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(format: "visibility > 0"))
        query.sortDescriptors = [NSSortDescriptor(key: "visibility", ascending: false)]
        do {
            let (matches, _) = try await database.records(matching: query, desiredKeys: nil, resultsLimit: 200)
            return matches.compactMap { try? $0.1.get() }.compactMap(CatalogListing.init)
        } catch {
            return []   // schema not deployed / offline / no records yet
        }
        #else
        return []
        #endif
    }

    /// Remove the instructor's listing (e.g. account deletion).
    func remove(ownerID: String) async {
        #if CLOUDKIT_ENABLED
        _ = try? await database.deleteRecord(withID: CKRecord.ID(recordName: ownerID))
        #endif
    }
}
