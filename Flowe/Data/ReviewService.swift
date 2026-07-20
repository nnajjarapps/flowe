import Foundation
import CloudKit

/// A review as it exists in the shared store (plain DTO decoded from a CKRecord).
struct RemoteReview {
    let id: String
    let bookingID: String
    let instructorID: String
    let studentID: String
    let studentName: String
    let rating: Int
    let text: String
    let createdAt: Date

    init?(record: CKRecord) {
        guard let bookingID = record["bookingID"] as? String,
              let instructorID = record["instructorID"] as? String,
              let studentID = record["studentID"] as? String else { return nil }
        id = record.recordID.recordName
        self.bookingID = bookingID
        self.instructorID = instructorID
        self.studentID = studentID
        studentName = record["studentName"] as? String ?? ""
        rating = record["rating"] as? Int ?? 0
        text = record["text"] as? String ?? ""
        createdAt = record["createdAt"] as? Date ?? .distantPast
    }
}

/// Session reviews over CloudKit's **public** database, for the same reason bookings and messages
/// live there: the private database is per-account, so a student's review would never reach the
/// instructor it is about.
///
/// The record name is derived from the booking (`review-<bookingID>`) rather than generated. That
/// does two things: it caps a booking at one review no matter how many times the student submits,
/// and it keeps the student the record's creator so the default `_creator`-write role lets them
/// edit their own review without a two-record split.
@MainActor
final class ReviewService {
    static let recordType = "SessionReview"

    private static let pageSize = 400

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    /// Record name for a booking's review — deterministic, so submitting twice updates.
    static func recordName(for bookingID: String) -> String { "review-\(bookingID)" }

    /// Publish (or update) the review for a booking. Returns the remote id, or nil if it didn't land.
    func submit(bookingID: String,
                instructorID: String,
                studentID: String,
                studentName: String,
                rating: Int,
                text: String,
                createdAt: Date) async -> String? {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: Self.recordName(for: bookingID))
        let record = (try? await database.record(for: id))
            ?? CKRecord(recordType: Self.recordType, recordID: id)
        record["bookingID"] = bookingID
        record["instructorID"] = instructorID
        record["studentID"] = studentID
        record["studentName"] = studentName
        record["rating"] = rating
        record["text"] = text
        record["createdAt"] = createdAt
        do {
            let saved = try await database.save(record)
            return saved.recordID.recordName
        } catch {
            return nil   // offline / not signed into iCloud / schema not deployed
        }
        #else
        return nil
        #endif
    }

    /// Every review written about an instructor.
    func fetchForInstructor(ownerID: String) async -> [RemoteReview] {
        await fetch(NSPredicate(format: "instructorID == %@", ownerID))
    }

    /// Every review this student has written — so the app knows which bookings are already done.
    func fetchForStudent(ownerID: String) async -> [RemoteReview] {
        await fetch(NSPredicate(format: "studentID == %@", ownerID))
    }

    private func fetch(_ predicate: NSPredicate) async -> [RemoteReview] {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.recordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        var reviews: [RemoteReview] = []
        do {
            var page = try await database.records(
                matching: query, desiredKeys: nil, resultsLimit: Self.pageSize
            )
            reviews += page.matchResults.compactMap { try? $0.1.get() }.compactMap(RemoteReview.init)
            // Follow the cursor: a popular instructor past one page would otherwise lose reviews,
            // and with a descending sort those losses would be the oldest ones silently vanishing.
            while let cursor = page.queryCursor {
                page = try await database.records(
                    continuingMatchFrom: cursor, desiredKeys: nil, resultsLimit: Self.pageSize
                )
                reviews += page.matchResults.compactMap { try? $0.1.get() }.compactMap(RemoteReview.init)
            }
            return reviews
        } catch {
            return []
        }
        #else
        return []
        #endif
    }
}
