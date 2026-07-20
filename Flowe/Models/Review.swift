import Foundation
import SwiftData

/// A student's review of a completed session, cached locally from the shared store.
///
/// A review is anchored to a **booking**, not just to an instructor: that is what makes it earned
/// rather than arbitrary. One booking yields at most one review, which is enforced by deriving the
/// remote record's name from the booking id (see `ReviewService`) rather than by a uniqueness
/// constraint SwiftData can't express on a CloudKit-backed model.
@Model
final class Review {
    /// recordName in the public database. Nil while the review is still queued for upload.
    var remoteID: String?
    /// Remote id of the booking being reviewed — the anchor that makes this review earned.
    var bookingID: String = ""
    /// ownerID of the instructor being reviewed.
    var instructorID: String = ""
    /// ownerID of the student who wrote it.
    var studentID: String = ""
    /// Denormalised so the row renders without a second lookup.
    var studentName: String = ""
    /// 1–5 stars.
    var rating: Int = 0
    var text: String = ""
    var createdAt: Date = Date.distantPast
    /// Hasn't reached the shared store yet; retried on the next sync.
    var pendingUpload: Bool = false

    init(
        remoteID: String? = nil,
        bookingID: String = "",
        instructorID: String = "",
        studentID: String = "",
        studentName: String = "",
        rating: Int = 0,
        text: String = "",
        createdAt: Date = Date(),
        pendingUpload: Bool = false
    ) {
        self.remoteID = remoteID
        self.bookingID = bookingID
        self.instructorID = instructorID
        self.studentID = studentID
        self.studentName = studentName
        self.rating = rating
        self.text = text
        self.createdAt = createdAt
        self.pendingUpload = pendingUpload
    }

    var displayName: String { studentName.isEmpty ? "A student" : studentName }

    /// "2 DAYS AGO" — matches the mono meta styling used across the profile.
    var relativeTime: String {
        let seconds = Date().timeIntervalSince(createdAt)
        switch seconds {
        case ..<3600:    return "JUST NOW"
        case ..<86_400:  return "\(Int(seconds / 3600))H AGO"
        case ..<604_800: return "\(Int(seconds / 86_400))D AGO"
        default:
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMM"
            return formatter.string(from: createdAt).uppercased()
        }
    }
}
