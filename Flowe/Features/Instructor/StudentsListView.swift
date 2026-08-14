import SwiftUI

// MARK: - Derived student summary

/// A single client in the instructor's book — a value type derived on-device from the instructor's own
/// bookings. Deliberately NOT an `@Model` / CloudKit record: it is recomputed from `incomingBookings`
/// each read, so it adds no schema and no new data exposure. `id` is the student's ownerID, which is
/// all the Message action and `StudentProfileView` need.
struct StudentSummary: Identifiable, Hashable {
    let id: String            // student ownerID
    let name: String
    let photo: Data?
    /// Non-cancelled bookings with this student (the relationship's size).
    let totalSessions: Int
    /// Sessions actually taught (status `.completed`).
    let completedSessions: Int
    /// End of the most recent completed session — the only recency signal a booking carries.
    let lastSeen: Date?
    /// Soonest confirmed session still to happen, if any.
    let nextSession: Date?
    /// No-show / fee-worthy late-cancel strikes — the No-Show Shield signal.
    let strikes: Int

    var hasUpcoming: Bool { nextSession != nil }
}

// MARK: - Derivation (instructor's own bookings only)

extension MockDataStore {
    /// The instructor's client book: one entry per student who has booked them, derived ONLY from
    /// `incomingBookings` (already scoped to `instructorOwnerID == currentUserID`) — no broad student
    /// query, no new record type. Mirrors `addressBook(asInstructor:)`'s guard, so nil-studentID
    /// legacy/seed rows and blocked students are excluded, meaning every listed student is messageable
    /// and has a resolvable profile.
    var instructorStudents: [StudentSummary] {
        let now = Date()
        let grouped = Dictionary(grouping: incomingBookings.filter { booking in
            guard let id = booking.studentID else { return false }
            return !isBlocked(id)
        }, by: { $0.studentID ?? "" })

        return grouped.compactMap { id, all -> StudentSummary? in
            let active = all.filter { $0.status != .cancelled }
            guard !active.isEmpty else { return nil }   // only cancelled history → not a real client

            let completed = active.filter { $0.status == .completed }
            let lastSeen = completed.compactMap { $0.sessionEnd(now: now) }.max()
            let next = active
                .filter { $0.status == .confirmed }
                .compactMap { booking in booking.sessionEnd(now: now).map { (booking, $0) } }
                .filter { $0.1 > now }
                .min { $0.1 < $1.1 }?
                .1

            return StudentSummary(
                id: id,
                // Resolve the name from the LIVE StudentProfile cache (`displayIdentity`, the same
                // source the photo already used), NOT the booking's frozen `studentName` snapshot — a
                // student who set/changed their name AFTER booking would otherwise stay stuck on the
                // old snapshot ("Member") here while their photo updated. The best non-empty snapshot
                // is the fallback for a student with no cached profile. Matches Calendar/SessionRow/
                // ReviewRow, which already resolve this way.
                name: displayIdentity(
                    ownerID: id,
                    fallbackName: active.first { !$0.studentName.isEmpty }?.studentName ?? ""
                ).name,
                photo: studentPhoto(forOwnerID: id),
                totalSessions: active.count,
                completedSessions: completed.count,
                lastSeen: lastSeen,
                nextSession: next,
                strikes: noShowStrikes(forStudentID: id)
            )
        }
        // Upcoming clients first (future date sorts high), then most recently seen.
        .sorted { ($0.nextSession ?? $0.lastSeen ?? .distantPast) > ($1.nextSession ?? $1.lastSeen ?? .distantPast) }
    }
}

// MARK: - Students screen

/// The instructor's client book: a de-duplicated, searchable list of every student who has booked them,
/// with smart categories computed on-device from booking history. A row taps through to the existing
/// read-only `StudentProfileView`; a Message action deep-links to that student's thread via the router.
struct StudentsListView: View {
    @Environment(MockDataStore.self) private var data
    @Environment(InstructorRouter.self) private var router

    @State private var search = ""
    @State private var category: String = StudentCategory.all.rawValue
    @State private var profileTarget: StudentSummary?

    // Windows kept under the ~26-week `sessionEnd()` nearest-year reconstruction ceiling (see Booking).
    private static let regularWindow: TimeInterval = 42 * 86_400   // 6 weeks
    private static let newWindow: TimeInterval = 28 * 86_400       // 4 weeks
    private static let lapsedWindow: TimeInterval = 42 * 86_400    // 6 weeks

    private var students: [StudentSummary] { data.instructorStudents }

    /// Students matching the selected category, then the search text. Categories are independent
    /// predicates over the SAME list (a student can match several) — not a partition.
    private var filtered: [StudentSummary] {
        let now = Date()
        let inCategory = students.filter { Self.matches($0, StudentCategory(rawValue: category) ?? .all, now: now) }
        guard !search.isEmpty else { return inCategory }
        let q = search.lowercased()
        return inCategory.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    searchField
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                        .padding(.bottom, 12)

                    FilterChipsBar(items: StudentCategory.allCases.map(\.rawValue), selection: $category)
                        .padding(.bottom, 12)

                    ForEach(filtered) { summary in
                        Button { profileTarget = summary } label: { row(summary) }
                            .buttonStyle(.plain)
                        Divider().overlay(Color.floweBorder).padding(.leading, 82)
                    }

                    if students.isEmpty {
                        EmptyStateView(
                            icon: "person.2",
                            title: "No students yet",
                            message: "Students who book a session with you will appear here."
                        )
                        .padding(.top, 60)
                    } else if filtered.isEmpty {
                        emptyCategoryState
                    }
                }
            }
            .background(Color.flowWhite)
            .safeAreaInset(edge: .top, spacing: 0) { header }
        }
        .sheet(item: $profileTarget) { summary in
            StudentProfileView(studentID: summary.id, studentName: summary.name,
                               onMessage: { message(summary) },
                               onClose: { profileTarget = nil })
        }
    }

    // MARK: - Message redirect

    /// The shared redirect used by both the profile CTA and the inline row button: dismiss the sheet
    /// (so it doesn't linger over the Messages tab) THEN deep-link to the student's thread.
    private func message(_ summary: StudentSummary) {
        profileTarget = nil
        router.openConversation(with: Counterpart(id: summary.id, name: summary.name, photo: summary.photo))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Students")
                .font(FloweFont.serif(20))
                .foregroundStyle(Color.floweInk)
            Spacer()
            Text("\(students.count)")
                .font(FloweFont.mono(13))
                .foregroundStyle(Color.floweMuted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.flowWhite)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.floweBorder).frame(height: 1)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(Color.floweMuted)
            TextField("", text: $search, prompt: Text("Search students…").foregroundColor(Color.floweMuted))
                .font(FloweFont.sans(14))
                .foregroundStyle(Color.floweInk)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.floweMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.floweCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.floweBorder, lineWidth: 1))
    }

    // MARK: - Row

    private func row(_ summary: StudentSummary) -> some View {
        HStack(spacing: 14) {
            AvatarView(id: "", photo: summary.photo, size: 50)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(summary.name.isEmpty ? "Student" : summary.name)
                        .font(FloweFont.serif(15))
                        .foregroundStyle(Color.floweInk)
                        .lineLimit(1)
                    if summary.strikes > 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.floweCancel)
                    }
                    if data.clientNoteHasFlags(forStudentID: summary.id) {
                        ClientNoteFlag(size: 10)
                    }
                }
                Text(statLine(summary))
                    .font(FloweFont.sans(13))
                    .foregroundStyle(Color.floweMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button { message(summary) } label: {
                Image(systemName: "message")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.flowePinkDeep)
                    .frame(width: 36, height: 36)
                    .background(Color.floweCardBg)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.floweBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Message \(summary.name.isEmpty ? "student" : summary.name)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    /// "12 sessions · Next Tue" / "3 sessions · Last seen 4d" — the key stat under the name.
    private func statLine(_ summary: StudentSummary) -> String {
        let count = summary.completedSessions
        let sessions = "\(count) \(count == 1 ? "session" : "sessions")"
        if let next = summary.nextSession {
            return "\(sessions) · Next \(Self.shortDate(next))"
        }
        if let last = summary.lastSeen {
            return "\(sessions) · Last seen \(MessageListView.relativeTime(last))"
        }
        return sessions
    }

    /// "Tue" this week, otherwise "12 Mar" — for a future session where `relativeTime` (past-only) doesn't fit.
    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = date.timeIntervalSinceNow < 7 * 86_400 ? "EEE" : "d MMM"
        return formatter.string(from: date)
    }

    private var emptyCategoryState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2")
                .font(.system(size: 34))
                .foregroundStyle(Color.flowePinkSoft)
            Text("No students here")
                .font(FloweFont.serif(17))
                .foregroundStyle(Color.floweInk)
            Text(search.isEmpty ? "Try another category." : "Try a different name.")
                .font(FloweFont.sans(13))
                .foregroundStyle(Color.floweMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Categories

    /// The segmented filters. Each is an independent predicate over the one derived list, computed from
    /// existing booking fields only — never a stored metric. See `matches(_:_:now:)` for the exact rules.
    private enum StudentCategory: String, CaseIterable {
        case all      = "All"
        case regulars = "Regulars"
        case new      = "New"
        case upcoming = "Upcoming"
        case winback  = "Win-back"
        case risk     = "No-show risk"
    }

    private static func matches(_ s: StudentSummary, _ category: StudentCategory, now: Date) -> Bool {
        switch category {
        case .all:
            return true
        case .regulars:
            // Frequency proxied by completed-count + recency (the reconstructed timeline isn't reliable
            // enough for a true rate).
            guard let last = s.lastSeen else { return false }
            return s.completedSessions >= 3 && now.timeIntervalSince(last) <= regularWindow
        case .new:
            // No per-instructor first-session date exists, so "new" = a single booking that is upcoming
            // or recent — an honest approximation, not a signup date.
            if s.totalSessions != 1 { return false }
            if s.hasUpcoming { return true }
            guard let last = s.lastSeen else { return false }
            return now.timeIntervalSince(last) <= newWindow
        case .upcoming:
            return s.hasUpcoming
        case .winback:
            // Lapsed: taught before, nothing on the books, not seen in the window. Requires a COMPLETED
            // session so a lone old cancelled request never looks like a win-back target.
            guard let last = s.lastSeen else { return false }
            return s.completedSessions >= 1 && !s.hasUpcoming && now.timeIntervalSince(last) > lapsedWindow
        case .risk:
            return s.strikes > 0
        }
    }
}
