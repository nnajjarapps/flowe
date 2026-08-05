import SwiftUI

// MARK: - Week-strip day pill

/// A selectable weekday pill. Selected uses the deep-pink gradient; a small dot
/// marks days that have sessions.
struct WeekDayPill: View {
    let day: WeekDay
    let isSelected: Bool
    let hasSessions: Bool
    /// The instructor closed this date off (vacation). Reads as a struck-through, muted number so the
    /// instructor sees their own time off on the strip. Defaults false for callers that don't set it.
    var isClosed: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                weekdayText
                    .font(FloweFont.mono(10))
                    .foregroundStyle(isSelected ? .white.opacity(0.85)
                                     : (day.isToday ? Color.flowePinkDeep : Color.floweMuted))

                Text(day.displayNumber)
                    .font(FloweFont.serif(18, .medium))
                    .foregroundStyle(isSelected ? .white : (isClosed ? Color.floweMuted : Color.floweInk))
                    .strikethrough(isClosed, color: isSelected ? .white.opacity(0.7) : Color.floweMuted)

                Circle()
                    .fill(dotColor)
                    .frame(width: 5, height: 5)
            }
            .frame(width: 46)
            .padding(.vertical, 12)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(FlowGradients.gradDark)
                } else {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.floweCardBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(Color.floweBorder, lineWidth: 1)
                        )
                }
            }
        }
        .flowePressable()
    }

    /// "TODAY" (localized) on the current day, otherwise the localized weekday. The weekday is
    /// already region-formatted data, so it's rendered verbatim rather than looked up as a key.
    private var weekdayText: Text {
        day.isToday
            ? Text(LocalizedStringKey("TODAY"))
            : Text(verbatim: day.displayWeekday.uppercased())
    }

    private var dotColor: Color {
        if isSelected { return hasSessions ? .white.opacity(0.9) : .clear }
        return hasSessions ? .flowePink : .clear
    }
}

// MARK: - Month overview grid

/// A calendar-month overview: a titled, pageable month with a weekday header and a 7-column grid of
/// day cells. Days outside the bookable window (before today, or beyond the paging cap) render dimmed
/// and non-selectable; a selectable day with sessions shows a small count dot. Tapping a day reports
/// its absolute offset-from-today id. Uses `LazyVGrid`, which lays out leading→trailing and mirrors
/// automatically under RTL.
struct MonthGrid: View {
    let monthOffset: Int
    let selectedDay: Int
    let sessionCount: (Date) -> Int
    /// Whether a given date is closed off (vacation), so the cell can mark it. Defaults to "never
    /// closed" for callers that don't supply it.
    var isClosed: (Date) -> Bool = { _ in false }
    let onPrev: () -> Void
    let onNext: () -> Void
    let onSelect: (Int) -> Void

    private var grid: (title: String, weekdaySymbols: [String], cells: [FloweWeek.MonthCell]) {
        FloweWeek.monthGrid(monthOffset: monthOffset)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
    }

    /// Past months are never shown (no bookings before today); forward paging stops once the shown
    /// month already reaches the last selectable day.
    private var prevDisabled: Bool { monthOffset <= 0 }
    private var nextDisabled: Bool {
        (grid.cells.compactMap { $0.day?.id }.max() ?? 0) >= FloweWeek.maxDayID
    }

    var body: some View {
        let g = grid
        VStack(spacing: FlowSpacing.md) {
            HStack {
                Button(action: onPrev) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(prevDisabled ? Color.floweMuted.opacity(0.4) : Color.flowePinkDeep)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .disabled(prevDisabled)
                .accessibilityLabel("Previous month")

                Spacer()
                Text(verbatim: g.title)
                    .font(FloweFont.serif(17, .medium))
                    .foregroundStyle(Color.floweInk)
                Spacer()

                Button(action: onNext) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(nextDisabled ? Color.floweMuted.opacity(0.4) : Color.flowePinkDeep)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .disabled(nextDisabled)
                .accessibilityLabel("Next month")
            }

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(g.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(verbatim: symbol)
                        .font(FloweFont.mono(10))
                        .foregroundStyle(Color.floweMuted)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(g.cells) { cell in
                    if let day = cell.day {
                        MonthDayCell(
                            day: day,
                            isSelected: day.id == selectedDay,
                            sessionCount: sessionCount(day.date),
                            isClosed: isClosed(day.date),
                            action: { onSelect(day.id) }
                        )
                    } else {
                        Color.clear.frame(height: 44)
                    }
                }
            }
        }
        .padding(FlowSpacing.md)
        .floweCard()
    }
}

/// A single day in the month grid. Selectable only when its absolute id is within the bookable
/// window (0…`FloweWeek.maxDayID`); past/beyond-cap days are dimmed and disabled. Selected uses the
/// deep-pink gradient (mirroring `WeekDayPill`); a dot marks days that have sessions.
struct MonthDayCell: View {
    let day: WeekDay
    let isSelected: Bool
    let sessionCount: Int
    /// The instructor closed this date off (vacation) — rendered with a struck-through number.
    var isClosed: Bool = false
    let action: () -> Void

    private var selectable: Bool { day.id >= 0 && day.id <= FloweWeek.maxDayID }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(day.displayNumber)
                    .font(FloweFont.serif(15, .medium))
                    .foregroundStyle(numberColor)
                    .strikethrough(isClosed, color: isSelected ? .white.opacity(0.7) : Color.floweMuted)
                Circle()
                    .fill(dotColor)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12).fill(FlowGradients.gradDark)
                } else if day.isToday {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.flowePinkDeep.opacity(0.5), lineWidth: 1)
                }
            }
            .opacity(selectable ? 1 : 0.3)
        }
        .flowePressable()
        .disabled(!selectable)
    }

    private var numberColor: Color {
        if isSelected { return .white }
        return day.isToday ? Color.flowePinkDeep : Color.floweInk
    }

    private var dotColor: Color {
        guard sessionCount > 0 else { return .clear }
        return isSelected ? .white.opacity(0.9) : .flowePink
    }
}

// MARK: - Session card (selected day)

/// A booked slot on the selected day: time column, student avatar + name,
/// session type, and a status badge.
struct CalendarSessionCard: View {
    let session: Booking

    @Environment(MockDataStore.self) private var data
    @Environment(InstructorRouter.self) private var router
    @Environment(\.locale) private var locale
    @State private var showStudent = false

    /// A standing session the instructor can either skip for one week (per-occurrence decline) or end
    /// for good (series-end tombstone). One enum-driven `.confirmationDialog` — a second one would
    /// shadow the first (the same SwiftUI trap the student card documents).
    private enum SkipEnd { case skip, endSeries }
    @State private var skipEnd: SkipEnd?

    /// Skip/end is only offered on a live standing week — not on a cancelled or already-delivered one.
    private var canManageSeries: Bool {
        session.isRecurring && session.status != .cancelled && session.status != .completed
    }

    var body: some View {
        HStack(spacing: FlowSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.localizedTime(locale))
                    .font(FloweFont.mono(12))
                    .foregroundStyle(Color.flowePinkDeep)
                Text("\(session.durationMinutes) min")
                    .font(FloweFont.mono(9))
                    .foregroundStyle(Color.floweMuted)
            }
            .frame(width: 62, alignment: .leading)

            Rectangle()
                .fill(Color.floweBorder)
                .frame(width: 1, height: 40)

            Button {
                if session.studentID != nil { showStudent = true }
            } label: {
                HStack(spacing: FlowSpacing.md) {
                    AvatarView(id: "", photo: data.studentPhoto(forOwnerID: session.studentID ?? ""), size: 42)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            ({ () -> Text in
                                let n = data.displayIdentity(ownerID: session.studentID, fallbackName: session.studentName).name
                                return n.isEmpty ? Text("Student") : Text(n)   // literal localizes; a real name stays verbatim
                            }())
                                .font(FloweFont.serif(16, .medium))
                                .foregroundStyle(Color.floweInk)
                                .lineLimit(1)
                            if data.clientNote(forStudentID: session.studentID ?? "")?.hasFlags == true {
                                ClientNoteFlag()
                            }
                        }
                        Text(localizedTag: session.type)
                            .textCase(.uppercase)
                            .font(FloweFont.mono(10))
                            .foregroundStyle(Color.floweMuted)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: FlowSpacing.sm)

            VStack(alignment: .trailing, spacing: 4) {
                StatusBadge(status: session.status)
            }

            if canManageSeries { seriesMenu }
        }
        .padding(FlowSpacing.md)
        .floweCard()
        .sheet(isPresented: $showStudent) {
            StudentProfileView(studentID: session.studentID ?? "", studentName: session.studentName,
                               onMessage: {
                                   showStudent = false
                                   let id = session.studentID ?? ""
                                   router.openConversation(with: Counterpart(id: id, name: session.studentName,
                                                                             photo: data.studentPhoto(forOwnerID: id)))
                               },
                               onClose: { showStudent = false })
        }
        .confirmationDialog(skipEndTitle, isPresented: skipEndBinding, titleVisibility: .visible) {
            switch skipEnd {
            case .skip:
                // Per-occurrence decline: cancels just this week; the series stays approved.
                Button("Skip this week", role: .destructive) { data.respond(to: session, confirmed: false) }
                Button("Keep it", role: .cancel) { }
            default:
                // Series-end tombstone: cancels every future week without touching the student's records.
                Button("End series", role: .destructive) { data.respondSeries(session, confirmed: false) }
                Button("Keep it", role: .cancel) { }
            }
        } message: {
            switch skipEnd {
            case .skip:      Text("This cancels only this week. Your weekly slot stays booked.")
            default:         Text("This cancels all upcoming weeks. Past sessions stay.")
            }
        }
    }

    /// Overflow menu for a standing week: skip just this week, or end the whole series.
    private var seriesMenu: some View {
        Menu {
            Button { skipEnd = .skip } label: {
                Label("Skip this week", systemImage: "forward")
            }
            Button(role: .destructive) { skipEnd = .endSeries } label: {
                Label("End series", systemImage: "xmark.circle")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.floweMuted)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Manage weekly session")
    }

    private var skipEndTitle: String {
        skipEnd == .skip ? String(localized: "Skip just this week?") : String(localized: "End this weekly series?")
    }

    private var skipEndBinding: Binding<Bool> {
        Binding(get: { skipEnd != nil }, set: { if !$0 { skipEnd = nil } })
    }
}

// MARK: - Group / duet roster card (selected day)

/// A group/duet class shown as ONE class entity: shared time + type header with an "N of M booked"
/// gauge, an optional waitlist count, and the ROSTER of booked students (avatar + name + status).
/// The instructor cannot attribute a specific seat index to a student — the seat lives in the
/// student-private `holdRecordName`, never uploaded — so this shows COUNTS only: `sessions.count` is
/// the true total booked, `capacity` the class size, and any excess is the waitlist. Each student is
/// still a separate `Booking` (per-student accept/decline unchanged); this only groups them for view.
struct CalendarGroupSessionCard: View {
    let sessions: [Booking]
    let capacity: Int

    @Environment(MockDataStore.self) private var data
    @Environment(InstructorRouter.self) private var router
    @Environment(\.locale) private var locale
    @State private var selectedStudent: Booking?

    private var primary: Booking { sessions[0] }
    private var seated: Int { min(sessions.count, capacity) }

    var body: some View {
        VStack(alignment: .leading, spacing: FlowSpacing.md) {
            HStack(spacing: FlowSpacing.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(primary.localizedTime(locale))
                        .font(FloweFont.mono(12))
                        .foregroundStyle(Color.flowePinkDeep)
                    Text("\(primary.durationMinutes) min")
                        .font(FloweFont.mono(9))
                        .foregroundStyle(Color.floweMuted)
                }
                .frame(width: 62, alignment: .leading)

                Rectangle()
                    .fill(Color.floweBorder)
                    .frame(width: 1, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(localizedTag: primary.type)
                        .textCase(.uppercase)
                        .font(FloweFont.mono(10))
                        .foregroundStyle(Color.floweMuted)
                    Text("\(seated) of \(capacity) booked")
                        .font(FloweFont.serif(16, .medium))
                        .foregroundStyle(Color.floweInk)
                }

                Spacer(minLength: FlowSpacing.sm)
            }

            Rectangle()
                .fill(Color.floweBorder)
                .frame(height: 1)

            // The roster: one tappable row per booked student (avatar + name + per-student status).
            VStack(spacing: FlowSpacing.sm) {
                ForEach(sessions) { s in
                    Button {
                        if s.studentID != nil { selectedStudent = s }
                    } label: {
                        HStack(spacing: FlowSpacing.sm) {
                            // One resolved identity feeds both avatar and name (name + photo from the same source).
                            let idty = data.displayIdentity(ownerID: s.studentID, fallbackName: s.studentName)
                            AvatarView(id: idty.img, photo: idty.photo, size: 34)
                            (idty.name.isEmpty ? Text("Student") : Text(idty.name))
                                .font(FloweFont.sans(13))
                                .foregroundStyle(Color.floweInk)
                                .lineLimit(1)
                            if data.clientNote(forStudentID: s.studentID ?? "")?.hasFlags == true {
                                ClientNoteFlag(size: 10)
                            }
                            Spacer(minLength: 0)
                            StatusBadge(status: s.status)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(FlowSpacing.md)
        .floweCard()
        .sheet(item: $selectedStudent) { s in
            StudentProfileView(studentID: s.studentID ?? "", studentName: s.studentName,
                               onMessage: {
                                   let id = s.studentID ?? ""
                                   selectedStudent = nil
                                   router.openConversation(with: Counterpart(id: id, name: s.studentName,
                                                                             photo: data.studentPhoto(forOwnerID: id)))
                               },
                               onClose: { selectedStudent = nil })
        }
    }
}

// MARK: - Empty state (rest day)

struct CalendarEmptyState: View {
    var body: some View {
        VStack(spacing: FlowSpacing.sm) {
            Image(systemName: "leaf")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.flowePinkSoft)
            Text("No sessions")
                .font(FloweFont.serif(17, .regular, italic: true))
                .foregroundStyle(Color.floweInk)
            Text("A quiet day to rest and restore.")
                .font(FloweFont.sans(12))
                .foregroundStyle(Color.floweMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, FlowSpacing.xxl)
        .floweCard()
    }
}

// MARK: - Booking request card (Accept / Decline)

/// A pending request with student, when, and two actions. Accepting or declining publishes the
/// instructor's decision to the shared database, which is how the student learns the outcome.
/// On decision the card collapses to a resolved confirmation line.
struct BookingRequestCard: View {
    @Environment(MockDataStore.self) private var data
    @Environment(InstructorRouter.self) private var router
    @Environment(\.locale) private var locale
    @State private var showStudent = false

    let request: Booking

    var body: some View {
        VStack(alignment: .leading, spacing: FlowSpacing.md) {
            HStack(spacing: FlowSpacing.md) {
                Button {
                    if request.studentID != nil { showStudent = true }
                } label: {
                    HStack(spacing: FlowSpacing.md) {
                        AvatarView(id: "", photo: data.studentPhoto(forOwnerID: request.studentID ?? ""), size: 44)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                ({ () -> Text in
                                    let n = data.displayIdentity(ownerID: request.studentID, fallbackName: request.studentName).name
                                    return n.isEmpty ? Text("A student") : Text(n)   // literal localizes; real name verbatim
                                }())
                                    .font(FloweFont.serif(16, .medium))
                                    .foregroundStyle(Color.floweInk)
                                    .lineLimit(1)
                                if data.clientNote(forStudentID: request.studentID ?? "")?.hasFlags == true {
                                    ClientNoteFlag()
                                }
                            }
                            (Text(localizedTag: request.type) + Text(" · ") + Text("\(request.durationMinutes) min"))
                                .textCase(.uppercase)
                                .font(FloweFont.mono(10))
                                .foregroundStyle(Color.floweMuted)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer(minLength: FlowSpacing.sm)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(request.localizedDate(locale))
                        .font(FloweFont.mono(11))
                        .foregroundStyle(Color.flowePinkDeep)
                    Text(request.localizedTime(locale))
                        .font(FloweFont.mono(10))
                        .foregroundStyle(Color.floweMuted)
                }
            }

            switch request.status {
            case .pending:
                // A weekly request is approved/ended ONCE for the whole series; a one-off answers just
                // itself. Declining a series ENDS it (all future weeks) — it's the instructor's "no".
                HStack(spacing: FlowSpacing.sm) {
                    Button {
                        Haptic.tap()
                        withAnimation(FloweMotion.spring) {
                            data.respond(to: request, confirmed: false)
                        }
                    } label: {
                        Text("Decline")
                            .font(FloweFont.sans(13, .medium))
                            .foregroundStyle(Color.flowePinkDeep)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.flowePink.opacity(0.4), lineWidth: 1)
                            )
                    }
                    .flowePressable()
                    .accessibilityIdentifier("request.decline")

                    Button {
                        Haptic.success()
                        withAnimation(FloweMotion.spring) {
                            data.respond(to: request, confirmed: true)
                        }
                    } label: {
                        Text("Accept")
                            .font(FloweFont.sans(13, .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(FlowGradients.gradDark)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .flowePressable()
                    .accessibilityIdentifier("request.accept")
                }
            case .cancelled:
                resolvedRow(icon: "xmark.circle.fill", text: "Declined", tint: .floweCancel)
            default:
                resolvedRow(icon: "checkmark.circle.fill", text: "Accepted", tint: .floweSuccess)
            }
        }
        .padding(FlowSpacing.lg)
        .floweCard()
        .sheet(isPresented: $showStudent) {
            StudentProfileView(studentID: request.studentID ?? "", studentName: request.studentName,
                               onMessage: {
                                   showStudent = false
                                   let id = request.studentID ?? ""
                                   router.openConversation(with: Counterpart(id: id, name: request.studentName,
                                                                             photo: data.studentPhoto(forOwnerID: id)))
                               },
                               onClose: { showStudent = false })
        }
    }

    private func resolvedRow(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(tint)
            Text(localizedTag: text)
                .font(FloweFont.sans(13, .medium))
                .foregroundStyle(tint)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
