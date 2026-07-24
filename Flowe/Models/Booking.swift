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

    // MARK: - Session timing (derived from the stored strings — no timestamp is stored)
    //
    // A booking carries only display strings (`date` "EEE, MMM d", `time` "h:mm a", `duration`
    // "55 min"), language-neutral so they match across users (see `FloweWeek`). To decide whether a
    // confirmed session has been delivered — the transition to `.completed` that nothing else
    // performs — we reconstruct its absolute end time from those strings.

    /// Absolute end of this session, or nil if the strings can't be parsed.
    func sessionEnd(now: Date = Date()) -> Date? {
        Self.sessionEnd(date: date, time: time, duration: duration, now: now)
    }

    /// Reconstruct a session's end `Date` from the stored strings.
    ///
    /// The date string carries **no year** — it is a shared display value, not a timestamp — so the
    /// occurrence nearest `now` is chosen. A booking is always made within days of its session, so
    /// the nearest calendar occurrence is the correct one, and picking the nearest of last/this/next
    /// year keeps it right across a year boundary (a "Dec 30" seen on "Jan 2" resolves to last year).
    static func sessionEnd(date: String, time: String, duration: String, now: Date = Date()) -> Date? {
        // Drop the weekday ("Thu, Jul 17" → "Jul 17"): parsing it risks a strict weekday/date
        // mismatch, and the numeric date is all that's needed.
        let dayPart = date.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? date
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d h:mm a"
        guard let parsed = f.date(from: "\(dayPart) \(time)") else { return nil }

        let cal = Calendar(identifier: .gregorian)
        var comps = cal.dateComponents([.month, .day, .hour, .minute], from: parsed)
        let thisYear = cal.component(.year, from: now)
        var start: Date?
        for year in [thisYear - 1, thisYear, thisYear + 1] {
            comps.year = year
            guard let candidate = cal.date(from: comps) else { continue }   // e.g. Feb 29 in a common year
            if start == nil || abs(candidate.timeIntervalSince(now)) < abs(start!.timeIntervalSince(now)) {
                start = candidate
            }
        }
        guard let start else { return nil }

        let minutes = Int(duration.prefix(while: \.isNumber)) ?? 60   // "55 min" → 55
        return start.addingTimeInterval(TimeInterval((minutes > 0 ? minutes : 60) * 60))
    }

    /// Whether a session's end has passed — the signal that turns a `.confirmed` booking
    /// `.completed`. Unparseable strings are treated as *not over*, so a booking we can't date stays
    /// confirmed rather than being wrongly marked delivered.
    static func isOver(date: String, time: String, duration: String, now: Date = Date()) -> Bool {
        guard let end = sessionEnd(date: date, time: time, duration: duration, now: now) else { return false }
        return end < now
    }
}
