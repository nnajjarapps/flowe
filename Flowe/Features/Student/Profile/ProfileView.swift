import SwiftUI

/// Student profile: identity header, progress achievements, weekly practice
/// chart, and an account settings list. Ported from `ProfileScreen` in App.tsx.
struct ProfileView: View {
    @Environment(AppSession.self) private var session
    @Environment(MockDataStore.self) private var data

    @State private var showSettings = false
    @State private var showNotifications = false

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

    /// Distinct instructors this user has booked with.
    private var distinctInstructorCount: Int {
        Set(data.bookings.map(\.instructorId)).count
    }

    /// Progress tiles computed entirely from real bookings.
    private var achievements: [Achievement] {
        [
            Achievement(systemIcon: "checkmark.seal.fill", label: "\(data.completedCount) sessions",          sub: "Completed"),
            Achievement(systemIcon: "person.2.fill",       label: "\(distinctInstructorCount) instructors",   sub: "Worked with"),
            Achievement(systemIcon: "clock.fill",          label: "\(data.hoursDisplay) hrs",                 sub: "Practiced"),
        ]
    }

    /// Minutes practiced per weekday, summed from real bookings' durations.
    private var weekBars: [WeeklyBar] {
        let weekdays: [(prefix: String, letter: String)] = [
            ("Mon", "M"), ("Tue", "T"), ("Wed", "W"), ("Thu", "T"),
            ("Fri", "F"), ("Sat", "S"), ("Sun", "S"),
        ]
        return weekdays.map { day in
            let minutes = data.bookings
                .filter { $0.date.hasPrefix(day.prefix) }
                .reduce(0) { $0 + (Int($1.duration.filter(\.isNumber)) ?? 0) }
            return WeeklyBar(day: day.letter, minutes: minutes)
        }
    }

    private var weekMinutes: Int { weekBars.reduce(0) { $0 + $1.minutes } }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header

                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(text: "YOUR PROGRESS")
                        .padding(.bottom, 12)

                    if data.bookings.isEmpty {
                        EmptyStateView(
                            icon: "sparkles",
                            title: "No sessions yet",
                            message: "Book your first class and your progress will show up here."
                        )
                        .padding(.bottom, 20)
                    } else {
                        achievementsGrid
                            .padding(.bottom, 20)

                        SectionHeader(text: "THIS WEEK")
                            .padding(.bottom, 10)

                        weekCard
                            .padding(.bottom, 20)
                    }

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
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            // No photo on file yet → empty id renders the gradient placeholder.
            AvatarView(id: "", size: 64)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.currentUser?.fullName ?? "Your Profile")
                    .font(FloweFont.serif(19))
                    .foregroundStyle(Color.floweInk)
                if let memberSinceText {
                    Text(memberSinceText)
                        .font(FloweFont.sans(12))
                        .foregroundStyle(Color.floweMuted)
                }
                HStack(spacing: 4) {
                    disciplinePill(roleLabel, background: Color.flowePink.opacity(0.09))
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
                    default: showSettings = true
                    }
                } label: {
                    HStack {
                        Text(row)
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

#Preview {
    ProfileView()
        .environment(MockDataStore.preview)
        .environment(AppSettings())
        .environment(AppSession())
}
