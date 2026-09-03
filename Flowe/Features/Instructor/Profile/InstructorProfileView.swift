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
    @State private var showCertZoom = false

    /// The signed-in instructor's own (possibly-empty) listing.
    private var me: Instructor? { data.currentInstructor }

    /// Real reviews of this instructor, newest first — earned from completed bookings, not seeded.
    private var reviews: [Review] { data.myReviews }

    /// Peer recommendations of this instructor (Flowe Pro), newest first.
    private var recommendations: [InstructorRecommendation] { data.myRecommendations }

    /// Average rating and count, derived from those reviews. Nil until the first one lands, because
    /// "no reviews yet" is a different thing from a 0.0 rating.
    private var ratingSummary: (average: Double, count: Int)? {
        data.currentUserID.flatMap { data.rating(for: $0) }
    }

    private var hasRating: Bool { ratingSummary != nil }

    /// Whether a studio address has been entered yet.
    private var hasAddress: Bool { !(me?.address ?? "").isEmpty }

    /// Display name from signup, with a gentle fallback if somehow blank.
    private var displayName: String {
        let name = me?.name ?? ""
        return name.isEmpty ? "Your Profile" : name
    }

    /// Certification line. Falls back to a role-neutral label — NOT "Certified Instructor", which
    /// would assert a credential the instructor never entered. Real cert text takes over once set.
    private var certLine: String {
        let cert = me?.cert ?? ""
        return cert.isEmpty ? String(localized: "INSTRUCTOR") : cert.uppercased()
    }

    var body: some View {
        @Bindable var router = router
        ScrollView {
            VStack(spacing: 0) {
                coverBand
                header

                // Six tabs — a segmented picker truncates them, and worse under he/ar. The strip
                // scrolls instead. Horizontal padding lives INSIDE the strip so it can bleed to the
                // screen edge while its content still aligns with the rest of the column.
                FloweTabStrip(tabs: Tab.allCases, label: \.rawValue, selection: $router.profileTab)
                    .padding(.top, 16)
                    .padding(.bottom, 20)

                // Padding is per-tab, NOT on the Group: the posts tab is edge-to-edge because
                // `PostRowView` already insets itself and bleeds its photos.
                Group {
                    switch router.profileTab {
                    case .overview:  overviewTab.padding(.horizontal, 20)
                    case .posts:     ProfilePostsList()
                    case .events:    ProfileEventsList(scope: .organizing).padding(.horizontal, 20)
                    case .analytics: analyticsTab.padding(.horizontal, 20)
                    case .reviews:   reviewsTab.padding(.horizontal, 20)
                    case .earnings:  earningsTab.padding(.horizontal, 20)
                    }
                }
                .padding(.bottom, 32)
                .animation(FloweMotion.gentle, value: router.profileTab)
            }
        }
        .background(Color.flowWhite.ignoresSafeArea())
        .task {
            await data.syncReviews(asInstructor: true)
            // The owner's own device pulls its lesson types too, so a type authored on another device
            // (delivered via the private mirror, or re-fetched from the public store) shows here.
            if let me { await data.syncLessonTypes(for: me) }
            await data.syncMyRecommendations()
            // The activity section reads the community store, which nothing else on this screen
            // populates — without this it reads empty until the Community tab has been opened.
            await data.syncCommunity()
        }
        // Manual pull-to-refresh: pulls newly-posted reviews (no student→instructor push), lesson
        // types authored on another device, and peer recommendations. Mirrors the .task.
        .refreshable {
            await data.syncReviews(asInstructor: true)
            if let me { await data.syncLessonTypes(for: me) }
            await data.syncMyRecommendations()
            // The activity section reads the community store, which nothing else on this screen
            // populates — without this it reads empty until the Community tab has been opened.
            await data.syncCommunity()
        }
        .sheet(isPresented: $showSettings) { InstructorSettingsView() }
        .sheet(isPresented: $showEditProfile) { EditProfileView() }
    }

    // MARK: - Brand cover (Flowe Pro)

    /// The brand cover banner atop the instructor's own profile, only when set. A thin brand-color
    /// underline ties it to the accent. See [[FlowePro]].
    @ViewBuilder
    private var coverBand: some View {
        if let cover = me?.coverPhoto, let ui = UIImage(data: cover) {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
                .frame(height: 132)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color(hexString: me?.brandColor ?? "") ?? Color.flowePink)
                        .frame(height: 3)
                }
                .padding(.bottom, 8)
        }
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
                .flowePressable()
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
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("instructor.settings")
            }

            EditableAvatarView(id: me?.img ?? "", photo: me?.photo, size: 88)

            VStack(spacing: 6) {
                Text(displayName)
                    .font(FloweFont.serif(24))
                    .foregroundStyle(Color.floweInk)

                // Flowe Pro: the professional headline sits under the name (the LinkedIn-style tagline),
                // distinct from the bio. Only when set — see [[FlowePro]].
                if let headline = me?.headline, !headline.isEmpty {
                    Text(headline)
                        .font(FloweFont.sans(13, .medium))
                        // Flowe Pro brand kit: the headline takes the instructor's brand accent (falls
                        // back to the app pink when unset/invalid). See [[FlowePro]].
                        .foregroundStyle(Color(hexString: me?.brandColor ?? "") ?? Color.flowePinkDeep)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                }

                Text(certLine)
                    .font(FloweFont.mono(10))
                    .foregroundStyle(Color.floweMuted)

                if hasAddress || hasRating {
                    HStack(spacing: 6) {
                        if hasAddress {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.floweMuted)
                            Text(me?.address ?? "")
                                .font(FloweFont.sans(12))
                                .foregroundStyle(Color.floweMuted)
                        }

                        if hasAddress && hasRating {
                            Text("·")
                                .foregroundStyle(Color.floweMuted)
                        }

                        if let summary = ratingSummary {
                            StarRatingView(rating: summary.average, size: 11)
                            Text("(\(summary.count))")
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

    /// The listing fields a student actually judges an instructor on. Reads the SINGLE completion
    /// signal hoisted onto `Instructor` (`profileMissingPieces`), so this card and the Studio Setup
    /// wizard's step-1 gate share one definition rather than each computing their own.
    private var missingPieces: [String] {
        me?.profileMissingPieces ?? []
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
        .flowePressable()
        .accessibilityIdentifier("instructor.completeness")
    }

    // MARK: - Overview

    /// One work-history row: a pink timeline dot, the role + place, and the period. Flowe Pro.
    private func experienceRow(_ entry: Instructor.ExperienceEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Color.flowePink)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.role.isEmpty ? entry.place : entry.role)
                    .font(FloweFont.sans(14, .medium))
                    .foregroundStyle(Color.floweInk)
                Text(entry.role.isEmpty ? "" : entry.place)
                    .font(FloweFont.sans(13))
                    .foregroundStyle(Color.floweInk.opacity(0.7))
                if !entry.period.isEmpty {
                    Text(entry.period)
                        .font(FloweFont.mono(10))
                        .foregroundStyle(Color.floweMuted)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Flowe Pro brand kit: the studio "story" in a card carrying the instructor's brand accent — a
    /// left rule + a faint tint of their brand color. Only when a story is set. See [[FlowePro]].
    @ViewBuilder
    private func brandStoryCard(_ me: Instructor) -> some View {
        if !me.story.isEmpty {
            let tint = Color(hexString: me.brandColor) ?? Color.flowePink
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(text: "MY STUDIO")
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3)
                    Text(me.story)
                        .font(FloweFont.sans(14))
                        .foregroundStyle(Color.floweInk.opacity(0.85))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

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

            if let me { brandStoryCard(me) }

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

            // Flowe Pro: work history (the résumé spine). Only rendered when the instructor has added
            // entries — no empty-state nag in this first phase (the editor lands next). See [[FlowePro]].
            if let entries = me?.experience, !entries.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(text: "EXPERIENCE")
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(entries) { entry in
                            experienceRow(entry)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(text: "OFFERS")
                // Read the LIVE `LessonType` rows (the same source Edit Profile shows), not the
                // denormalised `me.sessionTypes` name cache — that cache only re-derives on a lesson-type
                // mutation, so types added before the derivation fix (or on another device) never appear
                // here even though the rows exist. The rows are authoritative for the owner's own screen.
                let offers = me.map { data.ownedLessonTypes(for: $0).filter { !$0.pendingDelete }.map(\.name) } ?? []
                if !offers.isEmpty {
                    FlowChipRow(items: offers)
                } else {
                    Text("Add the lesson types you offer in Edit Profile.")
                        .font(FloweFont.sans(13))
                        .foregroundStyle(Color.floweMuted)
                }
            }

            rateCard

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(text: "CERTIFICATION")
                // Show the text claim AND/OR the uploaded certificate photo — the empty state only when
                // BOTH are absent. A photo-only certification previously read as "empty" here even though
                // it showed in Edit Profile and to students (parity with StudentInstructorProfileView).
                let cert = me?.cert ?? ""
                let certImage = me?.certPhoto.flatMap { UIImage(data: $0) }
                if !cert.isEmpty || certImage != nil {
                    if !cert.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "rosette")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.flowePinkDeep)
                            Text(cert)
                                .font(FloweFont.sans(14))
                                .foregroundStyle(Color.floweInk)
                        }
                    }
                    if let certImage {
                        Button { Haptic.tap(); showCertZoom = true } label: {
                            Image(uiImage: certImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.floweBorder, lineWidth: 1))
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 26, height: 26)
                                        .background(.ultraThinMaterial, in: Circle())
                                        .padding(8)
                                }
                        }
                        .buttonStyle(.plain)
                        // Tap to open the certificate full-screen with pinch / double-tap zoom.
                        .fullScreenImageZoom(source: .uiImage(certImage), isPresented: $showCertZoom)
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
                SectionHeader(text: "STARTING RATE")
                Text(me.map { $0.price > 0 ? settings.money($0.price) : "—" } ?? "—")
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

    @ViewBuilder
    private var analyticsTab: some View {
        let sessionsByType = data.instructorSessionsByType
        let hasActivity = !data.incomingBookings.isEmpty

        if !hasActivity {
            EmptyStateView(
                icon: "chart.bar",
                title: "No analytics yet",
                message: "Once students start booking you, your session stats and rebooking rate will appear here."
            )
        } else {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    StatTile(value: "\(data.instructorCompletedCount)", label: "SESSIONS")
                    StatTile(value: "\(data.instructorStudentCount)", label: "STUDENTS", accent: .flowePink)
                    StatTile(value: "\(data.instructorRepeatStudentCount)", label: "REPEAT", accent: .floweSuccess)
                }

                HStack(spacing: 12) {
                    StatTile(value: acceptanceDisplay, label: "ACCEPTED")
                    StatTile(value: ratingSummary.map { String(format: "%.1f", $0.average) } ?? "—",
                             label: "RATING", accent: .flowePink)
                    StatTile(value: "\(reviews.count)", label: "REVIEWS", accent: .floweSuccess)
                }

                if !sessionsByType.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(text: "SESSIONS BY TYPE")
                        InstructorBarChart(
                            bars: sessionsByType.map { .init(label: $0.type, value: $0.count) },
                            showValues: true
                        )
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .floweCard()
                }
            }
        }
    }

    private var acceptanceDisplay: String {
        data.instructorAcceptanceRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }

    // MARK: - Reviews

    /// Non-empty review bodies — the input to the on-device "What students say" digest.
    private var reviewTextsForDigest: [String] { reviews.map(\.text).filter { !$0.isEmpty } }

    @ViewBuilder
    private var reviewsTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            // ✨ On-device review digest (Flowe Intelligence) — social proof atop the reviews. Only when
            // the model is available and there's enough to summarize; renders nothing otherwise.
            if #available(iOS 26, *), FloweAI.isAvailable, reviewTextsForDigest.count >= 3 {
                ReviewDigestCard(reviewTexts: reviewTextsForDigest)
            }
            if reviews.isEmpty {
                EmptyStateView(
                    icon: "star",
                    title: "No reviews yet",
                    // One literal, not a `+` concatenation — a concatenation is an expression, so it
                    // can't be a LocalizedStringKey and would never be extracted.
                    message: "After a session, students can review it from their Bookings tab. Their reviews will show up here."
                )
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        SectionHeader(text: "STUDENT REVIEWS")
                        Spacer()
                        if let summary = ratingSummary {
                            StarRatingView(rating: summary.average, size: 12)
                            Text("(\(summary.count))")
                                .font(FloweFont.mono(10))
                                .foregroundStyle(Color.floweMuted)
                        }
                    }

                    ForEach(reviews) { review in
                        ReviewRow(review: review)
                    }
                }
                .accessibilityIdentifier("instructor.reviewsList")
            }

            // Peer recommendations (Flowe Pro Phase 5) — instructor↔instructor endorsements, shown
            // whenever there are any, independent of student reviews. See [[FlowePro]].
            if !recommendations.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(text: "PEER RECOMMENDATIONS")
                    ForEach(recommendations) { RecommendationRow(recommendation: $0) }
                }
                .accessibilityIdentifier("instructor.recommendationsList")
            }
        }
    }

    // MARK: - Earnings

    @ViewBuilder
    private var earningsTab: some View {
        let earnings = data.instructorEarnings
        let byType = data.instructorSessionsByType
        let price = me?.price ?? 0

        if earnings.collected == 0 && earnings.projected == 0 {
            EmptyStateView(
                icon: "banknote",
                title: "No earnings yet",
                message: price == 0
                    ? "Set a price on your lesson types, then completed sessions will show up here."
                    : "Earnings from your completed sessions will appear here."
            )
        } else {
            VStack(alignment: .leading, spacing: 20) {
                earningsHeadline(earnings)

                if !byType.isEmpty, price > 0 {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(text: "BY SESSION TYPE")
                        ForEach(byType, id: \.type) { entry in
                            HStack {
                                Text(localizedTag: entry.type)
                                    .font(FloweFont.sans(14))
                                    .foregroundStyle(Color.floweInk)
                                Text("· \(entry.count)")
                                    .font(FloweFont.mono(11))
                                    .foregroundStyle(Color.floweMuted)
                                Spacer()
                                // Priced at THIS type's own price, not a single rate — keeps the
                                // per-type totals consistent with the collected/projected headline,
                                // which also sums each booking's actual lesson-type price.
                                Text(settings.money(entry.count * data.priceForType(entry.type)))
                                    .font(FloweFont.serif(15, .medium))
                                    .foregroundStyle(Color.floweInk)
                            }
                            .padding(.vertical, 6)
                            Divider().overlay(Color.floweBorder)
                        }
                    }
                    .padding(16)
                    .floweCard()
                }

                Text("Payment is arranged directly with your students, so these are session "
                     + "totals at each lesson type's price — Flowe doesn't process payments.")
                    .font(FloweFont.sans(12))
                    .foregroundStyle(Color.floweMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func earningsHeadline(_ earnings: (collected: Int, projected: Int)) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(text: "COLLECTED")
                Text(settings.money(earnings.collected))
                    .font(FloweFont.serif(26, .medium))
                    .foregroundStyle(Color.floweInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .floweCard()

            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(text: "PROJECTED")
                Text(settings.money(earnings.projected))
                    .font(FloweFont.serif(26, .medium))
                    .foregroundStyle(Color.flowePinkDeep)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .floweCard()
        }
    }
}

private extension Array where Element == String {
    /// "photo, city and bio" — reads as a sentence in the completeness nudge.
    var listed: String {
        guard count > 1 else { return first ?? "" }
        return dropLast().joined(separator: ", ") + String(localized: " and ") + (last ?? "")
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
