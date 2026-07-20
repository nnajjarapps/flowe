import Foundation
import CloudKit

/// Erases every public-database record a user created, for the in-app account deletion that
/// App Store Review Guideline 5.1.1(v) requires.
///
/// Only `_creator`-owned records can go. The public database grants write to whoever created a
/// record, so a user can remove their own listing, bookings, decisions and sent messages — but not
/// the messages the other side wrote to them, which stay owned by their sender (see
/// `BOOKING-SYSTEM.md`).
///
/// Sign in with Apple token revocation is deliberately **not** attempted here: the REST revoke
/// endpoint needs a client-secret JWT that cannot ship inside an app, and Flowe never retains the
/// `authorizationCode` required to obtain a refresh token. Apple's TN3194 covers exactly this case —
/// delete the user's data, then direct them to revoke the credential from Settings, which
/// `DeleteAccountView` does.
@MainActor
final class AccountDeletionService {
    /// CloudKit caps how many records one modify operation may carry; stay well under it.
    private static let deleteBatchSize = 300
    /// Page size for the id sweep. Completeness comes from following the cursor, not from this.
    private static let pageSize = 400

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    /// Remove everything `ownerID` created.
    ///
    /// Returns false if any part failed, so the caller can keep the account alive rather than sign
    /// the user out while their records stay readable in the public database.
    func deleteAllRecords(ownerID: String) async -> Bool {
        #if CLOUDKIT_ENABLED
        var ids: [CKRecord.ID] = []

        // Messages I wrote. Ones written *to* me belong to their sender and cannot be removed.
        guard let sent = await recordIDs(
            ofType: MessagingService.recordType,
            matching: NSPredicate(format: "senderID == %@", ownerID)
        ) else { return false }
        ids += sent

        // Bookings I made as a student.
        guard let asStudent = await recordIDs(
            ofType: BookingService.bookingRecordType,
            matching: NSPredicate(format: "studentID == %@", ownerID)
        ) else { return false }
        ids += asStudent

        // Decisions I wrote as an instructor. `SessionDecision` carries no instructor id, but its
        // recordName is derived from the booking it answers, so the bookings addressed to me yield
        // the full set. Ones I never answered simply don't exist, which `delete` tolerates.
        guard let addressedToMe = await recordIDs(
            ofType: BookingService.bookingRecordType,
            matching: NSPredicate(format: "instructorID == %@", ownerID)
        ) else { return false }
        ids += addressedToMe.map { CKRecord.ID(recordName: "decision-\($0.recordName)") }

        // My instructor listing, whose recordName *is* the owner id. Absent for students.
        ids.append(CKRecord.ID(recordName: ownerID))

        return await delete(dedupe(ids))
        #else
        return true   // nothing was ever published
        #endif
    }

    #if CLOUDKIT_ENABLED

    /// Every record id of `type` matching `predicate`, following cursors so nothing is stranded
    /// beyond a page boundary.
    ///
    /// Returns nil when the query itself failed (offline, schema not deployed). That is distinct
    /// from an empty array, which means "genuinely none" — conflating the two would report a
    /// successful deletion for an account whose records were never even enumerated.
    private func recordIDs(ofType type: String, matching predicate: NSPredicate) async -> [CKRecord.ID]? {
        var ids: [CKRecord.ID] = []
        do {
            // Only ids are needed, so ask for no fields at all.
            var page = try await database.records(
                matching: CKQuery(recordType: type, predicate: predicate),
                desiredKeys: [], resultsLimit: Self.pageSize
            )
            ids += page.matchResults.map(\.0)

            while let cursor = page.queryCursor {
                page = try await database.records(
                    continuingMatchFrom: cursor, desiredKeys: [], resultsLimit: Self.pageSize
                )
                ids += page.matchResults.map(\.0)
            }
            return ids
        } catch {
            return nil
        }
    }

    private func delete(_ ids: [CKRecord.ID]) async -> Bool {
        guard !ids.isEmpty else { return true }

        for start in stride(from: 0, to: ids.count, by: Self.deleteBatchSize) {
            let chunk = Array(ids[start..<min(start + Self.deleteBatchSize, ids.count)])
            do {
                let (_, deletes) = try await database.modifyRecords(saving: [], deleting: chunk)
                for result in deletes.values {
                    if case .failure(let error) = result, !Self.isAlreadyGone(error) { return false }
                }
            } catch {
                return false
            }
        }
        return true
    }

    /// A record that never existed — an unanswered booking's decision, a student with no listing —
    /// is not a failure. The goal state is "gone", and it already is.
    private static func isAlreadyGone(_ error: Error) -> Bool {
        (error as? CKError)?.code == .unknownItem
    }

    /// CloudKit rejects a modify operation carrying the same id twice.
    private func dedupe(_ ids: [CKRecord.ID]) -> [CKRecord.ID] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0.recordName).inserted }
    }

    #endif
}
