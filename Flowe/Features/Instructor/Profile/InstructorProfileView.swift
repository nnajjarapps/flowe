import SwiftUI

/// The instructor's own profile: an identity header over a segmented control
/// with four tabs — Overview, Analytics, Reviews, Earnings. Not present in the
/// Figma mockup; designed here in the shared pink design system.
///
/// Reads `data.instructors[0]` for a name/photo/rating and `data.posts` for
/// review content. All other numbers are local mock data.
struct InstructorProfileView: View {

    typealias Tab = InstructorRouter.ProfileTab

    @Environment(MockDataStore.self) private var data
    @Environment(AppSession.self) private var session
    @Environment(InstructorRouter.self) private var router
    @Environment(AppSettings.self) private var settings

    @State private var showSettings = false
    @State private var showEditProfile = false
    @State private var showNotifications = false
    @State private var showAppSettings = false

    /// The signed-in instructor is represented by the first mock instructor.
    private var me: Instructor? { data.instructors.first }

    /// Up to three student reviews drawn from the community feed.
    private var reviews: [FeedPost] {
        Array(data.posts.filter { $0.type == .review }.prefix(3))
    }

    var body: some View {
        @Bindable var router = router
        ScrollView {
            VStack(spacing: 0) {
                header

                Picker("", selection: $router.profileTab) {
                    ForEach(Tab.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)

                Group {
                    switch router.profileTab {
                    case .overview:  overviewTab
                    case .analytics: analyticsTab
                    case .reviews:   reviewsTab
                    case .earnings:  earningsTab
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .background(Color.flowWhite.ignoresSafeArea())
        .confirmationDialog("Account", isPresented: $showSettings, titleVisibility: .visible) {
            Button("Edit profile") { showEditProfile = true }
            Button("Settings") { showAppSettings = true }
            Button("Notifications") { showNotifications = true }
            Button("Log out", role: .destructive) { session.logout() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showEditProfile) { EditProfileView() }
        .sheet(isPresented: $showNotifications) { NotificationSettingsView() }
        .sheet(isPresented: $showAppSettings) { SettingsView() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top) {
                Spacer()
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

            AvatarView(id: me?.img ?? "", size: 88, ring: true)

            VStack(spacing: 6) {
                Text(me?.name ?? "Elena Rossi")
                    .font(FloweFont.serif(24))
                    .foregroundStyle(Color.floweInk)

                Text(me?.cert.uppercased() ?? "CERTIFIED INSTRUCTOR")
                    .font(FloweFont.mono(10))
                    .foregroundStyle(Color.floweMuted)

                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.floweMuted)
                    Text(me?.city ?? "Brooklyn, NY")
                        .font(FloweFont.sans(12))
                        .foregroundStyle(Color.floweMuted)

                    Text("·")
                        .foregroundStyle(Color.floweMuted)

                    StarRatingView(rating: me?.rating ?? 4.9, size: 11)
                    Text("(\(me?.reviews ?? 0))")
                        .font(FloweFont.mono(10))
                        .foregroundStyle(Color.floweMuted)
                }
            }

            if let specialties = me?.specialties, !specialties.isEmpty {
                FlowChipRow(items: specialties)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.floweBorder).frame(height: 1)
        }
    }

    // MARK: - Overview

    private var overviewTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(text: "ABOUT")
                Text(me?.bio ?? InstructorProfileMock.fallbackBio)
                    .font(FloweFont.sans(14))
                    .foregroundStyle(Color.floweInk.opacity(0.85))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                StatTile(value: "\(me?.students ?? 128)", label: "STUDENTS")
                StatTile(value: "\(me?.yearsExp ?? 7)", label: "YEARS", accent: .flowePink)
                StatTile(value: "\(InstructorProfileMock.totalSessions)", label: "SESSIONS", accent: .floweSuccess)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(text: "OFFERS")
                FlowChipRow(items: me?.sessionTypes ?? ["Private", "Duet", "Online"])
            }
        }
    }

    // MARK: - Analytics

    private var analyticsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(text: "SESSIONS PER MONTH")

            VStack(alignment: .leading, spacing: 14) {
                InstructorBarChart(bars: InstructorProfileMock.sessionBars, showValues: true)

                Divider().overlay(Color.floweBorder)

                HStack {
                    metric(value: "\(InstructorProfileMock.totalSessions)", label: "Total this year")
                    Spacer()
                    metric(value: "+18%", label: "vs. last quarter", accent: .floweSuccess)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .floweCard(cornerRadius: 16)

            HStack(spacing: 12) {
                StatTile(value: "92%", label: "REBOOK", accent: .flowePinkDeep)
                StatTile(value: "4.9", label: "AVG RATING", accent: .flowePink)
                StatTile(value: "12", label: "THIS WEEK", accent: .floweSuccess)
            }
        }
    }

    // MARK: - Reviews

    private var reviewsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(text: "STUDENT REVIEWS")
                Spacer()
                StarRatingView(rating: me?.rating ?? 4.9, size: 12)
            }

            if reviews.isEmpty {
                Text("No reviews yet.")
                    .font(FloweFont.sans(13))
                    .foregroundStyle(Color.floweMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ForEach(reviews) { post in
                    ReviewRow(post: post)
                }
            }
        }
    }

    // MARK: - Earnings

    private var earningsTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(text: "EARNINGS PER MONTH")

            VStack(alignment: .leading, spacing: 14) {
                InstructorBarChart(
                    bars: InstructorProfileMock.earningBars,
                    showValues: true,
                    valueFormat: { settings.money($0) }
                )

                Divider().overlay(Color.floweBorder)

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.money(InstructorProfileMock.totalEarnings))
                            .font(FloweFont.serif(28, .medium))
                            .foregroundStyle(Color.floweSuccess)
                        Text("EARNED THIS YEAR")
                            .font(FloweFont.mono(10))
                            .foregroundStyle(Color.floweMuted)
                    }
                    Spacer()
                    metric(value: settings.money(540), label: "Pending payout")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .floweCard(cornerRadius: 16)

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(text: "RECENT PAYOUTS")
                payoutList
            }
        }
    }

    private var payoutList: some View {
        VStack(spacing: 0) {
            ForEach(Array(InstructorProfileMock.payouts.enumerated()), id: \.offset) { index, payout in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(payout.date)
                            .font(FloweFont.sans(14, .medium))
                            .foregroundStyle(Color.floweInk)
                        Text(payout.method.uppercased())
                            .font(FloweFont.mono(9))
                            .foregroundStyle(Color.floweMuted)
                    }
                    Spacer()
                    Text(settings.money(payout.amount))
                        .font(FloweFont.serif(16, .medium))
                        .foregroundStyle(Color.floweSuccess)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.flowWhite)
                .overlay(alignment: .top) {
                    if index > 0 {
                        Rectangle().fill(Color.floweBorder).frame(height: 1)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16).stroke(Color.floweBorder, lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private func metric(value: String, label: String, accent: Color = .floweInk) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(FloweFont.serif(18, .medium))
                .foregroundStyle(accent)
            Text(label)
                .font(FloweFont.sans(11))
                .foregroundStyle(Color.floweMuted)
        }
    }
}

// MARK: - Wrapping chip row (self-sizing rows of specialty pills)

/// A small flow-layout of `SpecialtyTag`s that wraps onto multiple rows.
private struct FlowChipRow: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(items, id: \.self) { SpecialtyTag(text: $0) }
        }
    }
}

// MARK: - Local mock data (profile-only)

private enum InstructorProfileMock {
    struct Payout {
        let date: String
        let method: String
        let amount: Int
    }

    static let totalSessions = 486
    static let totalEarnings = 24_180

    static let fallbackBio =
        "I teach classical and contemporary Pilates with a focus on breath, alignment, and slow, deliberate control. Every session is tailored — whether you're rehabbing, building strength, or just craving forty-five minutes that feel like your own."

    static let sessionBars: [InstructorBarChart.Bar] = [
        .init(label: "FEB", value: 34),
        .init(label: "MAR", value: 41),
        .init(label: "APR", value: 38),
        .init(label: "MAY", value: 52),
        .init(label: "JUN", value: 47),
        .init(label: "JUL", value: 44)
    ]

    static let earningBars: [InstructorBarChart.Bar] = [
        .init(label: "FEB", value: 2720),
        .init(label: "MAR", value: 3280),
        .init(label: "APR", value: 3040),
        .init(label: "MAY", value: 4160),
        .init(label: "JUN", value: 3760),
        .init(label: "JUL", value: 3520)
    ]

    static let payouts: [Payout] = [
        Payout(date: "Jul 15, 2026", method: "Direct deposit", amount: 1_840),
        Payout(date: "Jul 1, 2026",  method: "Direct deposit", amount: 1_680),
        Payout(date: "Jun 15, 2026", method: "Direct deposit", amount: 2_040)
    ]
}

#Preview {
    InstructorProfileView()
        .environment(MockDataStore.preview)
        .environment(AppSettings())
        .environment(AppSession())
        .environment(InstructorRouter())
}
