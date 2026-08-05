import SwiftUI

/// Student profile: identity header, progress achievements, weekly practice
/// chart, and an account settings list. Ported from `ProfileScreen` in App.tsx.
struct ProfileView: View {
    @Environment(AppSession.self) private var session
    @Environment(MockDataStore.self) private var data

    @State private var showSettings = false
    @State private var showNotifications = false
    @State private var showEditProfile = false
    @State private var showOpportunities = false
    @State private var legalDoc: LegalDoc?
    /// A tapped teacher in the "Your Teachers" rail → opens their profile to rebook (same destination
    /// as a booking card's "Book again"). `Instructor` is Identifiable, so `.sheet(item:)` drives it.
    @State private var rebookTeacher: Instructor?

    /// Per-icon accent tints matching the Figma mockup (deep → pink → soft).
    private let achievementTints: [Color] = [.flowePinkDeep, .flowePink, .flowePinkSoft]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    // MARK: - Derived from real data

    /// "Member since <Month Year>" from the signed-in user's join date.
    private var memberSinceText: String? {
        guard let date = session.currentUser?.memberSince else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return "Member since \(formatter.string(from: date))"
    }

    /// The user's role, shown as a single pill (no hardcoded disciplines).
    private var roleLabel: String {
        (session.currentUser?.role ?? .student).rawValue.capitalized
    }

    /// Distinct instructors this user has booked with — counted by the reliable `instructorOwnerID`
    /// (legacy `instructorId` is 0 for any uncached instructor, which collapsed them into one bucket).
    private var distinctInstructorCount: Int {
        Set(data.myBookings.compactMap(\.instructorOwnerID)).count
    }

    /// Progress tiles computed entirely from real bookings.
    private var achievements: [Achievement] {
        [
            Achievement(systemIcon: "checkmark.seal.fill", label: String(localized: "\(data.completedCount) sessions"),        sub: String(localized: "Completed")),
            Achievement(systemIcon: "person.2.fill",       label: String(localized: "\(distinctInstructorCount) instructors"), sub: String(localized: "Worked with")),
            Achievement(systemIcon: "clock.fill",          label: String(localized: "\(data.hoursDisplay) hrs"),               sub: String(localized: "Practiced")),
        ]
    }

    /// Minutes practiced per weekday **this week**, from sessions that actually happened.
    ///
    /// Was previously matched by weekday name alone (`date.hasPrefix("Mon")`), which counted every
    /// Monday session ever, of any status — so the chart inflated for every returning user. Now each
    /// bar is a specific date in the current Monday–Sunday week, and only a non-cancelled session
    /// whose reconstructed end time has actually passed counts as "practiced".
    private var weekBars: [WeeklyBar] {
        let now = Date()
        let calendar = Calendar.current
        let letters = ["M", "T", "W", "T", "F", "S", "S"]
        let practiced = data.myBookings.filter { $0.status == .completed || $0.status == .confirmed }
        return FloweWeek.mondayWeekDays(now: now, calendar: calendar).enumerated().map { index, dayDate in
            let minutes = practiced.reduce(0) { total, booking in
                guard let end = booking.sessionEnd(now: now), end <= now,
                      calendar.isDate(end, inSameDayAs: dayDate) else { return total }
                return total + (Int(booking.duration.filter(\.isNumber)) ?? 0)
            }
            return WeeklyBar(day: letters[index], minutes: minutes)
        }
    }

    private var weekMinutes: Int { weekBars.reduce(0) { $0 + $1.minutes } }

    // MARK: - Practice spine (streak · milestones · next session)

    /// Completed sessions — the same set the "N sessions · Completed" tile counts, so the streak,
    /// milestone and that tile never disagree. (A just-finished session becomes `.completed` on the next
    /// sync via `applyCompletions`.)
    private var practicedSessions: [Booking] {
        data.myBookings.filter { $0.status == .completed }
    }

    private var practicedCount: Int { practicedSessions.count }

    /// Monday 00:00 of the week containing `date`, forced to a Monday start (locale-independent) so it
    /// agrees with `FloweWeek.mondayWeekDays` used by the chart.
    private func mondayStart(_ date: Date, _ cal: Calendar) -> Date {
        let weekday = cal.component(.weekday, from: date)      // 1=Sun … 7=Sat
        let daysFromMonday = (weekday + 5) % 7                 // Mon→0 … Sun→6
        return cal.date(byAdding: .day, value: -daysFromMonday, to: cal.startOfDay(for: date)) ?? date
    }

    private enum StreakState { case none; case active(Int); case atRisk(Int) }

    /// WEEKLY streak: consecutive Mon–Sun weeks with ≥1 practiced session. `.active` when THIS week
    /// already has one, `.atRisk` when it doesn't yet but last week did (alive, but needs a session this
    /// week), `.none` when neither this nor last week has one. Weekly — not daily — because that matches
    /// how people actually practice Pilates and rides on the standing weekly-booking backbone.
    private var streakState: StreakState {
        let now = Date(); let cal = Calendar.current
        let weeks = Set(practicedSessions.compactMap { $0.sessionEnd(now: now) }.map { mondayStart($0, cal) })
        guard !weeks.isEmpty else { return .none }
        let thisWeek = mondayStart(now, cal)
        let lastWeek = cal.date(byAdding: .weekOfYear, value: -1, to: thisWeek) ?? thisWeek
        let hasThisWeek = weeks.contains(thisWeek)
        guard let anchor = hasThisWeek ? thisWeek : (weeks.contains(lastWeek) ? lastWeek : nil) else { return .none }
        var count = 0; var w = anchor
        while weeks.contains(w) {
            count += 1
            w = cal.date(byAdding: .weekOfYear, value: -1, to: w) ?? w
        }
        return hasThisWeek ? .active(count) : .atRisk(count)
    }

    /// Session-count milestones. `nextMilestone` is nil once every threshold is passed.
    private let milestones = [1, 5, 10, 25, 50, 100]
    private var nextMilestone: Int? { milestones.first { $0 > practicedCount } }

    /// Soonest upcoming session (already sorted soonest-first by the store).
    private var nextSession: Booking? { data.upcomingBookings.first }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header

                VStack(alignment: .leading, spacing: 0) {
                    if data.myBookings.isEmpty {
                        SectionHeader(text: "YOUR PROGRESS")
                            .padding(.bottom, 12)

                        EmptyStateView(
                            icon: "sparkles",
                            title: "No sessions yet",
                            message: "Book your first class and your progress will show up here."
                        )
                        .padding(.bottom, 20)
                    } else {
                        // The practice spine: streak + milestone + next session — the reason to open
                        // the app between sessions. All derived from real bookings; no new data.
                        practiceHero
                            .padding(.bottom, 20)

                        // One-tap rebook: the faces you already practice with, so returning to a trusted
                        // instructor is a tap from the profile instead of a hunt through Discover.
                        yourTeachersSection

                        SectionHeader(text: "YOUR PROGRESS")
                            .padding(.bottom, 12)

                        achievementsGrid
                            .padding(.bottom, 20)

                        SectionHeader(text: "THIS WEEK")
                            .padding(.bottom, 10)

                        weekCard
                            .padding(.bottom, 20)
                    }

                    // Wishlist — the instructors you saved to come back to. Shows even before any
                    // booking (a browse-first student), so it lives outside the bookings branch.
                    savedSection

                    // The student-facing career surface (Flowe Pro): browse open apprentice/assistant/
                    // studio roles and track applications. Shown to every student — it's an on-ramp, not
                    // gated on any prior activity.
                    SectionHeader(text: "OPPORTUNITIES")
                        .padding(.bottom, 10)
                    opportunitiesCard
                        .padding(.bottom, 20)

                    SectionHeader(text: "ACCOUNT")
                        .padding(.bottom, 10)

                    accountList
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }
        }
        .background(Color.flowWhite)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showNotifications) { NotificationSettingsView() }
        .sheet(isPresented: $showEditProfile) { EditStudentProfileView() }
        .sheet(isPresented: $showOpportunities) { StudentOpportunitiesView() }
        .sheet(item: $legalDoc) { LegalDocumentView(resource: $0.resource, title: $0.title) }
        // Rebook destination — the instructor's full bookable profile, same as a booking card's
        // "Book again" (BookingCard deliberately opens the profile, not the sheet, so the student
        // picks the slot/time).
        .sheet(item: $rebookTeacher) { teacher in
            StudentInstructorProfileView(instructor: teacher) { rebookTeacher = nil }
        }
    }

    // MARK: - Your Teachers (one-tap rebook rail)

    @ViewBuilder private var yourTeachersSection: some View {
        let teachers = data.bookedInstructors
        if !teachers.isEmpty {
            SectionHeader(text: "YOUR TEACHERS")
                .padding(.bottom, 10)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(teachers) { teacher in
                        Button {
                            Haptic.tap()
                            rebookTeacher = teacher
                        } label: {
                            VStack(spacing: 6) {
                                AvatarView(id: teacher.img, photo: teacher.photo, size: 60, ring: true)
                                Text(teacher.name)
                                    .font(FloweFont.sans(11, .medium))
                                    .foregroundStyle(Color.floweInk)
                                    .lineLimit(1)
                                    .frame(maxWidth: 68)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Book again with \(teacher.name)")
                        .accessibilityHint("Opens their profile to book a session")
                    }
                }
                .padding(.horizontal, 1)
                .padding(.bottom, 2)
            }
            .padding(.bottom, 20)
        }
    }

    // MARK: - Opportunities (Flowe Pro student career surface)

    /// A single tappable card into the opportunity browse. Adapts its copy to whether the student has
    /// applications in flight, so a returning applicant sees their pipeline at a glance.
    private var opportunitiesCard: some View {
        let appliedCount = data.myAppliedOpportunities.count
        return Button {
            Haptic.tap()
            showOpportunities = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "briefcase.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.flowePinkDeep)
                    .frame(width: 44, height: 44)
                    .background(Color.flowePink.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(appliedCount > 0 ? "Your applications" : "Browse opportunities")
                        .font(FloweFont.sans(15, .medium))
                        .foregroundStyle(Color.floweInk)
                    Text(appliedCount > 0
                         ? String(localized: "\(appliedCount) in progress")
                         : String(localized: "Apprenticeships, assistant & studio roles"))
                        .font(FloweFont.sans(12))
                        .foregroundStyle(Color.floweMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.floweMuted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .floweCard(cornerRadius: 16)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("student.opportunities")
    }

    // MARK: - Saved (local wishlist rail)

    @ViewBuilder private var savedSection: some View {
        let saved = data.savedInstructors
        if !saved.isEmpty {
            SectionHeader(text: "SAVED")
                .padding(.bottom, 10)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(saved) { instructor in
                        Button {
                            Haptic.tap()
                            rebookTeacher = instructor
                        } label: {
                            VStack(spacing: 6) {
                                AvatarView(id: instructor.img, photo: instructor.photo, size: 60, ring: true)
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: "heart.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color.flowePinkDeep)
                                            .padding(4)
                                            .background(Color.flowWhite, in: Circle())
                                            .offset(x: 2, y: -2)
                                    }
                                Text(instructor.name)
                                    .font(FloweFont.sans(11, .medium))
                                    .foregroundStyle(Color.floweInk)
                                    .lineLimit(1)
                                    .frame(maxWidth: 68)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Saved instructor \(instructor.name)")
                        .accessibilityHint("Opens their profile")
                    }
                }
                .padding(.horizontal, 1)
                .padding(.top, 4)
                .padding(.bottom, 2)
            }
            .padding(.bottom, 20)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            // The student's uploaded photo, if any; an empty id falls back to the gradient placeholder.
            AvatarView(id: "", photo: session.currentUser?.photo, size: 64)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.currentUser?.fullName ?? "Your Profile")
                    .font(FloweFont.serif(19))
                    .foregroundStyle(Color.floweInk)
                if let memberSinceText {
                    Text(memberSinceText)
                        .font(FloweFont.sans(12))
                        .foregroundStyle(Color.floweMuted)
                }
                if let bio = session.currentUser?.bio, !bio.isEmpty {
                    Text(bio)
                        .font(FloweFont.sans(12))
                        .foregroundStyle(Color.floweInk.opacity(0.8))
                        .lineLimit(2)
                        .padding(.top, 2)
                }
                HStack(spacing: 6) {
                    disciplinePill(roleLabel, background: Color.flowePink.opacity(0.09))
                    Button {
                        showEditProfile = true
                    } label: {
                        Text("Edit Profile")
                            .font(FloweFont.sans(11, .medium))
                            .foregroundStyle(Color.flowePinkDeep)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(Color.flowePink.opacity(0.10), in: Capsule())
                    }
                    .accessibilityIdentifier("student.editProfile")
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.floweInk)
                    .frame(width: 32, height: 32)
                    .background(Color.floweCardBg)
                    .overlay(Circle().stroke(Color.floweBorder, lineWidth: 1))
                    .clipShape(Circle())
            }
            .accessibilityIdentifier("student.settings")
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.floweBorder)
                .frame(height: 1)
        }
    }

    private func disciplinePill(_ text: String, background: Color) -> some View {
        Text(text)
            .font(FloweFont.mono(10))
            .foregroundStyle(Color.flowePinkDeep)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(background)
            .clipShape(Capsule())
    }

    // MARK: - Achievements

    private var achievementsGrid: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(achievements.enumerated()), id: \.element.id) { index, achievement in
                VStack(spacing: 6) {
                    Image(systemName: achievement.systemIcon)
                        .font(.system(size: 16))
                        .foregroundStyle(achievementTints[index % achievementTints.count])
                        .padding(.bottom, 2)
                    Text(achievement.label)
                        .font(FloweFont.sans(12, .medium))
                        .foregroundStyle(Color.floweInk)
                        .multilineTextAlignment(.center)
                        .lineSpacing(1)
                    Text(achievement.sub)
                        .font(FloweFont.mono(10))
                        .foregroundStyle(Color.floweMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .floweCard(cornerRadius: 16)
            }
        }
    }

    // MARK: - Practice hero (streak · milestone · next session)

    private var practiceHero: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("YOUR PRACTICE")
                .font(FloweFont.mono(10))
                .foregroundStyle(.white.opacity(0.75))

            streakRow

            if let next = nextMilestone {
                milestoneBar(next: next)
            } else {
                Text("🏆 \(practicedCount) sessions — you're a legend.")
                    .font(FloweFont.sans(12, .medium))
                    .foregroundStyle(.white)
            }

            nextSessionChip
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FlowGradients.gradDark, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder private var streakRow: some View {
        switch streakState {
        case .active(let n):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("🔥").font(.system(size: 30))
                    (Text("\(n)").font(FloweFont.serif(38)) + Text(" week streak").font(FloweFont.serif(18)))
                        .foregroundStyle(.white)
                }
                Text(n == 1 ? "First week down — keep it going." : "\(n) weeks in a row. Don't break the chain.")
                    .font(FloweFont.sans(12)).foregroundStyle(.white.opacity(0.85))
            }
        case .atRisk(let n):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("🔥").font(.system(size: 30)).opacity(0.55)
                    (Text("\(n)").font(FloweFont.serif(38)) + Text(" week streak").font(FloweFont.serif(18)))
                        .foregroundStyle(.white)
                }
                Text("Practice this week to keep your \(n)-week streak alive.")
                    .font(FloweFont.sans(12)).foregroundStyle(.white.opacity(0.9))
            }
        case .none:
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("✨").font(.system(size: 26))
                    Text("Start your streak").font(FloweFont.serif(24)).foregroundStyle(.white)
                }
                Text("Complete a session this week to begin your practice.")
                    .font(FloweFont.sans(12)).foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    private func milestoneBar(next: Int) -> some View {
        let prev = milestones.last { $0 <= practicedCount } ?? 0
        let span = max(next - prev, 1)
        let progress = min(max(Double(practicedCount - prev) / Double(span), 0), 1)
        let remaining = next - practicedCount
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white).frame(width: max(6, geo.size.width * progress))
                }
            }
            .frame(height: 6)
            Text("\(remaining) \(remaining == 1 ? "session" : "sessions") to your \(next)-session milestone")
                .font(FloweFont.mono(10)).foregroundStyle(.white.opacity(0.8))
        }
    }

    @ViewBuilder private var nextSessionChip: some View {
        if let next = nextSession {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .font(.system(size: 13)).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 1) {
                    Text("NEXT SESSION").font(FloweFont.mono(9)).foregroundStyle(.white.opacity(0.7))
                    Text([next.date, next.time].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(FloweFont.sans(13, .medium)).foregroundStyle(.white)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
        } else {
            HStack {
                Image(systemName: "sparkles").font(.system(size: 13)).foregroundStyle(.white.opacity(0.9))
                Text("Book your next session to keep the momentum.")
                    .font(FloweFont.sans(12)).foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - This week

    private var weekCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if weekMinutes > 0 {
                WeeklyBarChart(bars: weekBars)

                (
                    Text("\(weekMinutes) min").font(FloweFont.sans(11, .medium)).foregroundColor(Color.floweInk)
                    + Text(" practiced this week").font(FloweFont.sans(11)).foregroundColor(Color.floweMuted)
                )
            } else {
                Text("No practice logged this week")
                    .font(FloweFont.sans(12))
                    .foregroundStyle(Color.floweMuted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floweCard(cornerRadius: 16)
    }

    // MARK: - Account list

    private var accountList: some View {
        VStack(spacing: 0) {
            ForEach(Array(ProfileMock.accountRows.enumerated()), id: \.offset) { index, row in
                let isLogout = row == "Log out"
                Button {
                    switch row {
                    case "Log out": session.logout()
                    case "Notifications": showNotifications = true
                    // Open the bundled documents directly rather than bouncing through Settings.
                    case "Privacy": legalDoc = .privacy
                    case "Help & Support": legalDoc = .support
                    default: showSettings = true
                    }
                } label: {
                    HStack {
                        Text(LocalizedStringKey(row))
                            .font(FloweFont.sans(14))
                            .foregroundStyle(isLogout ? Color.flowePinkDeep : Color.floweInk)
                        Spacer()
                        if !isLogout {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 15))
                                .foregroundStyle(Color.floweMuted)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.flowWhite)
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Rectangle()
                                .fill(Color.floweBorder)
                                .frame(height: 1)
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.floweBorder, lineWidth: 1)
        )
    }
}
