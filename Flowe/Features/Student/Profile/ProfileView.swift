import SwiftUI

/// Student profile: identity header, progress achievements, weekly practice
/// chart, and an account settings list. Ported from `ProfileScreen` in App.tsx.
struct ProfileView: View {
    @Environment(AppSession.self) private var session

    @State private var showSettings = false
    @State private var showNotifications = false

    /// Per-icon accent tints matching the Figma mockup (deep → pink → soft).
    private let achievementTints: [Color] = [.flowePinkDeep, .flowePink, .flowePinkSoft]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header

                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(text: "YOUR PROGRESS")
                        .padding(.bottom, 12)

                    achievementsGrid
                        .padding(.bottom, 20)

                    SectionHeader(text: "THIS WEEK")
                        .padding(.bottom, 10)

                    weekCard
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
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            AvatarView(id: "1531746020798-e6953c6e8e04", size: 64)

            VStack(alignment: .leading, spacing: 2) {
                Text("Mia Tanaka")
                    .font(FloweFont.serif(19))
                    .foregroundStyle(Color.floweInk)
                Text("Member since March 2026")
                    .font(FloweFont.sans(12))
                    .foregroundStyle(Color.floweMuted)
                HStack(spacing: 4) {
                    disciplinePill("Reformer", background: Color.flowePink.opacity(0.09))
                    disciplinePill("Mat", background: Color.flowePinkSoft.opacity(0.19))
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
            ForEach(Array(ProfileMock.achievements.enumerated()), id: \.element.id) { index, achievement in
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
            WeeklyBarChart()

            (
                Text("265 min").font(FloweFont.sans(11, .medium)).foregroundColor(Color.floweInk)
                + Text(" practiced this week").font(FloweFont.sans(11)).foregroundColor(Color.floweMuted)
            )
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
