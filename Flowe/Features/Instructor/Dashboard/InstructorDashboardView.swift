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
    @State private var showStudioWizard = false
    @State private var showComposeEvent = false
    @State private var showShield = false
    @State private var showCoveragePicker = false
    @State private var showCoverageInbox = false
    @State private var selectedEvent: CommunityEvent?
    @State private var selectedOpportunity: Opportunity?
    @State private var manageOpportunity: Opportunity?
    @State private var showComposeOpportunity = false
    @State private var showPackages = false
    @State private var showFinance = false
    @State private var showStudents = false
    @State private var showLibrary = false

    /// The No-Show Shield card surfaces only when there's something to act on — a session to judge,
    /// a fee to reconcile, or a risky upcoming booking worth a nudge.
    private var shieldSignal: Bool {
        !data.sessionsAwaitingAttendance.isEmpty || data.totalOwed > 0
            || data.incomingBookings.contains { data.isRisky($0) }
    }

    private var shieldSubtitle: String {
        var parts: [String] = []
        let awaiting = data.sessionsAwaitingAttendance.count
        if awaiting > 0 { parts.append(String(localized: "\(awaiting) to review")) }
        if data.totalOwed > 0 { parts.append(String(localized: "\(settings.money(data.totalOwed)) owed")) }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        // Nothing to act on → say whether protection is actually ON, or prompt setup.
        return data.hasActiveCancellationPolicy
            ? String(localized: "Cancellation protection is on")
            : String(localized: "Tap to protect against no-shows")
    }

    /// The OWNER coverage card surfaces once someone has claimed a session this instructor handed off —
    /// there's a winner to pick. (Requesting cover itself happens in Out of Studio; nothing to act on
    /// until a claim lands.)
    private var ownerCoverageSignal: Bool { !data.myClaims.isEmpty }

    private var ownerCoverageSubtitle: String {
        let n = data.myClaims.count
        return n == 1 ? String(localized: "1 instructor can cover — pick one") : String(localized: "\(n) instructors can cover — pick one")
    }

    /// The REPLACER inbox surfaces when there's an inbound offer to claim, or cover pay still owed for
    /// one already taught.
    private var coverInboxSignal: Bool { !data.myOffers.isEmpty || data.totalCoverOwed > 0 }

    private var coverInboxSubtitle: String {
        var parts: [String] = []
        let offers = data.myOffers.count
        if offers > 0 { parts.append(offers == 1 ? String(localized: "1 to claim") : String(localized: "\(offers) to claim")) }
        if data.totalCoverOwed > 0 { parts.append(String(localized: "\(settings.money(data.totalCoverOwed)) owed")) }
        return parts.isEmpty ? String(localized: "Cover for nearby instructors") : parts.joined(separator: " · ")
    }

    /// Accepted sessions scheduled for today — not the whole book of business. Pending requests
    /// live in their own section; declined and cancelled ones drop off entirely.
    private var todaysSessions: [Booking] {
        data.incomingBookings.filter {
            $0.status != .cancelled && $0.status != .pending
                && $0.date == FloweWeek.todayBookingDate
        }
    }

    /// Requests still awaiting an accept/decline. De-duped so a standing weekly series is ONE card.
    private var pendingRequests: [Booking] {
        data.pendingRequestCards
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
    /// Monday–Sunday week, summing each booked lesson type's own price. Was previously *every*
    /// outstanding confirmed session with no date scope — which duplicated the profile's PROJECTED tile
    /// and made the "THIS WEEK" label wrong. Payment is collected directly from the student, so this is
    /// a projection, not a balance.
    private var weekEarnings: Int {
        let now = Date()
        return data.incomingBookings.filter { booking in
            guard booking.status == .confirmed || booking.status == .completed,
                  let end = booking.sessionEnd(now: now) else { return false }
            return FloweWeek.isInCurrentWeek(end, now: now)
        }.reduce(0) { $0 + data.sessionEarning(for: $1) }
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

                // Always present, not signal-gated: a new instructor needs to DISCOVER the shield and
                // learn how to turn it on — hiding it until a fee is already owed is why it read as
                // "unclear how to use". The subtitle carries the state (action items / on / not set up).
                shieldCard

                packagesCard

                financeCard

                // Your client book — folded here from its former tab (the iPhone tab bar holds only 5),
                // so the roster stays one tap away.
                studentsCard

                libraryCard

                if ownerCoverageSignal {
                    ownerCoverageCard
                }

                if coverInboxSignal {
                    coverInboxCard
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
                        // A group/duet class shows as ONE row with a fullness count, not N duplicate rows.
                        ForEach(data.sessionGroups(todaysSessions)) { group in
                            if group.isGroup {
                                SessionRow(booking: group.primary,
                                           rosterCount: group.bookings.count, capacity: group.capacity)
                            } else {
                                // Render every booking in a non-group slot, not just the first — else a
                                // second session sharing the slot key silently vanishes from Today.
                                ForEach(group.bookings) { SessionRow(booking: $0) }
                            }
                        }
                    }
                }

                // Flowe Pro career marketplace (Phase 3). Cold-start liquidity surface: browse open
                // gigs to pick up, and post + manage your own. See [[FlowePro]].
                if !data.myOpportunities.isEmpty {
                    VStack(alignment: .leading, spacing: FlowSpacing.md) {
                        SectionHeader(text: "YOUR OPPORTUNITIES")
                        ForEach(data.myOpportunities) { opp in
                            Button { manageOpportunity = opp } label: {
                                OpportunityCard(opportunity: opp)
                            }
                            .buttonStyle(.plain)
                            .flowePressable()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: FlowSpacing.md) {
                    HStack {
                        SectionHeader(text: "OPPORTUNITIES")
                        Spacer()
                        Button {
                            // Recruiting is the paid half of the Flowe Pro marketplace: posting an
                            // opportunity is a premium **Boost** perk (applying is always free). A
                            // non-Boost instructor meets the paywall instead of the composer. Existing
                            // posts stay manageable after a lapse — creation is gated, management isn't,
                            // matching the events flow below. See [[FlowePro]] / [[Paywall]].
                            if subscription.isBoosted { showComposeOpportunity = true } else { showPaywall = true }
                        } label: {
                            HStack(spacing: 6) {
                                Label("Post", systemImage: "plus")
                                    .font(FloweFont.sans(13, .medium))
                                    .foregroundStyle(Color.flowePinkDeep)
                                // Signals that Post is a Boost feature, so the paywall isn't a jolt.
                                if !subscription.isBoosted {
                                    Text("BOOST")
                                        .font(FloweFont.mono(8))
                                        .foregroundStyle(Color.flowePinkDeep)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.flowePink.opacity(0.14), in: Capsule())
                                }
                            }
                        }
                        .accessibilityIdentifier("dashboard.postOpportunity")
                    }
                    if data.openOpportunities.isEmpty {
                        Text("No open opportunities nearby yet — post one to find a sub or grow your team.")
                            .font(FloweFont.sans(13))
                            .foregroundStyle(Color.floweMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(data.openOpportunities) { opp in
                            Button { selectedOpportunity = opp } label: {
                                OpportunityCard(opportunity: opp)
                            }
                            .buttonStyle(.plain)
                            .flowePressable()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: FlowSpacing.md) {
                    SectionHeader(text: "QUICK ACTIONS")
                    QuickActionsGrid(
                        onTap: handle,
                        showSetupStudio: StudioSetupState(data: data, subscription: subscription).incompleteCoreSteps
                    )
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
        .task { await data.syncBookings(asInstructor: true) }
        .task { await data.syncEvents(asOrganizer: true) }
        .task { await data.syncCoverage(asInstructor: true) }
        .task { await data.syncOpportunities() }
        .task { await data.syncOfferings() }
        // Manual pull-to-refresh, restored alongside the on-appear .task + foreground re-sync: on a
        // serverless CloudKit app there's no live socket, so a swipe-down is the one instant way to
        // pull just-landed requests / event responses / coverage claims. Mirrors the .task syncs.
        .refreshable {
            await data.syncBookings(asInstructor: true, recoverSession: true)
            await data.syncEvents(asOrganizer: true)
            await data.syncCoverage(asInstructor: true)
            await data.syncOpportunities()
            await data.syncOfferings()
        }
        .fullScreenCover(isPresented: $showStudioWizard) { StudioSetupWizard() }
        .sheet(isPresented: $showAvailability) { AvailabilityView() }
        .sheet(isPresented: $showEditProfile) { EditProfileView() }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .sheet(isPresented: $showComposeEvent) { ComposeEventSheet() }
        .sheet(isPresented: $showShield) { NavigationStack { NoShowShieldView() } }
        .sheet(isPresented: $showPackages) { PackagesManagerView() }
        .sheet(isPresented: $showFinance) { FinanceCenterView() }
        .sheet(isPresented: $showStudents) { StudentsListView() }
        .sheet(isPresented: $showLibrary) { LibraryManagerView() }
        .sheet(isPresented: $showCoveragePicker) { CoveragePickerView() }
        .sheet(isPresented: $showCoverageInbox) { CoverageInboxView() }
        .sheet(item: $selectedEvent) { event in
            // The instructor manages their own events from here — the one context that may edit /
            // cancel / delete. Everywhere else (the student Community browse) leaves this false.
            EventDetailView(event: event, manageable: true)
        }
        .sheet(item: $selectedOpportunity) { OpportunityDetailView(opportunity: $0) }
        .sheet(item: $manageOpportunity) { OpportunityDetailView(opportunity: $0, manageable: true) }
        .sheet(isPresented: $showComposeOpportunity) { ComposeOpportunitySheet() }
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
        .flowePressable()
        .accessibilityIdentifier("dashboard.noShowShield")
    }

    /// Class-packages entry — always present (a new instructor needs to discover it), with the pending
    /// purchase-request count as a badge. Cloned from `shieldCard`.
    private var financeCard: some View {
        Button { showFinance = true } label: {
            HStack(spacing: FlowSpacing.md) {
                Image(systemName: "chart.pie.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.flowePinkDeep)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finance center")
                        .font(FloweFont.serif(16))
                        .foregroundStyle(Color.floweInk)
                    Text("Revenue, packages & fees")
                        .font(FloweFont.sans(12))
                        .foregroundStyle(Color.floweMuted)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Color.floweMuted)
            }
            .padding(16)
            .background(Color.floweCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.floweBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .flowePressable()
    }

    private var packagesCard: some View {
        Button { showPackages = true } label: {
            HStack(spacing: FlowSpacing.md) {
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.flowePinkDeep)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Class packages")
                        .font(FloweFont.serif(16))
                        .foregroundStyle(Color.floweInk)
                    Text(packagesSubtitle)
                        .font(FloweFont.sans(12))
                        .foregroundStyle(Color.floweMuted)
                }
                Spacer()
                if data.pendingPurchaseCards.count > 0 {
                    Text(verbatim: "\(data.pendingPurchaseCards.count)")
                        .font(FloweFont.mono(12)).foregroundStyle(.white)
                        .frame(minWidth: 20).padding(5)
                        .background(Color.flowePinkDeep).clipShape(Capsule())
                }
                Image(systemName: "chevron.right").foregroundStyle(Color.floweMuted)
            }
            .padding(FlowSpacing.lg)
            .floweCard(cornerRadius: 18)
        }
        .flowePressable()
        .accessibilityIdentifier("dashboard.packages")
    }

    private var packagesSubtitle: LocalizedStringKey {
        let pending = data.pendingPurchaseCards.count
        if pending > 0 { return "^[\(pending) request](inflect: true) to review" }
        if !data.myOfferings.isEmpty { return "^[\(data.myOfferings.count) package](inflect: true) on offer" }
        return "Sell prepaid class packages"
    }

    /// Flowe Education entry — the instructor's video training library. Cloned from `packagesCard`;
    /// opens `LibraryManagerView` (which brings its own NavigationStack).
    private var libraryCard: some View {
        Button { showLibrary = true } label: {
            HStack(spacing: FlowSpacing.md) {
                Image(systemName: "play.rectangle.on.rectangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.flowePinkDeep)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Education")
                        .font(FloweFont.serif(16))
                        .foregroundStyle(Color.floweInk)
                    Text(librarySubtitle)
                        .font(FloweFont.sans(12))
                        .foregroundStyle(Color.floweMuted)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Color.floweMuted)
            }
            .padding(FlowSpacing.lg)
            .floweCard(cornerRadius: 18)
        }
        .flowePressable()
        .accessibilityIdentifier("dashboard.library")
    }

    private var librarySubtitle: LocalizedStringKey {
        let count = data.currentInstructor.map { data.ownedPrograms(for: $0).count } ?? 0
        if count > 0 { return "^[\(count) program](inflect: true) in your library" }
        return "Share a video training library"
    }

    /// Client book entry — folded here from its former tab so the instructor shell stays at 5 tabs.
    /// Cloned from `packagesCard`; opens the full `StudentsListView` (which brings its own NavigationStack).
    private var studentsCard: some View {
        Button { showStudents = true } label: {
            HStack(spacing: FlowSpacing.md) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.flowePinkDeep)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Students")
                        .font(FloweFont.serif(16))
                        .foregroundStyle(Color.floweInk)
                    Text(studentsSubtitle)
                        .font(FloweFont.sans(12))
                        .foregroundStyle(Color.floweMuted)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Color.floweMuted)
            }
            .padding(FlowSpacing.lg)
            .floweCard(cornerRadius: 18)
        }
        .flowePressable()
        .accessibilityIdentifier("dashboard.students")
    }

    private var studentsSubtitle: LocalizedStringKey {
        let count = data.instructorStudents.count
        if count > 0 { return "^[\(count) student](inflect: true) in your book" }
        return "Your client book"
    }

    /// Out-of-Studio OWNER entry — a session this instructor handed off has been claimed and needs a
    /// winner picked. Cloned from `shieldCard`.
    private var ownerCoverageCard: some View {
        Button { showCoveragePicker = true } label: {
            HStack(spacing: FlowSpacing.md) {
                Image(systemName: "airplane.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.flowePinkDeep)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Coverage")
                        .font(FloweFont.serif(16))
                        .foregroundStyle(Color.floweInk)
                    Text(ownerCoverageSubtitle)
                        .font(FloweFont.sans(12))
                        .foregroundStyle(Color.floweMuted)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Color.floweMuted)
            }
            .padding(FlowSpacing.lg)
            .floweCard(cornerRadius: 18)
        }
        .flowePressable()
        .accessibilityIdentifier("dashboard.coverageOwner")
    }

    /// Out-of-Studio REPLACER entry — sessions nearby to claim, plus 50% cover pay owed. Cloned from
    /// `shieldCard`.
    private var coverInboxCard: some View {
        Button { showCoverageInbox = true } label: {
            HStack(spacing: FlowSpacing.md) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.flowePinkDeep)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cover for others")
                        .font(FloweFont.serif(16))
                        .foregroundStyle(Color.floweInk)
                    Text(coverInboxSubtitle)
                        .font(FloweFont.sans(12))
                        .foregroundStyle(Color.floweMuted)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Color.floweMuted)
            }
            .padding(FlowSpacing.lg)
            .floweCard(cornerRadius: 18)
        }
        .flowePressable()
        .accessibilityIdentifier("dashboard.coverInbox")
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
        .flowePressable()
        .accessibilityIdentifier("dashboard.getDiscovered")
    }

    private func handle(_ action: QuickAction) {
        switch action.kind {
        case .setupStudio:  showStudioWizard = true
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

            ActivityBellButton(isInstructor: true)

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
                .contentTransition(.numericText())
                .animation(FloweMotion.spring, value: todaysSessions.count)
                .floweAppear(0)
            StatTile(value: settings.money(weekEarnings), label: "THIS WEEK", accent: .floweSuccess)
                .contentTransition(.numericText())
                .animation(FloweMotion.spring, value: weekEarnings)
                .floweAppear(1)
            StatTile(value: ratingDisplay, label: "RATING", accent: .flowePink)
                .contentTransition(.numericText())
                .animation(FloweMotion.spring, value: ratingDisplay)
                .floweAppear(2)
        }
    }
}
