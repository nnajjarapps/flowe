import Foundation
import CloudKit

/// The single source of truth for which role an Apple ID is CURRENTLY acting as, stored in CloudKit's
/// **public** database. Because `ownerID` (the Sign-in-with-Apple id) is stable across ALL of a user's
/// devices, this record lets any device learn the role another device already committed — so one Apple
/// ID can't be an instructor on one device and a student on another at the same time. That split-brain
/// silently cross-contaminates the shared private database (same iCloud account = one private DB) and
/// makes every student↔instructor flow self-referential. See [[two-party-test-harness]].
///
/// The role is SWITCHABLE, not locked: an explicit in-app action (`AppSession.switchRole`) updates this
/// record, and other devices follow on next foreground (`AppSession.reconcileRole`). What's forbidden is
/// DIVERGING — signing a second device in as the other role — which this guards at sign-in.
///
/// CRITICAL: the recordName is namespaced `role-<ownerID>`, NOT the bare ownerID. `InstructorListing`
/// (`CatalogService`) already keys its record on the bare ownerID in this same public default zone, and
/// CloudKit recordNames are unique per zone across ALL record types — a bare-ownerID claim would fetch
/// the wrong-typed listing and collide on save (the exact hazard `StudentDirectoryService` documents).
@MainActor
final class AccountRoleService {
    static let recordType = "AccountRole"
    static let roleKey = "role"           // UserRole.rawValue — "student" | "instructor"
    static let updatedAtKey = "updatedAt"

    nonisolated static func recordName(for ownerID: String) -> String { "role-\(ownerID)" }

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    /// The account's established role, distinguishing "no claim yet" from "couldn't reach CloudKit" —
    /// callers MUST NOT write a claim when the answer is `.unavailable` (a transient read failure could
    /// otherwise let a stale choice overwrite a real claim). Falls back to a legacy signal: an existing
    /// bare-ownerID `InstructorListing` means this Apple ID is an instructor, for accounts created before
    /// claims existed. Students have no reliable public signal, so their absence reads as `.none` (new).
    func lookup(for ownerID: String) async -> EstablishedRole {
        #if CLOUDKIT_ENABLED
        let claimID = CKRecord.ID(recordName: Self.recordName(for: ownerID))
        do {
            let rec = try await database.record(for: claimID)
            if let raw = rec[Self.roleKey] as? String, let role = UserRole(rawValue: raw) {
                return .claimed(role)
            }
            // Record exists but is unreadable/blank — treat as no usable claim, try the legacy signal.
        } catch let err as CKError where err.code == .unknownItem {
            // No claim record — expected for new accounts and legacy ones. Fall through.
        } catch {
            return .unavailable
        }

        // Legacy inference: a pre-claim instructor is detectable by their public listing (bare ownerID).
        let listingID = CKRecord.ID(recordName: ownerID)
        if let rec = try? await database.record(for: listingID),
           rec.recordType == CatalogService.recordType {
            return .claimed(.instructor)
        }
        return .none
        #else
        return .none
        #endif
    }

    /// Upsert the role claim. Returns the role now in force — normally `role`, but on a lost create/update
    /// race (`serverRecordChanged`) it re-reads and returns the winner's value so the caller can converge.
    @discardableResult
    func setRole(_ role: UserRole, for ownerID: String) async -> UserRole? {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: Self.recordName(for: ownerID))
        let record = (try? await database.record(for: id)) ?? CKRecord(recordType: Self.recordType, recordID: id)
        record[Self.roleKey] = role.rawValue
        record[Self.updatedAtKey] = Date()
        do {
            _ = try await database.save(record)
            return role
        } catch {
            return await currentClaim(for: ownerID)
        }
        #else
        return role
        #endif
    }

    /// Read just the authoritative claim (no legacy fallback), used to resolve a write race.
    private func currentClaim(for ownerID: String) async -> UserRole? {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: Self.recordName(for: ownerID))
        guard let rec = try? await database.record(for: id),
              let raw = rec[Self.roleKey] as? String else { return nil }
        return UserRole(rawValue: raw)
        #else
        return nil
        #endif
    }
}

/// What we know about an Apple ID's established role at sign-in time.
enum EstablishedRole: Equatable {
    case claimed(UserRole)   // this Apple ID already acts as this role (claim record or legacy listing)
    case none                // brand-new account — no claim, no legacy signal
    case unavailable         // CloudKit unreachable — we could not determine it (never write on this)
}
