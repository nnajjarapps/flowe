import Foundation
import CloudKit

/// A public instructor listing fetched from CloudKit (plain DTO, decoded from a CKRecord).
struct CatalogListing {
    let ownerID: String
    let name: String
    /// LEGACY free-text city. Still decoded for back-compat reads of older records, but no longer
    /// published or displayed — `address` replaced it.
    let city: String
    /// The instructor's exact studio address, shown publicly wherever `city` used to appear.
    let address: String
    let bio: String?
    let price: Int
    /// Years teaching, as the instructor declared it in Edit Profile. `0` means "not stated" — see
    /// `Instructor.yearsExp`.
    let yearsExp: Int
    let specialties: [String]
    let sessionTypes: [String]
    let available: [String]
    let hours: [String]
    let rating: Double
    let reviews: Int
    let img: String
    let cert: String
    let visibility: Int
    /// The instructor's Flowe Community peer opt-in (mirror of `StudentProfile.communityVisible`).
    let communityVisible: Bool
    let updatedAt: Date
    /// Uploaded profile photo, if the instructor set one.
    let photo: Data?
    /// Uploaded photo of the certificate itself, if the instructor set one.
    let certPhoto: Data?
    /// Flowe Pro brand cover/banner photo, if set.
    let coverPhoto: Data?
    /// `PaymentMethod` raw ids — how this instructor takes payment offline.
    let paymentMethods: [String]
    /// Flowe Pro career layer (see [[FlowePro]]): the professional headline, brand story, and
    /// pipe-encoded work-history rows (`period|place|role`). Empty strings/array when unset.
    let headline: String
    let story: String
    let experience: [String]
    /// Brand accent as "#RRGGBB", or empty. Part of the Flowe Pro brand kit.
    let brandColor: String
    /// The instructor's EXACT studio point (no longer coarsened). Nil when the instructor hasn't set
    /// one — which is most of them, and never a reason to hide a listing.
    let latitude: Double?
    let longitude: Double?
    /// Server-assigned last-modified timestamp of the CKRecord — intrinsic to every saved/fetched
    /// record, so it costs no public field and no schema deploy. This is the ONE authoritative clock
    /// (never the client-set `updatedAt`) that `hydrateOwnListingIfNeeded` compares its local
    /// baseline against to decide whether the server copy is strictly newer. Nil only on a record
    /// that was never saved — never the case for one fetched from the server.
    let modifiedAt: Date?

    init?(record: CKRecord) {
        guard let name = record["name"] as? String else { return nil }
        ownerID = record.recordID.recordName
        self.name = name
        city = record["city"] as? String ?? ""
        address = record["address"] as? String ?? ""
        bio = record["bio"] as? String
        price = record["price"] as? Int ?? 0
        yearsExp = record["yearsExp"] as? Int ?? 0
        specialties = record["specialties"] as? [String] ?? []
        sessionTypes = record["sessionTypes"] as? [String] ?? []
        available = record["available"] as? [String] ?? []
        hours = record["hours"] as? [String] ?? []
        rating = record["rating"] as? Double ?? 0
        reviews = record["reviews"] as? Int ?? 0
        img = record["img"] as? String ?? ""
        cert = record["cert"] as? String ?? ""
        paymentMethods = record["paymentMethods"] as? [String] ?? []
        headline = record["headline"] as? String ?? ""
        story = record["story"] as? String ?? ""
        experience = record["experience"] as? [String] ?? []
        brandColor = record["brandColor"] as? String ?? ""
        visibility = record["visibility"] as? Int ?? 0
        communityVisible = (record["communityVisible"] as? Int ?? 0) == 1
        updatedAt = record["updatedAt"] as? Date ?? .distantPast
        modifiedAt = record.modificationDate
        latitude = record["latitude"] as? Double
        longitude = record["longitude"] as? Double
        // CloudKit stages an asset as a local file; read it now, before the temp copy is reclaimed.
        photo = (record["photo"] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
        certPhoto = (record["certPhoto"] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
        coverPhoto = (record["coverPhoto"] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
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
    ///
    /// Returns the saved record's server `modificationDate` on success (the caller stores it as the
    /// own-listing re-sync baseline), or nil on any failure. Not a `Bool`: the timestamp is what lets
    /// `hydrateOwnListingIfNeeded` recognise the publish's own echo and skip re-applying it.
    @discardableResult
    func publish(_ instructor: Instructor) async -> Date? {
        #if CLOUDKIT_ENABLED
        guard let ownerID = instructor.ownerID, !instructor.name.isEmpty else { return nil }
        let id = CKRecord.ID(recordName: ownerID)
        let record = (try? await database.record(for: id)) ?? CKRecord(recordType: Self.recordType, recordID: id)

        record["name"] = instructor.name
        // `city` is no longer written — `address` (the exact studio address) replaced it. The field
        // stays in the schema and is still decoded for back-compat reads of older records.
        record["address"] = instructor.address
        record["bio"] = instructor.bio
        record["price"] = instructor.price
        record["yearsExp"] = instructor.yearsExp
        record["specialties"] = instructor.specialties
        record["sessionTypes"] = instructor.sessionTypes
        record["available"] = instructor.available
        record["hours"] = instructor.hours
        record["rating"] = instructor.rating
        record["reviews"] = instructor.reviews
        record["img"] = instructor.img
        record["cert"] = instructor.cert
        record["paymentMethods"] = instructor.paymentMethods
        record["headline"] = instructor.headline
        record["story"] = instructor.story
        record["experience"] = instructor.experienceTokens
        record["brandColor"] = instructor.brandColor
        record["visibility"] = instructor.visibilityRaw
        record["communityVisible"] = instructor.communityVisible ? 1 : 0
        record["updatedAt"] = Date()
        // The EXACT studio point (no longer snapped) — students navigate here to book the studio.
        // Assigning nil removes the key, which is how "remove my studio location" actually reaches
        // other people's devices.
        record["latitude"] = instructor.latitude
        record["longitude"] = instructor.longitude

        // A CKAsset is uploaded from a file, so each image has to be staged on disk for the save.
        let staged = instructor.photo.flatMap { Self.stageAsset($0, name: "listing-photo") }
        let stagedCert = instructor.certPhoto.flatMap { Self.stageAsset($0, name: "listing-cert") }
        let stagedCover = instructor.coverPhoto.flatMap { Self.stageAsset($0, name: "listing-cover") }
        record["photo"] = staged.map { CKAsset(fileURL: $0) }
        record["certPhoto"] = stagedCert.map { CKAsset(fileURL: $0) }
        record["coverPhoto"] = stagedCover.map { CKAsset(fileURL: $0) }
        defer {
            staged.map { try? FileManager.default.removeItem(at: $0) }
            stagedCert.map { try? FileManager.default.removeItem(at: $0) }
        }

        do {
            let saved = try await database.save(record)
            return saved.modificationDate
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Last-writer-wins: take the server record, re-apply our fields, retry once.
            if let server = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord {
                server["visibility"] = instructor.visibilityRaw
                server["price"] = instructor.price
                server["paymentMethods"] = instructor.paymentMethods
                server["updatedAt"] = Date()
                // The edited text fields must survive a conflict too — omitting them let a concurrent
                // save keep the new photo while silently reverting a just-edited bio (or name/city/
                // specialties) to the stale server copy. All existing record fields, no schema impact.
                server["name"] = instructor.name
                server["address"] = instructor.address
                server["bio"] = instructor.bio
                server["yearsExp"] = instructor.yearsExp
                server["specialties"] = instructor.specialties
                server["sessionTypes"] = instructor.sessionTypes
                server["rating"] = instructor.rating
                server["reviews"] = instructor.reviews
                server["img"] = instructor.img
                server["cert"] = instructor.cert
                // Re-apply availability too — a conflicting save must not resurrect a day the
                // instructor just closed. A closed day is encoded as ABSENT from `available`, so
                // taking the server copy without this would silently reopen it from the stale record.
                server["available"] = instructor.available
                server["hours"] = instructor.hours
                // Re-applied including a nil, for the same reason the assets are: a conflicting
                // save must not resurrect a studio location the instructor has just removed. Exact.
                server["latitude"] = instructor.latitude
                server["longitude"] = instructor.longitude
                // The staged files outlive this block (`defer` fires on return), so the retry can
                // reuse them — otherwise a conflicting save would silently drop the new images.
                // Both assets are re-applied, including a nil, so a removal survives the conflict.
                server["photo"] = staged.map { CKAsset(fileURL: $0) }
                server["certPhoto"] = stagedCert.map { CKAsset(fileURL: $0) }
                // Return the conflict-resolved save's server timestamp too, so a publish that had to
                // retry still advances the caller's baseline — otherwise the next foreground pull
                // would see a newer server record and re-apply this very edit onto its own author.
                if let saved = try? await database.save(server) { return saved.modificationDate }
                return nil
            }
            return nil
        } catch {
            // Offline / not signed into iCloud / schema not deployed — non-fatal.
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Fetch specific instructor listings by ownerID (their recordName) — a DIRECT record fetch, not
    /// a visibility query. Lets a student resolve the instructors they message or booked, even ones
    /// who have since gone hidden (a lapsed subscription still owes its history a name and a face).
    func fetch(ownerIDs: [String]) async -> [CatalogListing] {
        #if CLOUDKIT_ENABLED
        guard !ownerIDs.isEmpty else { return [] }
        do {
            let results = try await database.records(for: ownerIDs.map { CKRecord.ID(recordName: $0) })
            return results.values.compactMap { try? $0.get() }.compactMap(CatalogListing.init)
        } catch {
            return []
        }
        #else
        return []
        #endif
    }

    /// Fetch all currently-visible listings (Boost + Visible).
    ///
    /// Returns nil when the query itself failed (offline, or the `visibility` index isn't deployed to
    /// this environment) — distinct from an empty array, which means "genuinely no visible listings".
    /// Conflating the two would let a schema/network error look identical to an empty marketplace, and
    /// the caller would then hide every cached instructor on the strength of a failed fetch.
    func fetchVisibleListings() async -> [CatalogListing]? {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(format: "visibility > 0"))
        query.sortDescriptors = [NSSortDescriptor(key: "visibility", ascending: false)]
        do {
            let (matches, _) = try await database.records(matching: query, desiredKeys: nil, resultsLimit: 200)
            return matches.compactMap { try? $0.1.get() }.compactMap(CatalogListing.init)
        } catch {
            return nil   // schema not deployed / offline — NOT "no records"
        }
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

    /// Remove the instructor's listing (e.g. account deletion).
    func remove(ownerID: String) async {
        #if CLOUDKIT_ENABLED
        _ = try? await database.deleteRecord(withID: CKRecord.ID(recordName: ownerID))
        #endif
    }
}
