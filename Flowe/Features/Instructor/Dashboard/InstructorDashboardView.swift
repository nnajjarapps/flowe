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
    @State private var showComposeEvent = false
    @State private var showShield = false
    @State private var selectedEvent: CommunityEvent?

    /// The No-Show Shield card surfaces only when there's something to act on — a session to judge,
    /// a fee to reconcile, or a risky upcoming booking worth a nudge.
    private var shieldSignal: Bool {
        !data.sessionsAwaitingAttendance.isEmpty || data.totalOwed > 0
            || data.incomingBookings.contains { data.isRisky($0) }
    }

    private var shieldSubtitle: String {
        var parts: [String] = []
        let awaiting = data.sessionsAwaitingAttendance.count
        if awaiting > 0 { parts.append("\(awaiting) to review") }
        if data.totalOwed > 0 { parts.append("\(settings.money(data.totalOwed)) owed") }
        return parts.isEmpty ? "Cancellation protection" : parts.joined(separator: " · ")
    }

    /// Accepted sessions scheduled for today — not the whole book of business. Pending requests
    /// live in their own section; declined and cancelled ones drop off entirely.
    private var todaysSessions: [Booking] {
        data.incomingBookings.filter {
            $0.status != .cancelled && $0.status != .pending
                && $0.date == FloweWeek.todayBookingDate
        }
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

    /// This week's earnings: accepted or completed sessions whose date falls in the current
    /// Monday–Sunday week, priced at the instructor's rate. Was previously *every* outstanding
    /// confirmed session with no date scope — which duplicated the profile's PROJECTED tile and made
    /// the "THIS WEEK" label wrong. Payment is collected directly from the student, so this is a
    /// projection, not a balance.
    private var weekEarnings: Int {
        let price = data.currentInstructor?.price ?? 0
        let now = Date()
        let count = data.incomingBookings.filter { booking in
            guard booking.status == .confirmed || booking.status == .completed,
                  let end = booking.sessionEnd(now: now) else { return false }
            return FloweWeek.isInCurrentWeek(end, now: now)
        }.count
        return count * price
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

                if shieldSignal {
                    shieldCard
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

                // Omitted entirely when the organizer has no events — a "YOUR EVENTS" header over
                // nothing reads as broken.
                if !data.myEvents.isEmpty {
                    VStack(alignment: .leading, spacing: FlowSpacing.md) {
                        SectionHeader(text: "YOUR EVENTS")
                        ForEach(data.myEvents) { event in
                            EventCardView(event: event, style: .compact) { selectedEvent = event }
                        }
                    }
                }
            }
            .padding(.horizontal, FlowSpacing.xl)
            .padding(.top, FlowSpacing.sm)
            .padding(.bottom, FlowSpacing.xxxl)
        }
        .background(Color.flowWhite.ignoresSafeArea())
        .task { await data.syncEvents(asOrganizer: true) }
        .refreshable {
            await data.syncBookings(asInstructor: true)
            await data.syncEvents(asOrganizer: true)
        }
        .sheet(isPresented: $showAvailability) { AvailabilityView() }
        .sheet(isPresented: $showEditProfile) { EditProfileView() }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .sheet(isPresented: $showComposeEvent) { ComposeEventSheet() }
        .sheet(isPresented: $showShield) { NavigationStack { NoShowShieldView() } }
        .sheet(item: $selectedEvent) { event in
            // The instructor manages their own events from here — the one context that may edit /
            // cancel / delete. Everywhere else (the student Community browse) leaves this false.
            EventDetailView(event: event, manageable: true)
        }
    }

    /// No-Show Shield entry — sessions to judge, fees owed, or a risky booking to nudge.
    private var shieldCard: some View {
        Button { showShield = true } label: {
            HStack(spacing: FlowSpacing.md) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.flowePinkDeep)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No-Show Shield")
                        .font(FloweFont.serif(16))
                        .foregroundStyle(Color.floweInk)
                    Text(shieldSubtitle)
                        .font(FloweFont.sans(12))
                        .foregroundStyle(Color.floweMuted)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Color.floweMuted)
            }
            .padding(FlowSpacing.lg)
            .floweCard(cornerRadius: 18)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dashboard.noShowShield")
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
        // Hosting an event broadcasts to students. An instructor students can't even find in Discover
        // shouldn't broadcast, and that subscription is the only money Flowe takes — so an ineligible
        // organizer meets the paywall instead of the composer. (Deliberately *not* symmetric: a lapsed
        // organizer's existing events stay visible so a joined student never watches the class vanish.)
        case .createEvent:
            if subscription.isVisible { showComposeEvent = true } else { showPaywall = true }
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
