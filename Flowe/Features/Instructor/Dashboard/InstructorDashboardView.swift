import SwiftUI

// MARK: - Local mock model (dashboard-only; students are drawn from data.instructors)

/// A scheduled teaching slot for the instructor's day.
/// `studentId` indexes into `data.instructors` for a name + avatar.
struct DashboardSession: Identifiable {
    let id: Int
    let studentId: Int
    let startTime: String
    let duration: String
    let type: String
    let status: BookingStatus

    static let sample: [DashboardSession] = [
        DashboardSession(id: 1, studentId: 2, startTime: "9:00",  duration: "55 MIN", type: "Private",  status: .confirmed),
        DashboardSession(id: 2, studentId: 3, startTime: "11:30", duration: "55 MIN", type: "Duet",     status: .confirmed),
        DashboardSession(id: 3, studentId: 6, startTime: "4:00",  duration: "45 MIN", type: "Online",   status: .pending)
    ]
}

// MARK: - Dashboard

struct InstructorDashboardView: View {
    @Environment(MockDataStore.self) private var data
    @Environment(AppSession.self) private var session
    @Environment(InstructorRouter.self) private var router
    @Environment(AppSettings.self) private var settings

    @State private var showAvailability = false
    @State private var showEditProfile = false

    private let sessions = DashboardSession.sample

    private var instructorName: String {
        session.currentUser?.fullName.split(separator: " ").first.map(String.init)
            ?? data.instructors.first?.firstName
            ?? "there"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FlowSpacing.xl) {
                header
                kpiRow

                VStack(alignment: .leading, spacing: FlowSpacing.md) {
                    SectionHeader(text: "TODAY'S SCHEDULE")
                    ForEach(sessions) { item in
                        SessionRow(session: item)
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

            AvatarView(id: data.instructors.first?.img ?? "", size: 46, ring: true)
        }
    }

    // MARK: KPI row

    private var kpiRow: some View {
        HStack(spacing: FlowSpacing.md) {
            StatTile(value: "\(sessions.count)", label: "TODAY")
            StatTile(value: settings.money(840), label: "THIS WEEK", accent: .floweSuccess)
            StatTile(value: "4.9", label: "RATING", accent: .flowePink)
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
