import SwiftUI

/// The instructor's weekly calendar: a header, a Week/Month toggle, a pageable week strip of
/// selectable day pills (or a month overview grid), the selected day's session list, and a section
/// of pending booking requests with Accept / Decline actions.
struct InstructorCalendarView: View {
    @Environment(MockDataStore.self) private var data

    /// The selected day, identified by its ABSOLUTE offset from today (today = 0). Defaults to today
    /// and is clamped back into a visible day whenever the week page or view mode changes.
    @State private var selectedDay = 0
    /// Which forward week the strip is showing (0 = this week … `FloweWeek.maxWeekOffset`).
    @State private var weekOffset = 0
    /// Which month the overview grid is showing, in months from the current month.
    @State private var monthOffset = 0
    @State private var viewMode: CalendarViewMode = .week

    /// Accepted sessions on the selected day.
    private var daySessions: [Booking] {
        sessions(on: selectedDay).filter { $0.status != .pending && $0.status != .cancelled }
    }

    /// Sessions on a day, identified by its absolute offset-from-today id. The date is derived
    /// straight from the id (start of today + id days) rather than searched in the visible `week`
    /// array — a month-selected day can be off the current page, so an array lookup would return nil
    /// and blank the list. Matched on the **full** stored `Booking.date` string (not the weekday
    /// prefix, which pulled in other weeks' same weekday), agreeing with the Dashboard.
    private func sessions(on dayID: Int) -> [Booking] {
        let start = Calendar.current.startOfDay(for: Date())
        guard let date = Calendar.current.date(byAdding: .day, value: dayID, to: start) else { return [] }
        let dateString = FloweWeek.bookingDateString(for: date)
        return data.incomingBookings.filter { $0.date == dateString }
    }

    /// The currently paged week, in the device calendar/time zone.
    private var week: [WeekDay] { FloweWeek.week(offset: weekOffset) }

    /// Requests still awaiting a decision, across the whole horizon (the inbox is never page-scoped).
    /// De-duped so a 12-week standing series shows as ONE card, not 12.
    private var requests: [Booking] {
        data.pendingRequestCards
    }

    private var pendingCount: Int { requests.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FlowSpacing.xl) {
                header
                if viewMode == .week {
                    weekPager
                    weekStrip
                } else {
                    MonthGrid(
                        monthOffset: monthOffset,
                        selectedDay: selectedDay,
                        sessionCount: { date in
                            data.incomingBookings.filter { $0.date == FloweWeek.bookingDateString(for: date) }.count
                        },
                        isClosed: { data.currentInstructor?.isClosedOverride(onDate: $0) ?? false },
                        onPrev: { withAnimation { monthOffset -= 1 } },
                        onNext: { withAnimation { monthOffset += 1 } },
                        onSelect: { id in Haptic.selection(); withAnimation(FloweMotion.pop) { selectedDay = id } }
                    )
                }
                daySection
                requestSection
            }
            .padding(.horizontal, FlowSpacing.xl)
            .padding(.top, FlowSpacing.sm)
            .padding(.bottom, FlowSpacing.xxxl)
        }
        .background(Color.flowWhite.ignoresSafeArea())
        .task { await data.syncBookings(asInstructor: true) }
        // Manual pull-to-refresh for the request inbox — pulls just-sent booking requests instantly.
        .refreshable { await data.syncBookings(asInstructor: true, recoverSession: true) }
        .onChange(of: weekOffset) { _, newOffset in
            // Keep a visible day selected: if the selected day is off the new page, snap to its first day.
            if selectedDay < newOffset * 7 || selectedDay > newOffset * 7 + 6 {
                selectedDay = newOffset * 7
            }
        }
        .onChange(of: viewMode) { _, mode in
            // Switching to the week strip: pull an out-of-range month selection back to a visible day.
            if mode == .week, selectedDay < weekOffset * 7 || selectedDay > weekOffset * 7 + 6 {
                selectedDay = weekOffset * 7
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: FlowSpacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: FlowSpacing.xs) {
                    // The week-range kicker only reads right in Week mode; the Month grid carries its own
                    // "July 2026" title, so showing a week range above it is confusing. Hide it in Month.
                    if viewMode == .week {
                        Text(FloweWeek.rangeLabel(offset: weekOffset).uppercased())
                            .font(FloweFont.mono(11))
                            .foregroundStyle(Color.floweMuted)
                    }

                    (
                        Text("Your ")
                            .font(FloweFont.serif(30, .light))
                        + Text(viewMode == .week ? "week." : "month.")
                            .font(FloweFont.serif(30, .regular, italic: true))
                    )
                    .foregroundStyle(Color.floweInk)
                }

                Spacer()

                AvatarView(id: data.currentInstructor?.img ?? "", photo: data.currentInstructor?.photo, size: 46, ring: true)
            }

            modeToggle
        }
    }

    /// Week / Month segmented toggle.
    private var modeToggle: some View {
        HStack(spacing: 0) {
            modeButton("Week", mode: .week)
            modeButton("Month", mode: .month)
        }
        .padding(3)
        .background(Color.floweCardBg, in: Capsule())
        .overlay(Capsule().stroke(Color.floweBorder, lineWidth: 1))
    }

    private func modeButton(_ title: LocalizedStringKey, mode: CalendarViewMode) -> some View {
        Button {
            Haptic.selection()
            withAnimation(FloweMotion.pop) { viewMode = mode }
        } label: {
            Text(title)
                .font(FloweFont.sans(13, .medium))
                .foregroundStyle(viewMode == mode ? .white : Color.floweMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background {
                    if viewMode == mode {
                        Capsule().fill(FlowGradients.gradDark)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: Week pager (prev / next)

    private var weekPager: some View {
        HStack {
            Button { withAnimation { weekOffset -= 1 } } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(weekOffset == 0 ? Color.floweMuted.opacity(0.4) : Color.flowePinkDeep)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .disabled(weekOffset == 0)
            .accessibilityLabel("Previous week")

            Spacer()

            Text(FloweWeek.rangeLabel(offset: weekOffset))
                .font(FloweFont.mono(12))
                .foregroundStyle(Color.floweInk)

            Spacer()

            Button { withAnimation { weekOffset += 1 } } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(weekOffset == FloweWeek.maxWeekOffset ? Color.floweMuted.opacity(0.4) : Color.flowePinkDeep)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .disabled(weekOffset == FloweWeek.maxWeekOffset)
            .accessibilityLabel("Next week")
        }
    }

    // MARK: Week strip

    private var weekStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: FlowSpacing.sm) {
                ForEach(week) { day in
                    WeekDayPill(
                        day: day,
                        isSelected: day.id == selectedDay,
                        hasSessions: !sessions(on: day.id).isEmpty,
                        isClosed: data.currentInstructor?.isClosedOverride(onDate: day.date) ?? false
                    ) {
                        Haptic.selection()
                        withAnimation(FloweMotion.pop) { selectedDay = day.id }
                    }
                }
            }
            .padding(.horizontal, 1)
        }
    }

    // MARK: Selected day sessions

    private var daySection: some View {
        VStack(alignment: .leading, spacing: FlowSpacing.md) {
            HStack {
                SectionHeader(text: "SCHEDULE")
                Spacer()
                Text(sessionCountLabel)
                    .font(FloweFont.mono(10))
                    .foregroundStyle(Color.flowePinkDeep)
            }

            if daySessions.isEmpty {
                CalendarEmptyState()
            } else {
                // Group/duet slots (capacity >= 2) render as ONE roster card; 1-on-1s as today's card.
                ForEach(data.sessionGroups(daySessions)) { group in
                    if group.isGroup {
                        CalendarGroupSessionCard(sessions: group.bookings, capacity: group.capacity)
                    } else {
                        // Not a group (capacity < 2, or uncached). Render EVERY booking in the slot, not
                        // just the first — collapsing to `primary` would silently drop a second session
                        // sharing the slot key (e.g. two bookings on a slot while the lock is undeployed).
                        ForEach(group.bookings) { CalendarSessionCard(session: $0) }
                    }
                }
            }
        }
    }

    private var sessionCountLabel: String {
        let count = daySessions.count
        return count == 1 ? String(localized: "1 SESSION") : String(localized: "\(count) SESSIONS")
    }

    // MARK: Booking requests

    private var requestSection: some View {
        VStack(alignment: .leading, spacing: FlowSpacing.md) {
            HStack(spacing: FlowSpacing.sm) {
                SectionHeader(text: "BOOKING REQUESTS")
                if pendingCount > 0 {
                    Text("\(pendingCount)")
                        .font(FloweFont.mono(10))
                        .foregroundStyle(.white)
                        .frame(minWidth: 18)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(FlowGradients.gradDark))
                }
                Spacer()
            }

            if requests.isEmpty {
                EmptyStateView(
                    icon: "tray",
                    title: "No booking requests",
                    message: "New requests from students will appear here."
                )
            } else {
                ForEach(requests) { request in
                    BookingRequestCard(request: request)
                }
            }
        }
    }
}
