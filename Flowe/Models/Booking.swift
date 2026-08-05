import Foundation
import SwiftData

/// The instructor's attendance judgment for a session whose time has passed. Instructor-local only —
/// never written to the shared booking record (a student never sees "you were marked a no-show").
enum Attendance: String, Codable {
    case unknown   // not yet judged (or still upcoming)
    case attended
    case noShow
}

/// How a no-show / late-cancel fee has been resolved. Off-app: the instructor collects directly, Flowe
/// only tracks the state.
enum FeeStatus: String, Codable {
    case none       // no fee applies
    case owed       // flagged, not yet collected
    case collected
    case waived
}

/// This instructor's role in an Out-of-Studio cover for a session. Instructor-local only — like the
/// No-Show Shield block, it never touches the world-readable booking record.
enum CoverRole: String, Codable {
    case none        // no cover involved
    case handedOff   // this instructor reported OOS; a replacer is covering the session
    case covering    // this instructor is covering someone else's session
}

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
    /// Stored as a raw String, not a Codable enum, so it mirrors to CloudKit as a plain STRING rather
    /// than opaque BYTES — the same forward-safe pattern as `attendance`/`feeStatus`/`coverRole` below.
    /// An unknown or renamed case then degrades to `.pending` instead of failing to decode the whole row.
    var statusRaw: String = BookingStatus.pending.rawValue
    var status: BookingStatus {
        get { BookingStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }
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

    // MARK: Seat lock (private-mirror only — NEVER uploaded to the shared SessionBooking record, so it
    // adds no exposure to the world-readable booking, exactly like the No-Show Shield fields below).
    /// The `SlotHold` recordName whose seat this booking occupies, so a cancel/skip/end can release it
    /// (a freed hold recordName goes absent and is immediately re-claimable). Nil when the atomic claim
    /// degraded to unlocked (offline / schema not yet deployed) or for a booking made before seat-locks.
    /// Holds are anonymous (no studentID), so the student cannot re-derive which hold is theirs by query
    /// — storing the recordName locally is the only way to release the right seat.
    var holdRecordName: String? = nil

    /// The booked lesson type's seat capacity, frozen at claim time (private-mirror only, never uploaded).
    /// Group/duet logic (waitlist rank, promotion, series top-up) needs the capacity even when the live
    /// `LessonType` cache is cold, on a second device, renamed, or resolved via a hours-less placeholder —
    /// reading a stale/absent cache would collapse a real group to a 1-seat slot. 0 = unknown (fall back
    /// to the live lookup). Set right after construction, like `pendingUpload`.
    var bookedCapacity: Int = 0

    // MARK: Delivery state
    /// The booking has not reached the shared database yet (offline when it was made).
    /// Retried on the next sync — a booking the instructor never receives is the worst failure
    /// this system can have, so it is never silently dropped.
    var pendingUpload: Bool = false
    /// A local accept/decline (or cancellation) that has not been pushed yet.
    var pendingDecision: Bool = false

    // MARK: No-Show Shield (instructor-local — NEVER uploaded to the shared record, so it stays private
    // and adds no exposure to the world-readable booking record). Persists in the private-mirrored cache.
    var attendanceRaw: String = Attendance.unknown.rawValue
    var feeStatusRaw: String = FeeStatus.none.rawValue
    /// The fee owed, resolved from the lesson type's policy at the moment it was flagged (so a later
    /// policy edit doesn't silently rewrite history).
    var feeAmount: Int = 0

    var attendance: Attendance {
        get { Attendance(rawValue: attendanceRaw) ?? .unknown }
        set { attendanceRaw = newValue.rawValue }
    }
    var feeStatus: FeeStatus {
        get { FeeStatus(rawValue: feeStatusRaw) ?? .none }
        set { feeStatusRaw = newValue.rawValue }
    }

    // MARK: Out of Studio (instructor-local — NEVER uploaded to the shared record, exactly like the
    // No-Show Shield block above: it stays private and adds no exposure to the world-readable booking
    // record). Persists in the private-mirrored cache.
    var coverRoleRaw: String = CoverRole.none.rawValue
    /// Half the session price, frozen when the swap is confirmed (so a later price edit doesn't
    /// silently rewrite what the replacer is owed) — the same freezing `feeAmount` does above.
    var coverAmount: Int = 0
    var coverStatusRaw: String = FeeStatus.none.rawValue

    var coverRole: CoverRole {
        get { CoverRole(rawValue: coverRoleRaw) ?? .none }
        set { coverRoleRaw = newValue.rawValue }
    }
    var coverStatus: FeeStatus {
        get { FeeStatus(rawValue: coverStatusRaw) ?? .none }
        set { coverStatusRaw = newValue.rawValue }
    }

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
        studentName: String = "",
        holdRecordName: String? = nil
    ) {
        self.legacyId = legacyId
        self.instructorId = instructorId
        self.date = date
        self.time = time
        self.type = type
        self.duration = duration
        self.statusRaw = status.rawValue
        self.ownerID = ownerID
        self.order = order
        self.remoteID = remoteID
        self.instructorOwnerID = instructorOwnerID
        self.studentID = studentID
        self.studentName = studentName
        self.holdRecordName = holdRecordName
    }

    // MARK: - Slot seat-lock helpers
    //
    // A `SlotHold` recordName is `hold-<instructorID>-<yyyy-MM-dd>-<HHmm>-<seat>`, derived ONLY from
    // the physical slot (instructor + POSIX date + 24h time), never the booking flavor — so a one-off
    // and a standing-series week on the same slot resolve to the identical key and genuinely contend.

    /// The 24h "HHmm" token for a stored "h:mm a" time string, parsed in en_US_POSIX so it never drifts
    /// with the device locale — the same parse basis as `sessionEnd` / `Instructor.minutesOfDay`. Nil on
    /// a parse failure (the caller then degrades to booking without a hold). This is the time component
    /// of a `SlotHold` recordName, uniform across one-offs and series occurrences.
    /// The seat index this booking's `SlotHold` occupies — the trailing integer of `holdRecordName`
    /// (`hold-<instructorID>-<yyyy-MM-dd>-<HHmm>-<seat>`). The final `-` token is ALWAYS the seat, so
    /// this is robust to dashes inside the instructorID or the date. Nil when the booking has no hold
    /// (offline / schema not deployed / pre-seat-lock). Admitted seats are `0..<capacity`; an index
    /// `>= capacity` is a waitlist (OVERFLOW) seat — this is how waitlisted-ness is derived with NO
    /// stored column and no new `BookingStatus` case.
    var seatIndex: Int? {
        guard let last = holdRecordName?.split(separator: "-").last else { return nil }
        return Int(last)
    }

    // MARK: - Cached formatters
    //
    // `DateFormatter()` creation is one of the most expensive common iOS operations, and these helpers
    // are called PER BOOKING PER RENDER (My Sessions list, calendar, status resolver) — a fresh formatter
    // each call caused visible main-thread lag switching Upcoming/Past. POSIX (locale-independent)
    // formatters are shared `static let`s; the locale-aware DISPLAY formatters are cached per
    // (locale, template) in a thread-safe `NSCache`. A configured `DateFormatter` is safe to share for
    // read-only formatting/parsing across threads (iOS 7+), and none of these are mutated after setup.
    private static let posixTimeParser: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "h:mm a"; return f
    }()
    private static let posixTokenOut: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HHmm"; return f
    }()
    private static let posixDayKey: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let posixEndParser: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMM d h:mm a"; return f
    }()
    private static let localizedFormatterCache = NSCache<NSString, DateFormatter>()
    private static func localizedFormatter(template: String, locale: Locale) -> DateFormatter {
        let key = "\(locale.identifier)|\(template)" as NSString
        if let f = localizedFormatterCache.object(forKey: key) { return f }
        let f = DateFormatter(); f.locale = locale; f.setLocalizedDateFormatFromTemplate(template)
        localizedFormatterCache.setObject(f, forKey: key)
        return f
    }

    static func timeToken(_ time: String) -> String? {
        guard let d = posixTimeParser.date(from: time) else { return nil }
        return posixTokenOut.string(from: d)
    }

    // MARK: - Recurring series (COMPUTED from `remoteID` — NO stored column, so no CloudKit-mirror
    // migration). A weekly standing slot materializes one ordinary Booking per week, every occurrence
    // sharing a deterministic recordName `sb-<seriesUUID>-<yyyy-MM-dd>`. A one-off booking keeps its
    // server-random recordName (no `sb-` prefix), so all of these read nil/false for it.

    /// Prefix that marks a recordName as belonging to a recurring series.
    static let seriesPrefix = "sb-"

    /// The deterministic recordName for one occurrence of a series: `sb-<seriesID>-<yyyy-MM-dd>`.
    /// The date suffix is fixed-width (10 chars, en_US_POSIX) so it is stable across users and
    /// independent of when top-up runs — never a "today"-relative week index.
    static func seriesRecordName(seriesID: String, occurrenceDate: Date) -> String {
        "\(seriesPrefix)\(seriesID)-\(seriesDateString(occurrenceDate))"
    }

    /// The fixed "yyyy-MM-dd" occurrence-date component of a series recordName.
    static func seriesDateString(_ date: Date) -> String {
        posixDayKey.string(from: date)
    }

    /// The series UUID carried by a series recordName, or nil for a one-off. Robust against the dashes
    /// inside a UUID because the trailing `-yyyy-MM-dd` is fixed-width (11 chars incl. separator).
    static func seriesID(fromRecordName name: String) -> String? {
        guard name.hasPrefix(seriesPrefix) else { return nil }
        let body = name.dropFirst(seriesPrefix.count)   // "<uuid>-yyyy-MM-dd"
        guard body.count > 11 else { return nil }
        return String(body.dropLast(11))                // drop "-yyyy-MM-dd"
    }

    /// True when this booking is one week of a standing weekly series.
    var isRecurring: Bool { remoteID.map { $0.hasPrefix(Self.seriesPrefix) } ?? false }

    /// The series identity shared by every week of a standing slot, or nil for a one-off.
    var seriesID: String? { remoteID.flatMap { Self.seriesID(fromRecordName: $0) } }

    /// The "yyyy-MM-dd" calendar date of this occurrence (from the recordName), or nil for a one-off.
    var occurrenceDateString: String? {
        guard isRecurring, let name = remoteID, name.count >= 10 else { return nil }
        return String(name.suffix(10))
    }

    // MARK: - Display helpers (locale-aware; storage stays English/POSIX — see timing section below)
    //
    // Storage MUST stay English/POSIX: `date`/`time`/`duration` are the cross-user match key and the
    // `sessionEnd()` parse basis. These helpers reconstruct the underlying value and re-render it for
    // the caller's locale ONLY at display time — never mutating the stored strings.

    /// Numeric minutes parsed from the stored "NN min" duration (e.g. "55 min" → 55).
    var durationMinutes: Int { Int(duration.prefix(while: \.isNumber)) ?? 60 }

    /// The stored date string re-rendered for `locale` (e.g. Hebrew weekday+month+day). Falls back to
    /// the raw stored string if the strings can't be parsed — never blank. DateFormatter ignores the
    /// environment locale, so the caller must pass it in explicitly.
    func localizedDate(_ locale: Locale) -> String {
        guard let d = sessionStart() else { return date }
        return Self.localizedFormatter(template: "EEEMMMd", locale: locale).string(from: d)
    }

    /// The stored time string re-rendered for `locale`. Falls back to the raw stored string on parse
    /// failure. `jmm` yields 24h without AM/PM for he/ar — desired for the mono time columns.
    func localizedTime(_ locale: Locale) -> String {
        guard let d = sessionStart() else { return time }
        return Self.localizedFormatter(template: "jmm", locale: locale).string(from: d)
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

    /// Absolute start of this session — the end minus the parsed duration. Used by No-Show Shield to
    /// measure a cancellation against the policy window.
    func sessionStart(now: Date = Date()) -> Date? {
        Self.sessionStart(date: date, time: time, duration: duration, now: now)
    }

    /// Reconstruct a session's start `Date` from the stored strings (end minus duration). Static so the
    /// booking-status resolver can decide a series-end tombstone's past/future split without a row.
    static func sessionStart(date: String, time: String, duration: String, now: Date = Date()) -> Date? {
        guard let end = sessionEnd(date: date, time: time, duration: duration, now: now) else { return nil }
        let minutes = Int(duration.prefix(while: \.isNumber)) ?? 60
        return end.addingTimeInterval(TimeInterval(-(minutes > 0 ? minutes : 60) * 60))
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
        guard let parsed = posixEndParser.date(from: "\(dayPart) \(time)") else { return nil }

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
