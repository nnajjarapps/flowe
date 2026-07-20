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

    /// Sessions students have booked with this instructor, newest first. Declined and cancelled
    /// requests drop off the schedule.
    private var todaysSessions: [Booking] {
        data.incomingBookings.filter { $0.status != .cancelled }
    }

    /// Requests still awaiting an accept/decline.
    private var pendingRequests: [Booking] {
        data.incomingBookings.filter { $0.status == .pending }
    }

    /// Instructor's first name, preferring the listing (which they can edit) and falling back to the
    /// signed-in account, then a neutral label if neither is set yet. Guards against empty strings —
    /// a blank listing name would otherwise slip past a plain `??`.
    private var instructorName: String {
        let listingName = data.currentInstructor?.firstName ?? ""
        if !listingName.isEmpty { return listingName }
        let accountFirst = session.currentUser?.fullName
            .split(separator: " ").first.map(String.init) ?? ""
        return accountFirst.isEmpty ? "there" : accountFirst
    }

    /// This week's earnings from accepted sessions, priced at the instructor's rate.
    /// Payment is collected directly from the student, so this is a projection, not a balance.
    private var weekEarnings: Int {
        let price = data.currentInstructor?.price ?? 0
        return data.incomingBookings.filter { $0.status == .confirmed }.count * price
    }

    private var ratingDisplay: String {
        // Derived from real reviews, like the profile — not the listing's cached number, which
        // isn't recomputed in previews and would disagree with the Reviews tab.
        guard let ownerID = data.currentUserID, let summary = data.rating(for: ownerID) else {
            return "—"
        }
        return String(format: "%.1f", summary.average)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FlowSpacing.xl) {
                header
                kpiRow

                if !subscription.isVisible {
                    visibilityBanner
                }

                if !pendingRequests.isEmpty {
                    VStack(alignment: .leading, spacing: FlowSpacing.md) {
                        SectionHeader(text: "REQUESTS")
                        ForEach(pendingRequests) { booking in
                            BookingRequestCard(request: booking)
                        }
                    }
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
        .refreshable { await data.syncBookings(asInstructor: true) }
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
        .accessibilityIdentifier("dashboard.getDiscovered")
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
                Text(LocalizedStringKey(greeting))
                    .font(FloweFont.mono(11))
                    .foregroundStyle(Color.floweMuted)

                (
                    Text("Hi ")
                        .font(FloweFont.serif(30, .light))
                    + Text("\(instructorName).")
                        .font(FloweFont.serif(30, .regular, italic: true))
                )
                .foregroundStyle(Color.floweInk)
            }

            Spacer()

            AvatarView(id: data.currentInstructor?.img ?? "", photo: data.currentInstructor?.photo, size: 46, ring: true)
        }
    }

    /// Time-of-day greeting, so the dashboard reads like it was opened just now.
    /// Uppercase to match the mono label style *and* the localization keys, so it translates.
    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12:  return "GOOD MORNING"
        case 12..<17: return "GOOD AFTERNOON"
        default:      return "GOOD EVENING"
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
