import Foundation
import SwiftData

enum BookingStatus: String, Codable {
    case confirmed
    case pending
    case completed
    case cancelled

    /// Upcoming = still to happen; past = history.
    var isUpcoming: Bool { self == .confirmed || self == .pending }

    var label: String {
        switch self {
        case .confirmed: return "Confirmed"
        case .pending:   return "Pending"
        case .completed: return "Done"
        case .cancelled: return "Cancelled"
        }
    }
}

/// A booked session — the local cache of a booking that lives in the shared public database
/// (see `BookingService`). Both parties cache the same booking: the student because they made it,
/// the instructor because they received it.
///
/// Badge colors live in `BookingStatus+Badge.swift` (presentation kept off the model).
@Model
final class Booking {
    var legacyId: Int = 0
    var instructorId: Int = 0        // links to Instructor.legacyId (local resolution only)
    var date: String = ""
    var time: String = ""
    var type: String = ""
    var duration: String = ""
    var status: BookingStatus = BookingStatus.pending
    var ownerID: String?             // Apple user id of the owner (Phase C)
    var order: Int = 0               // ascending sort; new bookings get a smaller order → appear first

    // MARK: Shared-booking identity
    /// recordName in the public database. Nil only for a booking that failed to publish.
    var remoteID: String?
    /// ownerID of the instructor the session was booked with.
    var instructorOwnerID: String?
    /// ownerID of the student who booked.
    var studentID: String?
    /// Student's display name, denormalised so the instructor can render the row offline.
    var studentName: String = ""

    // MARK: Delivery state
    /// The booking has not reached the shared database yet (offline when it was made).
    /// Retried on the next sync — a booking the instructor never receives is the worst failure
    /// this system can have, so it is never silently dropped.
    var pendingUpload: Bool = false
    /// A local accept/decline (or cancellation) that has not been pushed yet.
    var pendingDecision: Bool = false

    init(
        legacyId: Int = 0,
        instructorId: Int = 0,
        date: String = "",
        time: String = "",
        type: String = "",
        duration: String = "",
        status: BookingStatus = .pending,
        ownerID: String? = nil,
        order: Int = 0,
        remoteID: String? = nil,
        instructorOwnerID: String? = nil,
        studentID: String? = nil,
        studentName: String = ""
    ) {
        self.legacyId = legacyId
        self.instructorId = instructorId
        self.date = date
        self.time = time
        self.type = type
        self.duration = duration
        self.status = status
        self.ownerID = ownerID
        self.order = order
        self.remoteID = remoteID
        self.instructorOwnerID = instructorOwnerID
        self.studentID = studentID
        self.studentName = studentName
    }
}
