import SwiftUI

// MARK: - Dashboard

struct InstructorDashboardView: View {
    @Environment(MockDataStore.self) private var data
    @Environment(AppSession.self) private var session
    @Environment(InstructorRouter.self) private var router
    @Environment(AppSettings.self) private var settings
    @Environment(SubscriptionService.self) private var subscription

    @State private var showAvailability = false
    @State private var showEditProfile = false
    @State private var showPaywall = false

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

                if !subscription.isVisible {
                    visibilityBanner
                }

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
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }

    /// Promo shown until the instructor subscribes — they're hidden from the feed until they do.
    private var visibilityBanner: some View {
        Button { showPaywall = true } label: {
            HStack(spacing: FlowSpacing.md) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get discovered")
                        .font(FloweFont.serif(17))
                        .foregroundStyle(.white)
                    Text("You're hidden from students. Start your free month.")
                        .font(FloweFont.sans(12))
                        .foregroundStyle(.white.opacity(0.9))
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.9))
            }
            .padding(FlowSpacing.lg)
            .background(FlowGradients.gradDark)
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
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
        .environment(SubscriptionService())
        .environment(AppSettings())
        .environment(AppSession())
        .environment(InstructorRouter())
}
