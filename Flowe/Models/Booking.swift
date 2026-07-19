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

/// A booked session. Stored in the user `UserData` configuration (synced in Phase B).
/// Badge colors live in `BookingStatus+Badge.swift` (presentation kept off the model).
@Model
final class Booking {
    var legacyId: Int = 0
    var instructorId: Int = 0        // links to Instructor.legacyId
    var date: String = ""
    var time: String = ""
    var type: String = ""
    var duration: String = ""
    var status: BookingStatus = BookingStatus.pending
    var ownerID: String?             // Apple user id of the owner (Phase C)
    var order: Int = 0               // ascending sort; new bookings get a smaller order → appear first

    init(
        legacyId: Int = 0,
        instructorId: Int = 0,
        date: String = "",
        time: String = "",
        type: String = "",
        duration: String = "",
        status: BookingStatus = .pending,
        ownerID: String? = nil,
        order: Int = 0
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
    }
}
