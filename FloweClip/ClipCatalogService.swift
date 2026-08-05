import Foundation
import CloudKit

/// The slim subset of a public `InstructorListing` the Clip renders. Decoded from the SAME `CKRecord`
/// fields as the full app's `CatalogListing.init?(record:)`, so the two never disagree — but carries
/// only what the profile screen shows (name, address, bio, price, years, specialties, photo).
///
/// Intentionally NOT the full `CatalogListing`: that DTO lives in `CatalogService.swift` alongside the
/// `@MainActor CatalogService`, which references `FloweModelContainer` (SwiftData). Duplicating the
/// handful of fields here keeps the Clip free of SwiftData and under the size budget.
struct ClipInstructor: Identifiable {
    let ownerID: String
    let name: String
    /// The instructor's exact studio address, shown publicly.
    let address: String
    let bio: String?
    let price: Int
    /// Years teaching. `0` means "not stated".
    let yearsExp: Int
    let specialties: [String]
    /// Legacy remote image id/URL — used only if there is no uploaded `photo`.
    let img: String
    /// Uploaded profile photo bytes, if the instructor set one.
    let photo: Data?

    var id: String { ownerID }
    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }

    init?(record: CKRecord) {
        guard let name = record["name"] as? String else { return nil }
        ownerID = record.recordID.recordName
        self.name = name
        address = record["address"] as? String ?? ""
        bio = record["bio"] as? String
        price = record["price"] as? Int ?? 0
        yearsExp = record["yearsExp"] as? Int ?? 0
        specialties = record["specialties"] as? [String] ?? []
        img = record["img"] as? String ?? ""
        // CloudKit stages an asset as a local file; read it now, before the temp copy is reclaimed.
        photo = (record["photo"] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
    }
}

/// Anonymous reader over CloudKit's **public** database — the Clip's one data path.
///
/// Mirrors `CatalogService.fetch(ownerIDs:)`: a DIRECT `records(for:)` fetch by recordName (which
/// equals the ownerID) of an `InstructorListing`, resolving even a hidden listing. All fields are
/// world-readable, so this needs NO iCloud account signed in. The container entitlement
/// (icloud-container-identifiers + icloud-services CloudKit) MUST be present on the Clip target, or
/// `CKContainer(identifier:)` traps at launch.
@MainActor
final class ClipCatalogService {

    enum FetchResult {
        case success(ClipInstructor)
        case notFound      // no such record — bad or stale ownerID
        case failure       // network / CloudKit unreachable — retryable
    }

    /// Must equal `FloweModelContainer.cloudKitContainerID` in the main app. Hardcoded rather than
    /// shared because that type imports SwiftData, which the Clip deliberately excludes.
    private static let containerID = "iCloud.com.flowepilates.app"

    private let database = CKContainer(identifier: ClipCatalogService.containerID).publicCloudDatabase

    func fetch(ownerID: String) async -> FetchResult {
        let recordID = CKRecord.ID(recordName: ownerID)
        do {
            let results = try await database.records(for: [recordID])
            guard let outcome = results[recordID] else { return .notFound }
            switch outcome {
            case .success(let record):
                return ClipInstructor(record: record).map(FetchResult.success) ?? .notFound
            case .failure(let error as CKError) where error.code == .unknownItem:
                return .notFound
            case .failure:
                return .failure   // present but unreadable (network/partial) — treat as retryable
            }
        } catch let error as CKError where error.code == .unknownItem {
            return .notFound
        } catch {
            return .failure       // offline / CloudKit down
        }
    }
}
