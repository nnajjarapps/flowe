import SwiftUI

/// The instructor's own profile: an identity header over a segmented control
/// with four tabs — Overview, Analytics, Reviews, Earnings. Not present in the
/// Figma mockup; designed here in the shared pink design system.
///
/// Reads the signed-in instructor's own listing (`data.currentInstructor`),
/// whose fields start empty until they set up their profile, and `data.posts`
/// for review content. Empty tabs fall back to tasteful empty states.
struct InstructorProfileView: View {

    typealias Tab = InstructorRouter.ProfileTab

    @Environment(MockDataStore.self) private var data
    @Environment(AppSession.self) private var session
    @Environment(InstructorRouter.self) private var router
    @Environment(AppSettings.self) private var settings

    @State private var showSettings = false
    @State private var showEditProfile = false

    /// The signed-in instructor's own (possibly-empty) listing.
    private var me: Instructor? { data.currentInstructor }

    /// Whether this instructor has any reviews to show yet.
    private var hasRating: Bool { (me?.reviews ?? 0) > 0 }

    /// Whether a city has been entered yet.
    private var hasCity: Bool { !(me?.city ?? "").isEmpty }

    /// Display name from signup, with a gentle fallback if somehow blank.
    private var displayName: String {
        let name = me?.name ?? ""
        return name.isEmpty ? "Your Profile" : name
    }

    /// Certification line, defaulting to a neutral label when not set.
    private var certLine: String {
        let cert = me?.cert ?? ""
        return cert.isEmpty ? "CERTIFIED INSTRUCTOR" : cert.uppercased()
    }

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
        .sheet(isPresented: $showSettings) { InstructorSettingsView() }
        .sheet(isPresented: $showEditProfile) { EditProfileView() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top) {
                Button {
                    showEditProfile = true
                } label: {
                    Text("Edit Profile")
                        .font(FloweFont.sans(13, .medium))
                        .foregroundStyle(Color.flowePinkDeep)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.flowePink.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("instructor.editProfile")

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
                .accessibilityIdentifier("instructor.settings")
            }

            EditableAvatarView(id: me?.img ?? "", photo: me?.photo, size: 88)

            VStack(spacing: 6) {
                Text(displayName)
                    .font(FloweFont.serif(24))
                    .foregroundStyle(Color.floweInk)

                Text(certLine)
                    .font(FloweFont.mono(10))
                    .foregroundStyle(Color.floweMuted)

                if hasCity || hasRating {
                    HStack(spacing: 6) {
                        if hasCity {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.floweMuted)
                            Text(me?.city ?? "")
                                .font(FloweFont.sans(12))
                                .foregroundStyle(Color.floweMuted)
                        }

                        if hasCity && hasRating {
                            Text("·")
                                .foregroundStyle(Color.floweMuted)
                        }

                        if hasRating {
                            StarRatingView(rating: me?.rating ?? 0, size: 11)
                            Text("(\(me?.reviews ?? 0))")
                                .font(FloweFont.mono(10))
                                .foregroundStyle(Color.floweMuted)
                        }
                    }
                }
            }

            if let specialties = me?.specialties, !specialties.isEmpty {
                FlowChipRow(items: specialties)
            }

            if !missingPieces.isEmpty { completenessCard }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.floweBorder).frame(height: 1)
        }
    }

    // MARK: - Profile completeness

    /// The listing fields a student actually judges an instructor on. A profile missing these gets
    /// booked less, so the gaps are surfaced rather than left for the instructor to notice.
    private var missingPieces: [String] {
        guard let me else { return [] }
        var missing: [String] = []
        if me.photo == nil && me.img.isEmpty { missing.append("photo") }
        if me.city.isEmpty { missing.append("city") }
        if (me.bio ?? "").isEmpty { missing.append("bio") }
        if me.cert.isEmpty { missing.append("certification") }
        if me.specialties.isEmpty { missing.append("specialties") }
        if me.price == 0 { missing.append("rate") }
        return missing
    }

    private var completenessCard: some View {
        Button {
            showEditProfile = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.flowePinkDeep)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Finish your profile")
                        .font(FloweFont.sans(13, .medium))
                        .foregroundStyle(Color.floweInk)
                    Text("Add your \(missingPieces.listed) so students can find you.")
                        .font(FloweFont.sans(12))
                        .foregroundStyle(Color.floweMuted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.floweMuted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .floweCard()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("instructor.completeness")
    }

    // MARK: - Overview

    private var overviewTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(text: "ABOUT")
                if let bio = me?.bio, !bio.isEmpty {
                    Text(bio)
                        .font(FloweFont.sans(14))
                        .foregroundStyle(Color.floweInk.opacity(0.85))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Add a bio in Edit Profile so students can get to know you.")
                        .font(FloweFont.sans(14))
                        .foregroundStyle(Color.floweMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 12) {
                StatTile(value: "\(me?.students ?? 0)", label: "STUDENTS")
                StatTile(value: "\(me?.yearsExp ?? 0)", label: "YEARS", accent: .flowePink)
                StatTile(value: "\(data.instructorCompletedCount)", label: "SESSIONS", accent: .floweSuccess)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(text: "SPECIALTIES")
                if let specialties = me?.specialties, !specialties.isEmpty {
                    FlowChipRow(items: specialties)
                } else {
                    Text("Add your specialties in Edit Profile.")
                        .font(FloweFont.sans(13))
                        .foregroundStyle(Color.floweMuted)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(text: "OFFERS")
                if let types = me?.sessionTypes, !types.isEmpty {
                    FlowChipRow(items: types)
                } else {
                    Text("Add the session types you offer in Edit Profile.")
                        .font(FloweFont.sans(13))
                        .foregroundStyle(Color.floweMuted)
                }
            }

            rateCard

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(text: "CERTIFICATION")
                if let cert = me?.cert, !cert.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "rosette")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.flowePinkDeep)
                        Text(cert)
                            .font(FloweFont.sans(14))
                            .foregroundStyle(Color.floweInk)
                    }
                } else {
                    Text("Add your certification in Edit Profile.")
                        .font(FloweFont.sans(13))
                        .foregroundStyle(Color.floweMuted)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(text: "AVAILABILITY")
                if let days = me?.available, !days.isEmpty {
                    FlowChipRow(items: days)
                } else {
                    Text("Set the days you teach in Settings › Availability.")
                        .font(FloweFont.sans(13))
                        .foregroundStyle(Color.floweMuted)
                }
            }
        }
    }

    /// The headline number a student compares instructors on.
    private var rateCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                SectionHeader(text: "RATE PER SESSION")
                Text(me.map { $0.price > 0 ? settings.money($0.price) : "Not set" } ?? "Not set")
                    .font(FloweFont.serif(22, .medium))
                    .foregroundStyle(me?.price ?? 0 > 0 ? Color.floweInk : Color.floweMuted)
            }
            Spacer()
            Image(systemName: "creditcard")
                .font(.system(size: 20))
                .foregroundStyle(Color.flowePinkSoft)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .floweCard()
    }

    // MARK: - Analytics

    private var analyticsTab: some View {
        EmptyStateView(
            icon: "chart.bar",
            title: "No analytics yet",
            message: "Your session trends and rebooking stats will appear here once you start teaching on Flowe."
        )
    }

    // MARK: - Reviews

    @ViewBuilder
    private var reviewsTab: some View {
        if reviews.isEmpty {
            EmptyStateView(
                icon: "star",
                title: "No reviews yet",
                message: "Reviews from your students will show up here after your sessions."
            )
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeader(text: "STUDENT REVIEWS")
                    Spacer()
                    if hasRating {
                        StarRatingView(rating: me?.rating ?? 0, size: 12)
                    }
                }

                ForEach(reviews) { post in
                    ReviewRow(post: post)
                }
            }
        }
    }

    // MARK: - Earnings

    private var earningsTab: some View {
        EmptyStateView(
            icon: "banknote",
            title: "No earnings yet",
            message: "Your monthly earnings and recent payouts will appear here after your first paid session."
        )
    }
}

private extension Array where Element == String {
    /// "photo, city and bio" — reads as a sentence in the completeness nudge.
    var listed: String {
        guard count > 1 else { return first ?? "" }
        return dropLast().joined(separator: ", ") + " and " + (last ?? "")
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

#Preview {
    InstructorProfileView()
        .environment(MockDataStore.preview)
        .environment(SubscriptionService())
        .environment(AppSettings())
        .environment(AppSession())
        .environment(InstructorRouter())
}
