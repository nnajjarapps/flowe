import Foundation
import CloudKit

/// A session request as it exists in the shared catalog (plain DTO decoded from a CKRecord).
struct RemoteBooking {
    let id: String              // recordName — the stable booking identity
    let instructorID: String    // instructor's ownerID
    let studentID: String       // student's ownerID
    let studentName: String     // display name only — never an email
    let date: String
    let time: String
    let type: String
    let duration: String
    let createdAt: Date
    let cancelled: Bool

    init?(record: CKRecord) {
        guard let instructorID = record["instructorID"] as? String,
              let studentID = record["studentID"] as? String else { return nil }
        id = record.recordID.recordName
        self.instructorID = instructorID
        self.studentID = studentID
        studentName = record["studentName"] as? String ?? ""
        date = record["date"] as? String ?? ""
        time = record["time"] as? String ?? ""
        type = record["type"] as? String ?? ""
        duration = record["duration"] as? String ?? ""
        createdAt = record["createdAt"] as? Date ?? .distantPast
        cancelled = (record["cancelled"] as? Int ?? 0) == 1
    }
}

/// An instructor's accept/decline for a booking.
struct RemoteDecision {
    let bookingID: String
    let confirmed: Bool
    let respondedAt: Date

    init?(record: CKRecord) {
        guard let bookingID = record["bookingID"] as? String else { return nil }
        self.bookingID = bookingID
        confirmed = (record["confirmed"] as? Int ?? 0) == 1
        respondedAt = record["respondedAt"] as? Date ?? .distantPast
    }
}

/// Booking exchange over CloudKit's **public** database.
///
/// SwiftData can only mirror the *private* database, where each user sees only their own records —
/// so a student's booking would never reach the instructor. Bookings therefore live in the public
/// database as raw CloudKit, the same way `CatalogService` handles listings.
///
/// Public-DB security grants write to `_creator` and read to `_world`, which means a record is only
/// editable by whoever created it. A booking is consequently modelled as **two** records rather
/// than one mutable row:
///
/// - `SessionBooking` — written by the student (and cancellable by them).
/// - `SessionDecision` — written by the instructor, referencing the booking id.
///
/// Each side only ever writes its own records, so the default security roles are sufficient and no
/// world-writable record type is needed. Effective status is merged client-side in `MockDataStore`.
@MainActor
final class BookingService {
    static let bookingRecordType = "SessionBooking"
    static let decisionRecordType = "SessionDecision"

    /// CloudKit rejects an unbounded query; a pilot instructor is nowhere near this.
    private static let fetchLimit = 200

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    // MARK: - Student writes

    /// Publish a new booking request. Returns the remote id so it can be cached locally.
    func create(instructorID: String,
                studentID: String,
                studentName: String,
                date: String,
                time: String,
                type: String,
                duration: String) async -> String? {
        #if CLOUDKIT_ENABLED
        let record = CKRecord(recordType: Self.bookingRecordType)
        record["instructorID"] = instructorID
        record["studentID"] = studentID
        record["studentName"] = studentName
        record["date"] = date
        record["time"] = time
        record["type"] = type
        record["duration"] = duration
        record["createdAt"] = Date()
        record["cancelled"] = 0
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

    /// Student-initiated cancellation — allowed because the student created this record.
    /// Returns whether the change reached the server.
    @discardableResult
    func cancel(bookingID: String) async -> Bool {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: bookingID)
        guard let record = try? await database.record(for: id) else { return false }
        record["cancelled"] = 1
        return (try? await database.save(record)) != nil
        #else
        return false
        #endif
    }

    // MARK: - Instructor writes

    /// Accept or decline a booking. The instructor creates their *own* record rather than editing
    /// the student's, which is what keeps the default `_creator`-write security workable.
    /// Returns whether the decision reached the server.
    @discardableResult
    func respond(bookingID: String, confirmed: Bool) async -> Bool {
        #if CLOUDKIT_ENABLED
        // recordName is derived from the booking so responding twice updates rather than duplicates,
        // and so the instructor stays the creator of the record they are editing.
        let id = CKRecord.ID(recordName: "decision-\(bookingID)")
        let record = (try? await database.record(for: id))
            ?? CKRecord(recordType: Self.decisionRecordType, recordID: id)
        record["bookingID"] = bookingID
        record["confirmed"] = confirmed ? 1 : 0
        record["respondedAt"] = Date()
        return (try? await database.save(record)) != nil
        #else
        return false
        #endif
    }

    // MARK: - Reads

    /// Bookings addressed to an instructor.
    func fetchForInstructor(ownerID: String) async -> [RemoteBooking] {
        await fetchBookings(matching: NSPredicate(format: "instructorID == %@", ownerID))
    }

    /// Bookings a student has made.
    func fetchForStudent(ownerID: String) async -> [RemoteBooking] {
        await fetchBookings(matching: NSPredicate(format: "studentID == %@", ownerID))
    }

    private func fetchBookings(matching predicate: NSPredicate) async -> [RemoteBooking] {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.bookingRecordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        do {
            let (matches, _) = try await database.records(
                matching: query, desiredKeys: nil, resultsLimit: Self.fetchLimit
            )
            return matches.compactMap { try? $0.1.get() }.compactMap(RemoteBooking.init)
        } catch {
            return []
        }
        #else
        return []
        #endif
    }

    /// Decisions for the given bookings, keyed by booking id.
    func fetchDecisions(bookingIDs: [String]) async -> [String: RemoteDecision] {
        #if CLOUDKIT_ENABLED
        guard !bookingIDs.isEmpty else { return [:] }
        let query = CKQuery(recordType: Self.decisionRecordType,
                            predicate: NSPredicate(format: "bookingID IN %@", bookingIDs))
        do {
            let (matches, _) = try await database.records(
                matching: query, desiredKeys: nil, resultsLimit: Self.fetchLimit
            )
            let decisions = matches.compactMap { try? $0.1.get() }.compactMap(RemoteDecision.init)
            return Dictionary(decisions.map { ($0.bookingID, $0) }, uniquingKeysWith: {
                $0.respondedAt >= $1.respondedAt ? $0 : $1
            })
        } catch {
            return [:]
        }
        #else
        return [:]
        #endif
    }
}
