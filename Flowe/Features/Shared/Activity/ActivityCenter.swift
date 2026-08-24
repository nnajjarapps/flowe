import SwiftUI
import Foundation

// MARK: - Activity kinds
//
// Flowe has NO server-side notification log — it is pure APNs push ([[PushService]]). The activity
// centre (the bell inbox) is therefore an Instagram-style feed DERIVED from data the app already
// syncs: each row maps 1:1 to a push Flowe sends (or to an actionable local state). See the
// notification-source catalog in [[NotificationCenter]].

/// One discrete kind of activity a user can receive. Carries its own glyph, tint and the tab the
/// row deep-links to (reusing the shipped `PushService.pendingTopic` routing the tab shells already
/// observe — so tapping a row lands on exactly the screen its push would have).
enum ActivityKind: String {
    // Bookings & sessions
    case bookingRequest        // instructor: a student requested a session
    case bookingConfirmed      // student: the instructor confirmed
    case bookingCancelled      // either side: a session was cancelled
    case attendanceNeeded      // instructor: a finished session needs attendance marked
    case feeOwed               // instructor: a late-cancel fee is owed
    // Messages
    case message               // either: a new direct message
    // Reviews
    case reviewReceived        // instructor: a student left a review
    // Coverage / out-of-studio
    case coverageOffer         // instructor: asked to cover a session
    case coverageClaim         // instructor: a candidate can cover your session
    case coverageCovered       // student: your session will be taught by someone else
    // Community
    case comment               // either: someone commented on your post
    case recommendation        // instructor: another instructor recommended you
    case eventJoinRequest      // instructor: a student asked to join your event
    // Marketplace (Flowe Pro)
    case opportunityApplication // instructor: someone applied to your opportunity
    case applicationAdvanced    // applicant: your application moved forward
    case applicationHired       // applicant: you were hired
    case applicationDeclined    // applicant: not selected

    /// SF Symbol shown as a small badge over the actor avatar.
    var icon: String {
        switch self {
        case .bookingRequest, .bookingConfirmed: return "calendar"
        case .bookingCancelled:                  return "calendar.badge.minus"
        case .attendanceNeeded:                  return "checkmark.circle"
        case .feeOwed:                           return "creditcard"
        case .message:                           return "bubble.left.fill"
        case .reviewReceived:                    return "star.fill"
        case .coverageOffer, .coverageClaim, .coverageCovered:
            return "arrow.triangle.2.circlepath"
        case .comment:                           return "text.bubble.fill"
        case .recommendation:                    return "hand.thumbsup.fill"
        case .eventJoinRequest:                  return "person.2.fill"
        case .opportunityApplication, .applicationAdvanced, .applicationHired, .applicationDeclined:
            return "briefcase.fill"
        }
    }

    /// Badge tint.
    var tint: Color {
        switch self {
        case .feeOwed, .bookingCancelled, .applicationDeclined: return .orange
        case .reviewReceived, .recommendation, .applicationHired: return Color.flowePinkDeep
        case .message:                                          return .blue
        default:                                                return Color.flowePinkDeep
        }
    }

    /// The tab a tap should land on, expressed via the existing push-routing bus. `nil` = no deep
    /// link (informational only). Tab mapping (per the shells' `push.pendingTopic` handlers):
    /// student .bookings→Bookings, .messages→Messages, .community→Community, .coverage→Bookings;
    /// instructor .bookings→Calendar, .reviews→Profile·Reviews, .community→Community, .coverage→Dashboard.
    var topic: PushTopic? {
        switch self {
        case .bookingRequest, .bookingConfirmed, .bookingCancelled: return .bookings
        // Attendance / fees / coverage / posted-opportunity applications all live on the instructor
        // Dashboard, which .coverage routes to.
        case .attendanceNeeded, .feeOwed,
             .coverageOffer, .coverageClaim, .coverageCovered,
             .opportunityApplication:
            return .coverage
        case .message:            return .messages
        case .reviewReceived, .recommendation: return .reviews
        case .comment, .eventJoinRequest:      return .community
        // Applicant-side decisions can go to a student OR an instructor and have no single tab — leave
        // them informational.
        case .applicationAdvanced, .applicationHired, .applicationDeclined: return nil
        }
    }
}

// MARK: - Activity item

/// One row in the feed. `rawDate` is the time of the event the row ANNOUNCES — which for bookings is
/// three different moments, not one: a request dates from `RemoteBooking.createdAt`, a confirmation
/// from `RemoteDecision.respondedAt`, a cancellation from `RemoteBooking.modifiedAt`, and an
/// attendance/fee obligation from the session's own end. All are harvested at sync (the local
/// `Booking` @Model stores none of them) into `MockDataStore.bookingRequestedAt` / `bookingDecidedAt`
/// / `bookingCancelledAt`. nil only for a row that has never synced, where [[ActivityLedger]]'s
/// first-observed-on-this-device date IS the truth. `isActionable` marks rows backed by a real pending
/// flag (a request, an unread message, an owed fee) — those stay unread until the flag clears,
/// independent of the last-opened watermark.
struct ActivityItem: Identifiable {
    let id: String
    let kind: ActivityKind
    let rawDate: Date?
    let actorName: String
    let avatarID: String
    let avatarPhoto: Data?
    var detail: String = ""
    var detail2: String? = nil
    var rating: Int? = nil
    var isActionable: Bool = false
}

// MARK: - Time buckets

enum ActivityBucket: Int, CaseIterable, Identifiable {
    case today, thisWeek, thisMonth, earlier
    var id: Int { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .today:     return "Today"
        case .thisWeek:  return "This week"
        case .thisMonth: return "This month"
        case .earlier:   return "Earlier"
        }
    }
    static func of(_ date: Date, now: Date, calendar: Calendar = .current) -> ActivityBucket {
        if calendar.isDateInToday(date) { return .today }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now), date >= weekAgo { return .thisWeek }
        if let monthAgo = calendar.date(byAdding: .day, value: -30, to: now), date >= monthAgo { return .thisMonth }
        return .earlier
    }
}

// MARK: - Activity ledger
//
// The one piece of persistence the feed needs. Since bookings/likes carry no received-timestamp and
// there is no server log, the ledger stamps each derived item's id with the moment it was FIRST seen
// on this device (`firstSeen`), giving every row a real time to sort/group by — exactly how a client
// notification feed works with no backend. Unread = the item is actionable, OR it was first seen
// AFTER the inbox was last opened (`lastOpened`, per role). Local only (UserDefaults) — never CloudKit.

@Observable
final class ActivityLedger {
    static let shared = ActivityLedger()

    private static let firstSeenKey = "activity.firstSeen.v1"
    private static let lastOpenedKey = "activity.lastOpened.v1"
    /// Cap on remembered ids so the store can't grow without bound; oldest are pruned first.
    private static let maxRemembered = 400

    private var firstSeen: [String: Double]
    private var lastOpened: [String: Double]

    private init() {
        let d = UserDefaults.standard
        firstSeen = (d.dictionary(forKey: Self.firstSeenKey) as? [String: Double]) ?? [:]
        lastOpened = (d.dictionary(forKey: Self.lastOpenedKey) as? [String: Double]) ?? [:]
    }

    private func role(_ isInstructor: Bool) -> String { isInstructor ? "instructor" : "student" }

    /// The date a row sorts/groups by: its real event time, else the first-observed time, else now.
    func date(for item: ActivityItem) -> Date {
        if let raw = item.rawDate { return raw }
        if let seen = firstSeen[item.id] { return Date(timeIntervalSince1970: seen) }
        return Date()
    }

    /// Unread until read: an actionable row stays lit while its flag holds; any other row is unread
    /// while its first-seen time is newer than the last time this role opened the inbox. An id never
    /// seen before is treated as brand-new (unread), so the badge is correct before the first open.
    func isUnread(_ item: ActivityItem, isInstructor: Bool) -> Bool {
        if item.isActionable { return true }
        let seen = firstSeen[item.id] ?? Date().timeIntervalSince1970
        return seen > (lastOpened[role(isInstructor)] ?? 0)
    }

    func unreadCount(_ items: [ActivityItem], isInstructor: Bool) -> Int {
        items.reduce(0) { $0 + (isUnread($1, isInstructor: isInstructor) ? 1 : 0) }
    }

    /// Persist a first-seen stamp for any id we haven't recorded yet. Idempotent; call when the feed
    /// is shown (NOT on every render).
    func observe(_ items: [ActivityItem]) {
        let now = Date().timeIntervalSince1970
        var changed = false
        for item in items where firstSeen[item.id] == nil {
            firstSeen[item.id] = now
            changed = true
        }
        guard changed else { return }
        if firstSeen.count > Self.maxRemembered {
            let survivors = firstSeen.sorted { $0.value > $1.value }.prefix(Self.maxRemembered)
            firstSeen = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(firstSeen, forKey: Self.firstSeenKey)
    }

    /// Mark everything currently visible as read for this role.
    func markOpened(isInstructor: Bool) {
        lastOpened[role(isInstructor)] = Date().timeIntervalSince1970
        UserDefaults.standard.set(lastOpened, forKey: Self.lastOpenedKey)
    }
}

// MARK: - Feed aggregation
//
// Composes the activity feed from existing store accessors. Each helper is best-effort and guarded —
// a source with no data simply contributes no rows. Kinds not yet derivable (inbound follows, a
// followed-instructor's new training video, likes without a timestamp) are intentionally omitted;
// see [[NotificationCenter]] for the full catalog and the deferred rows.

extension MockDataStore {

    /// The role-aware activity feed, newest first, capped so a cold start can't produce an unbounded
    /// list. `isInstructor` decides which side of each two-sided event this user receives.
    func activityFeed(isInstructor: Bool) -> [ActivityItem] {
        guard currentUserID != nil else { return [] }
        var items: [ActivityItem] = []
        if isInstructor {
            items += instructorBookingActivity()
            items += instructorCoverageActivity()
            items += instructorCommunityActivity()
            items += instructorMarketplaceActivity()
            items += reviewActivity()
        } else {
            items += studentBookingActivity()
            items += studentCoverageActivity()
        }
        items += messageActivity()
        items += applicantDecisionActivity()

        let ledger = ActivityLedger.shared
        return items
            .sorted { ledger.date(for: $0) > ledger.date(for: $1) }
            .prefix(120)
            .map { $0 }
    }

    // MARK: Bookings

    /// A stable id for a booking row across launches: its server record name, or a deterministic
    /// composite for a not-yet-uploaded local booking.
    private func stableKey(_ b: Booking) -> String {
        b.remoteID ?? "\(b.legacyId)-\(b.date)-\(b.time)-\(b.studentID ?? "")"
    }

    /// When this booking was actually REQUESTED, from the server's `createdAt` (see
    /// `MockDataStore.bookingRequestedAt`). nil for a purely local row that has never synced — the
    /// ledger's first-seen stamp is the correct fallback there, since it genuinely was created now.
    private func requestedAt(_ b: Booking) -> Date? {
        b.remoteID.flatMap { bookingRequestedAt[$0] }
    }

    /// When the instructor CONFIRMED it (`RemoteDecision.respondedAt`), falling back to the request
    /// time. A "confirmed your session" row must date from the confirmation, not from the request —
    /// those can be days apart, and dating it by the request makes a fresh confirmation look stale.
    private func decidedAt(_ b: Booking) -> Date? {
        b.remoteID.flatMap { bookingDecidedAt[$0] } ?? requestedAt(b)
    }

    /// When it was CANCELLED (`RemoteBooking.modifiedAt` / the backend's `cancelled_at`), falling back
    /// to the decision then the request time.
    private func cancelledAt(_ b: Booking) -> Date? {
        b.remoteID.flatMap { bookingCancelledAt[$0] } ?? decidedAt(b)
    }

    /// When the OBLIGATION arose for a finished session — attendance to mark, or a fee owed. That is the
    /// moment the session ended, not when it was booked, so these rows sort by when they became due.
    private func sessionEndedAt(_ b: Booking) -> Date? {
        b.sessionEnd() ?? requestedAt(b)
    }

    private func instructorBookingActivity() -> [ActivityItem] {
        var out: [ActivityItem] = []
        // Names live-resolve: booking.studentName is a frozen snapshot that reads "Member" for a
        // student who booked before setting a name. Matches SessionRow/StudentsList/ReviewRow.
        func actor(_ b: Booking) -> String {
            displayIdentity(ownerID: b.studentID, fallbackName: b.studentName).name
        }
        for b in pendingRequestCards {
            out.append(ActivityItem(
                id: "req-\(stableKey(b))", kind: .bookingRequest, rawDate: requestedAt(b),
                actorName: actor(b), avatarID: "", avatarPhoto: studentPhoto(forOwnerID: b.studentID ?? ""),
                detail: b.type, detail2: "\(b.date) · \(b.time)", isActionable: true))
        }
        for b in sessionsAwaitingAttendance {
            out.append(ActivityItem(
                id: "att-\(stableKey(b))", kind: .attendanceNeeded, rawDate: sessionEndedAt(b),
                actorName: actor(b), avatarID: "", avatarPhoto: studentPhoto(forOwnerID: b.studentID ?? ""),
                detail: b.type, isActionable: true))
        }
        for b in owedFees {
            out.append(ActivityItem(
                id: "fee-\(stableKey(b))", kind: .feeOwed, rawDate: sessionEndedAt(b),
                actorName: actor(b), avatarID: "", avatarPhoto: studentPhoto(forOwnerID: b.studentID ?? ""),
                detail: b.type, detail2: "₪\(b.feeAmount)", isActionable: true))
        }
        return out
    }

    private func studentBookingActivity() -> [ActivityItem] {
        var out: [ActivityItem] = []
        for b in myBookings {
            let ins = instructor(ownerID: b.instructorOwnerID)
            switch b.status {
            case .confirmed:
                out.append(ActivityItem(
                    id: "conf-\(stableKey(b))", kind: .bookingConfirmed, rawDate: decidedAt(b),
                    actorName: ins?.name ?? "", avatarID: ins?.img ?? "", avatarPhoto: ins?.photo,
                    detail: b.type, detail2: "\(b.date) · \(b.time)"))
            case .cancelled:
                out.append(ActivityItem(
                    id: "canc-\(stableKey(b))", kind: .bookingCancelled, rawDate: cancelledAt(b),
                    actorName: ins?.name ?? "", avatarID: ins?.img ?? "", avatarPhoto: ins?.photo,
                    detail: b.type, detail2: "\(b.date) · \(b.time)"))
            default:
                break
            }
        }
        return out
    }

    // MARK: Messages

    private func messageActivity() -> [ActivityItem] {
        conversations.map { c in
            ActivityItem(
                id: "msg-\(c.counterpart.id)", kind: .message, rawDate: c.lastSentAt,
                actorName: c.counterpart.displayName, avatarID: c.counterpart.avatarID,
                avatarPhoto: c.counterpart.photo, isActionable: c.hasUnread)
        }
    }

    // MARK: Reviews

    private func reviewActivity() -> [ActivityItem] {
        myReviews.map { r in
            // Live-resolve: r.studentName is the frozen review-time snapshot ("Member" for a student
            // who reviewed before setting a name). Matches ReviewRow, which already resolves.
            let who = displayIdentity(ownerID: r.studentID, fallbackName: r.studentName)
            return ActivityItem(
                id: "rev-\(r.bookingID)-\(r.studentID)", kind: .reviewReceived, rawDate: r.createdAt,
                actorName: who.name, avatarID: who.img, avatarPhoto: who.photo, rating: r.rating)
        }
    }

    // MARK: Coverage

    private func instructorCoverageActivity() -> [ActivityItem] {
        var out: [ActivityItem] = []
        for o in myOffers {
            let ins = instructors.first { $0.ownerID == o.requesterID }
            out.append(ActivityItem(
                id: "offer-\(o.bookingID)", kind: .coverageOffer, rawDate: o.createdAt,
                actorName: ins?.name ?? "", avatarID: ins?.img ?? "", avatarPhoto: ins?.photo,
                detail: o.sessionType, detail2: o.sessionDate, isActionable: true))
        }
        for c in myClaims {
            let ins = instructors.first { $0.ownerID == c.replacerID }
            out.append(ActivityItem(
                id: "claim-\(c.bookingID)-\(c.replacerID)", kind: .coverageClaim, rawDate: c.claimedAt,
                actorName: c.replacerName, avatarID: ins?.img ?? "", avatarPhoto: ins?.photo,
                isActionable: true))
        }
        return out
    }

    private func studentCoverageActivity() -> [ActivityItem] {
        var out: [ActivityItem] = []
        for b in myBookings {
            guard let rid = b.remoteID, let cov = coverSession(forBookingID: rid), cov.status == 0 else { continue }
            let ins = instructors.first { $0.ownerID == cov.coveringInstructorID }
            out.append(ActivityItem(
                id: "cov-\(rid)", kind: .coverageCovered, rawDate: cov.createdAt,
                actorName: cov.coveringInstructorName, avatarID: ins?.img ?? "", avatarPhoto: ins?.photo,
                detail: b.type))
        }
        return out
    }

    // MARK: Community

    private func instructorCommunityActivity() -> [ActivityItem] {
        var out: [ActivityItem] = []
        // Comments on my posts.
        for post in posts where isMine(post) {
            for c in comments(for: post) where !isMine(c) {
                let who = displayIdentity(ownerID: c.authorID, fallbackName: c.authorName)
                out.append(ActivityItem(
                    id: "cmt-\(c.remoteID ?? "\(c.postID)-\(c.authorID)-\(c.createdAt.timeIntervalSince1970)")",
                    kind: .comment, rawDate: c.createdAt,
                    actorName: who.name, avatarID: who.img, avatarPhoto: who.photo))
            }
        }
        // Recommendations written about me.
        for r in myRecommendations {
            let who = displayIdentity(ownerID: r.fromID, fallbackName: r.fromName)
            out.append(ActivityItem(
                id: "rec-\(r.fromID)", kind: .recommendation, rawDate: r.createdAt,
                actorName: who.name, avatarID: who.img, avatarPhoto: who.photo))
        }
        // Join requests on my events.
        for event in myEvents {
            for req in pendingRequests(for: event) {
                let who = displayIdentity(ownerID: req.studentID, fallbackName: req.studentName)
                out.append(ActivityItem(
                    id: "evreq-\(event.remoteID ?? "")-\(req.studentID)", kind: .eventJoinRequest,
                    rawDate: req.joinedAt, actorName: who.name, avatarID: who.img, avatarPhoto: who.photo,
                    detail: event.title, isActionable: true))
            }
        }
        return out
    }

    // MARK: Marketplace (Flowe Pro)

    private func instructorMarketplaceActivity() -> [ActivityItem] {
        guard let me = currentUserID else { return [] }
        return opportunityApplications
            .filter { $0.posterID == me && !$0.withdrawn }
            .map { app in
                let title = opportunities.first { $0.key == app.opportunityID }?.title ?? ""
                return ActivityItem(
                    id: "app-\(app.opportunityID)-\(app.applicantID)", kind: .opportunityApplication,
                    rawDate: app.createdAt, actorName: app.applicantName, avatarID: "", avatarPhoto: nil,
                    detail: title)
            }
    }

    /// Applicant-side decisions — the same rows for a student or instructor applicant, so both shells
    /// surface them.
    private func applicantDecisionActivity() -> [ActivityItem] {
        guard let me = currentUserID else { return [] }
        return applicationDecisions.filter { $0.applicantID == me }.compactMap { dec in
            let opp = opportunities.first { $0.key == dec.opportunityID }
            let kind: ActivityKind
            switch dec.stageRaw {
            case ApplicationStage.hired.rawValue:    kind = .applicationHired
            case ApplicationStage.declined.rawValue: kind = .applicationDeclined
            case ApplicationStage.shortlisted.rawValue, ApplicationStage.talking.rawValue, ApplicationStage.offer.rawValue:
                kind = .applicationAdvanced
            default: return nil
            }
            return ActivityItem(
                id: "dec-\(dec.opportunityID)", kind: kind, rawDate: dec.updatedAt,
                actorName: opp?.posterName ?? "", avatarID: "", avatarPhoto: nil, detail: opp?.title ?? "")
        }
    }
}

