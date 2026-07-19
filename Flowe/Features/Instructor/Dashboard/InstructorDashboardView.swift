import SwiftUI

// MARK: - Dashboard

struct InstructorDashboardView: View {
    @Environment(MockDataStore.self) private var data
    @Environment(AppSession.self) private var session
    @Environment(InstructorRouter.self) private var router
    @Environment(AppSettings.self) private var settings

    @State private var showAvailability = false
    @State private var showEditProfile = false

    /// Real bookings for the signed-in instructor's own listing. Empty until students book.
    private var todaysSessions: [Booking] {
        guard let id = data.currentInstructor?.legacyId else { return [] }
        return data.bookings.filter { $0.instructorId == id }
    }

    private var instructorName: String {
        data.currentInstructor?.firstName
            ?? session.currentUser?.fullName.split(separator: " ").first.map(String.init)
            ?? "there"
    }

    /// This week's earnings from real sessions, priced at the instructor's rate.
    private var weekEarnings: Int {
        let price = data.currentInstructor?.price ?? 0
        return todaysSessions.count * price
    }

    private var ratingDisplay: String {
        guard let rating = data.currentInstructor?.rating, rating > 0 else { return "—" }
        return String(format: "%.1f", rating)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FlowSpacing.xl) {
                header
                kpiRow

                VStack(alignment: .leading, spacing: FlowSpacing.md) {
                    SectionHeader(text: "TODAY'S SCHEDULE")
                    if todaysSessions.isEmpty {
                        EmptyStateView(
                            icon: "calendar",
                            title: "No sessions today",
                            message: "When students book you, their sessions will show up here."
                        )
                    } else {
                        ForEach(todaysSessions) { booking in
                            SessionRow(booking: booking)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: FlowSpacing.md) {
                    SectionHeader(text: "QUICK ACTIONS")
                    QuickActionsGrid(onTap: handle)
                }
            }
            .padding(.horizontal, FlowSpacing.xl)
            .padding(.top, FlowSpacing.sm)
            .padding(.bottom, FlowSpacing.xxxl)
        }
        .background(Color.flowWhite.ignoresSafeArea())
        .sheet(isPresented: $showAvailability) { AvailabilityView() }
        .sheet(isPresented: $showEditProfile) { EditProfileView() }
    }

    private func handle(_ action: QuickAction) {
        switch action.kind {
        case .availability: showAvailability = true
        case .messages:     router.openMessages()
        case .earnings:     router.openEarnings()
        case .editProfile:  showEditProfile = true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: FlowSpacing.xs) {
                Text("GOOD MORNING")
                    .font(FloweFont.mono(11))
                    .foregroundStyle(Color.floweMuted)

                (
                    Text("Your ")
                        .font(FloweFont.serif(30, .light))
                    + Text("studio.")
                        .font(FloweFont.serif(30, .regular, italic: true))
                )
                .foregroundStyle(Color.floweInk)
            }

            Spacer()

            AvatarView(id: data.currentInstructor?.img ?? "", size: 46, ring: true)
        }
    }

    // MARK: KPI row

    private var kpiRow: some View {
        HStack(spacing: FlowSpacing.md) {
            StatTile(value: "\(todaysSessions.count)", label: "TODAY")
            StatTile(value: settings.money(weekEarnings), label: "THIS WEEK", accent: .floweSuccess)
            StatTile(value: ratingDisplay, label: "RATING", accent: .flowePink)
        }
    }
}

#Preview {
    InstructorDashboardView()
        .environment(MockDataStore.preview)
        .environment(AppSettings())
        .environment(AppSession())
        .environment(InstructorRouter())
}
