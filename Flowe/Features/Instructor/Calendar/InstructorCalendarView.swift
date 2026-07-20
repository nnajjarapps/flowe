import SwiftUI

/// The instructor's weekly calendar: a header, a scrollable week strip of
/// selectable day pills, the selected day's session list, and a section of
/// pending booking requests with Accept / Decline actions.
struct InstructorCalendarView: View {
    @Environment(MockDataStore.self) private var data

    @State private var selectedDay = 0

    /// Accepted sessions on the selected weekday. `Booking.date` reads "Thu, Jul 24", so the
    /// weekday prefix is what matches it to a strip day.
    private var daySessions: [Booking] {
        sessions(on: selectedDay).filter { $0.status != .pending && $0.status != .cancelled }
    }

    private func sessions(on dayIndex: Int) -> [Booking] {
        guard let weekday = WeekDay.all.first(where: { $0.id == dayIndex })?.weekday else { return [] }
        return data.incomingBookings.filter { $0.date.hasPrefix(weekday) }
    }

    /// Requests still awaiting a decision, across the whole week.
    private var requests: [Booking] {
        data.incomingBookings.filter { $0.status == .pending }
    }

    private var pendingCount: Int { requests.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FlowSpacing.xl) {
                header
                weekStrip
                daySection
                requestSection
            }
            .padding(.horizontal, FlowSpacing.xl)
            .padding(.top, FlowSpacing.sm)
            .padding(.bottom, FlowSpacing.xxxl)
        }
        .background(Color.flowWhite.ignoresSafeArea())
        .refreshable { await data.syncBookings(asInstructor: true) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: FlowSpacing.xs) {
                Text("JUL 7 – JUL 13")
                    .font(FloweFont.mono(11))
                    .foregroundStyle(Color.floweMuted)

                (
                    Text("Your ")
                        .font(FloweFont.serif(30, .light))
                    + Text("week.")
                        .font(FloweFont.serif(30, .regular, italic: true))
                )
                .foregroundStyle(Color.floweInk)
            }

            Spacer()

            AvatarView(id: data.currentInstructor?.img ?? "", size: 46, ring: true)
        }
    }

    // MARK: Week strip

    private var weekStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: FlowSpacing.sm) {
                ForEach(WeekDay.all) { day in
                    WeekDayPill(
                        day: day,
                        isSelected: day.id == selectedDay,
                        hasSessions: !sessions(on: day.id).isEmpty
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) { selectedDay = day.id }
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
                ForEach(daySessions) { item in
                    CalendarSessionCard(session: item)
                }
            }
        }
    }

    private var sessionCountLabel: String {
        let count = daySessions.count
        return count == 1 ? "1 SESSION" : "\(count) SESSIONS"
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

#Preview {
    InstructorCalendarView()
        .environment(MockDataStore.preview)
        .environment(AppSettings())
}
