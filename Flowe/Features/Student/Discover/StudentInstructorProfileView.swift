import SwiftUI
import UIKit

/// A student's full-screen look at an instructor before booking — the rich, trust-first surface that
/// finally exposes the `Instructor` model the app was sitting on. It mirrors `EventDetailView`'s
/// skeleton (full-bleed hero, an identity card overlapping its lower edge, an honest stat trio, a
/// conditional section stack, a pinned action rail) and adds the review wall as the conversion
/// centrepiece.
///
/// Every number here is drawn from a source that can't lie: the rating and review count come from
/// real `Review` rows via `data.rating(for:)` / `data.reviews(for:)` — never the stored
/// `instructor.rating`/`.reviews`/`.students` fields, which are seed-only and were flagged in the
/// audit — so a brand-new instructor reads "New", never a fabricated 0.0. Certification is labelled
/// unverified because Flowe verifies nothing.
///
/// Like `EventDetailView`, `.task` must call the NON-pruning `syncReviews(forInstructor:)`: it can
/// only insert or update, so it can't delete a `Review` this open view is rendering, which would
/// trap.
///
/// Named `StudentInstructorProfileView`, not `InstructorProfileView`: the latter is already taken by
/// the instructor's own self-profile tab (`Features/Instructor/Profile/InstructorProfileView.swift`),
/// a different screen entirely. Two types can't share a name in one module. Callers (Discover, the
/// wire step) present this one by its full name.
struct StudentInstructorProfileView: View {
    let instructor: Instructor
    /// Metres to the instructor's coarse teaching area, threaded in from Discover (which owns the
    /// `LocationService` fix). Nil at the other two entry points and whenever either side has no
    /// location — the profile renders fine without it, showing a city and nothing else.
    var distanceMetres: Double? = nil
    let onClose: () -> Void

    @Environment(MockDataStore.self) private var data
    @Environment(AppSettings.self) private var settings

    @State private var showReport = false
    @State private var confirmBlock = false
    @State private var showCertificate = false
    @State private var showBooking = false

    /// Payment methods we know how to render, in canonical order — an unknown one never reaches a chip.
    private var methods: [String] { PaymentMethod.known(instructor.paymentMethods) }

    /// The derived rating summary — nil until the first real review, which is a different state from
    /// a 0.0 score and must render differently everywhere.
    private var ratingSummary: (average: Double, count: Int)? {
        instructor.ownerID.flatMap { data.rating(for: $0) }
    }

    private var reviews: [Review] {
        instructor.ownerID.map { data.reviews(for: $0) } ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    hero
                    identityCard
                        .padding(.top, -24)   // overlap the hero's lower edge
                    statTrio
                        .padding(.top, 20)
                    sections
                        .padding(.top, 24)
                    reviewsSection
                        .padding(.top, 24)
                }
                .padding(.bottom, 24)
            }
            .ignoresSafeArea(edges: .top)
            .background(Color.flowWhite)
            .navigationBarHidden(true)
            .safeAreaInset(edge: .bottom) { actionRail }
        }
        .presentationDragIndicator(.hidden)   // the hero owns a custom xmark; no grabber over the photo
        .accessibilityIdentifier("instructor.profile")
        .task {
            if let id = instructor.ownerID { await data.syncReviews(forInstructor: id) }
            // Pull the instructor's rich lesson types so the OFFERS cards and the booking picker show
            // capacity/details/photos, not just the denormalised name cache. Same non-pruning pattern
            // as reviews: a student viewing this profile fetches all of one instructor's types.
            await data.syncLessonTypes(for: instructor)
        }
        .sheet(isPresented: $showReport) {
            ReportSheet(
                reportedID: instructor.ownerID ?? "",
                reportedName: instructor.name,
                content: .instructorListing,
                contentID: instructor.ownerID ?? "",
                snapshot: [instructor.name, instructor.city, instructor.cert, instructor.bio ?? ""]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
            )
        }
        .fullScreenCover(isPresented: $showCertificate) { certificateViewer }
        .sheet(isPresented: $showBooking) {
            // Sheet-on-sheet, the proven EventDetailView→BookingSheet pattern. startStep:1 skips the
            // orphaned intro and lands on the day picker, since this profile IS the intro.
            //
            // On a completed booking, dismiss the whole stack (the profile too) so the student lands
            // back in the app — not stranded on the profile with the tab bar hidden behind it. On a
            // mid-flow cancel, only the booking sheet closes and the profile stays.
            BookingSheet(instructor: instructor, startStep: 1) { booked in
                if booked { onClose() } else { showBooking = false }
            }
        }
        .confirmationDialog("Block \(instructor.firstName)?",
                            isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                if let id = instructor.ownerID { data.block(id: id, name: instructor.name) }
                onClose()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won't see their profile or messages. You can undo this in Settings.")
        }
    }

    // MARK: - Hero

    private var hero: some View {
        heroPhoto
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, Color.floweInk.opacity(0.75)],
                    startPoint: .center, endPoint: .bottom
                )
            }
            .clipped()
            .overlay(alignment: .bottomLeading) { heroCaption }
            .overlay(alignment: .topTrailing) { heroButtons }
    }

    @ViewBuilder
    private var heroPhoto: some View {
        if instructor.photo != nil || !instructor.img.isEmpty {
            RemoteImage(id: instructor.img, photo: instructor.photo, width: 800, height: 600)
        } else {
            // RemoteImage would already fall back to the flat gradient, but a full-bleed hero earns a
            // watermark so the empty state reads as designed, not as a failed load.
            FlowGradients.grad
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "figure.pilates")
                        .font(.system(size: 110))
                        .foregroundStyle(.white.opacity(0.18))
                        .padding(24)
                }
        }
    }

    private var heroCaption: some View {
        VStack(alignment: .leading, spacing: 8) {
            metaText
                .font(FloweFont.mono(11))
                .foregroundStyle(.white.opacity(0.85))
                .textCase(.uppercase)
            // The striking move, lifted from EventDetailView: the name set large in Fraunces, white,
            // over the darkened photo.
            Text(instructor.name)
                .font(FloweFont.serif(30, .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .shadow(color: Color.floweInk.opacity(0.35), radius: 8, y: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var heroButtons: some View {
        HStack(spacing: 10) {
            circleButton("xmark") { onClose() }
                .accessibilityLabel(Text("Close"))
            moderationMenu
        }
        .padding(.horizontal, 16)
        // Push clear of the status bar — the hero ignores the top safe area.
        .padding(.top, 56)
    }

    private func circleButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.floweInk)
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var moderationMenu: some View {
        Menu {
            // A listing's name, city, bio and certification are user-written and public, so students
            // need a way to flag one (App Store Review Guideline 1.2).
            Button("Report this profile", systemImage: "flag") { showReport = true }
            Button("Block \(instructor.firstName)", systemImage: "hand.raised",
                   role: .destructive) { confirmBlock = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.floweInk)
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityIdentifier("instructor.moderation")
    }

    /// City · distance, built from SEPARATE `Text` runs so the system lays it out bidirectionally —
    /// a baked "City · ~2 km" string would read backwards in Arabic. Distance only appears when it was
    /// threaded in; `city` is user text and passes through unlocalized. Mirrors InstructorCard.
    private var metaText: Text {
        var run = Text(instructor.city)
        if let d = distanceMetres {
            if !instructor.city.isEmpty { run = run + Text(verbatim: " · ") }
            run = run + Text(FloweDistance.label(metres: d))
        }
        return run
    }

    // MARK: - Identity card

    private var identityCard: some View {
        HStack(spacing: 12) {
            AvatarView(id: instructor.img, photo: instructor.photo, size: 44, ring: true)

            VStack(alignment: .leading, spacing: 2) {
                Text("INSTRUCTOR")
                    .font(FloweFont.mono(9))
                    .foregroundStyle(Color.floweMuted)
                Text(instructor.name)
                    .font(FloweFont.sans(15, .medium))
                    .foregroundStyle(Color.floweInk)
                    .lineLimit(1)
                metaText
                    .font(FloweFont.sans(11))
                    .foregroundStyle(Color.floweMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            ratingCluster
        }
        .padding(16)
        .floweCard(cornerRadius: 18)
        .padding(.horizontal, 20)
    }

    /// The only rating source is derived. A star cluster when reviews exist; a neutral "New" pill
    /// otherwise — never a fabricated 0.0 or empty stars.
    @ViewBuilder
    private var ratingCluster: some View {
        if let summary = ratingSummary {
            StarRatingView(rating: summary.average)
                .accessibilityIdentifier("instructor.rating")
        } else {
            Text("New")
                .font(FloweFont.mono(10))
                .foregroundStyle(Color.floweMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.flowePink.opacity(0.10), in: Capsule())
                .accessibilityIdentifier("instructor.rating")
        }
    }

    // MARK: - Stat trio

    /// Three honest tiles — the deleted fake "Students" stat's replacement. Unknowns render an em dash
    /// on a muted accent, never a zero.
    private var statTrio: some View {
        HStack(spacing: 12) {
            if let summary = ratingSummary {
                StatTile(value: String(format: "%.1f", summary.average),
                         label: "RATING", accent: .flowePinkDeep)
            } else {
                StatTile(value: "New", label: "RATING", accent: .floweMuted)
            }

            StatTile(value: instructor.yearsExp > 0 ? "\(instructor.yearsExp)" : "—",
                     label: "YEARS",
                     accent: instructor.yearsExp > 0 ? .flowePinkDeep : .floweMuted)

            StatTile(value: instructor.price == 0 ? String(localized: "Free") : settings.money(instructor.price),
                     label: "PER SESSION", accent: .flowePinkDeep)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Sections

    /// Every section is conditional — an empty field yields no empty block, so a sparse listing still
    /// reads as a finished screen rather than a form with holes in it.
    private var sections: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let bio = instructor.bio, !bio.isEmpty {
                section("ABOUT") {
                    Text(bio)
                        .font(FloweFont.sans(15))
                        .foregroundStyle(Color.floweInk)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !instructor.specialties.isEmpty {
                section("SPECIALTIES") {
                    FlowLayout(spacing: 6) {
                        // Raw user strings — passed through, never localized.
                        ForEach(instructor.specialties, id: \.self) { SpecialtyTag(text: $0) }
                    }
                }
            }

            // Rich, instructor-authored lesson types via the single resolver — owned rows when the
            // instructor has authored any, else the denormalised name cache as name-only cards. The
            // section stays conditional: a genuinely empty resolver omits it, an honest empty state
            // rather than a backfilled default.
            let types = data.lessonTypes(for: instructor)
            if !types.isEmpty {
                section("OFFERS") {
                    VStack(spacing: 12) {
                        ForEach(Array(types.enumerated()), id: \.element.id) { index, type in
                            LessonTypeCard(type: type, index: index)
                        }
                    }
                }
            }

            teachingArea
            availability
            certificationBlock
            paymentBlock
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    /// A titled block. Collapses to nothing when its content is empty (a `@ViewBuilder` `if` yields an
    /// EmptyView), which is how the section stack stays hole-free.
    private func section<Content: View>(_ title: LocalizedStringKey,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(text: title)
            content()
        }
    }

    // MARK: - Teaching area

    @ViewBuilder
    private var teachingArea: some View {
        // With neither a distance fix nor a city there is nothing true to show, so omit the block
        // rather than print an empty pin.
        if distanceMetres != nil || !instructor.city.isEmpty {
            section("TEACHING AREA") {
                HStack(spacing: 8) {
                    Image(systemName: "mappin.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.flowePinkDeep)
                    // Separate runs (RTL-safe): distance, then city — never coarseLocation.displayText,
                    // never a precise figure.
                    if let d = distanceMetres {
                        Text(FloweDistance.label(metres: d))
                            .font(FloweFont.mono(12))
                            .foregroundStyle(Color.flowePinkDeep)
                    }
                    if !instructor.city.isEmpty {
                        Text(instructor.city)
                            .font(FloweFont.sans(14))
                            .foregroundStyle(Color.floweInk)
                    }
                }
                Text("Approximate teaching area.")
                    .font(FloweFont.mono(9))
                    .foregroundStyle(Color.floweMuted)
            }
        }
    }

    // MARK: - Availability

    @ViewBuilder
    private var availability: some View {
        if !instructor.bookableDays.isEmpty {
            section("AVAILABILITY") {
                HStack(spacing: 6) {
                    ForEach(FloweConstants.weekdays, id: \.self) { day in
                        let open = instructor.isBookable(on: day)
                        // `day` is the model's own English key; wrap it so ar/es/fr can translate the
                        // 3-letter label while the stored value stays English.
                        Text(LocalizedStringKey(day))
                            .font(FloweFont.mono(10))
                            .textCase(.uppercase)
                            .foregroundStyle(open ? .white : Color.floweMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background {
                                if open {
                                    RoundedRectangle(cornerRadius: 10).fill(FlowGradients.gradDark)
                                } else {
                                    // Mirrors stepDay's disabled cell so the preview matches what
                                    // booking actually offers.
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.floweBorder.opacity(0.25))
                                }
                            }
                            .opacity(open ? 1 : 0.5)
                    }
                }
                Text("Pick a time when you book.")
                    .font(FloweFont.mono(9))
                    .foregroundStyle(Color.floweMuted)
            }
        }
    }

    // MARK: - Certification

    private var hasCertification: Bool { !instructor.cert.isEmpty || instructor.certPhoto != nil }

    /// The instructor's own certification claim — text, and the certificate photo if they uploaded
    /// one. The disclaimer travels with it: a photo makes the claim look official, and Flowe checks
    /// none of it. Absent entirely, the block is silent — a missing credential is not a red flag.
    @ViewBuilder
    private var certificationBlock: some View {
        if hasCertification {
            section("CERTIFICATION") {
                if !instructor.cert.isEmpty {
                    Text(instructor.cert)
                        .font(FloweFont.sans(13))
                        .foregroundStyle(Color.floweInk)
                }

                if let bytes = instructor.certPhoto, let image = UIImage(data: bytes) {
                    Button { showCertificate = true } label: {
                        Image(uiImage: image)
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
                    .accessibilityIdentifier("instructor.certPhoto")
                }

                Text("Flowe doesn't verify certifications.")
                    .font(FloweFont.mono(10))
                    .foregroundStyle(Color.floweMuted)
            }
        }
    }

    /// Full-screen look at the certificate — the credential and its date are often small print. The
    /// disclaimer follows it here too, where the photo fills the screen and reads most like an
    /// endorsement.
    private var certificateViewer: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Spacer(minLength: 0)
                if let bytes = instructor.certPhoto, let image = UIImage(data: bytes) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
                Spacer(minLength: 0)
                Text("Flowe doesn't verify certifications.")
                    .font(FloweFont.mono(10))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(20)

            VStack {
                HStack {
                    Spacer()
                    Button { showCertificate = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityIdentifier("instructor.certPhotoClose")
                }
                Spacer()
            }
            .padding(16)
        }
    }

    // MARK: - Payment

    /// How the student will actually pay. Flowe collects nothing, so this belongs on the profile, not
    /// in fine print after booking. An unlisted method yields guidance, never an empty row.
    private var paymentBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(text: "PAYMENT")

            if methods.isEmpty {
                Text("\(instructor.firstName) hasn't listed how they take payment — ask them before your session.")
                    .font(FloweFont.sans(13))
                    .foregroundStyle(Color.floweInk)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(methods, id: \.self) { method in
                        Text(PaymentMethod.label(method))
                            .font(FloweFont.mono(11))
                            .foregroundStyle(Color.flowePinkDeep)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.flowePink.opacity(0.12), in: Capsule())
                    }
                }
                Text("Flowe doesn't process payments — you pay \(instructor.firstName) directly.")
                    .font(FloweFont.mono(10))
                    .foregroundStyle(Color.floweMuted)
            }
        }
        .accessibilityIdentifier("instructor.payment")
    }

    // MARK: - Reviews

    /// The centrepiece. Real reviews, newest first, blocked authors already filtered by the accessor.
    private var reviewsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(text: "REVIEWS")
                Spacer()
                if let summary = ratingSummary {
                    StarRatingView(rating: summary.average)
                    Text("^[\(summary.count) review](inflect: true)")
                        .font(FloweFont.mono(9))
                        .foregroundStyle(Color.floweMuted)
                }
            }

            reviewsBody
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .accessibilityIdentifier("instructor.reviews")
    }

    @ViewBuilder
    private var reviewsBody: some View {
        if reviews.isEmpty {
            // A compact inline state, deliberately NOT the full EmptyStateView splash — the profile
            // still has to read as a real screen. Never a fabricated 0.0 or empty stars.
            VStack(alignment: .leading, spacing: 4) {
                Text("No reviews yet")
                    .font(FloweFont.mono(11))
                    .foregroundStyle(Color.floweMuted)
                Text("Be the first to book \(instructor.firstName) and share how it went.")
                    .font(FloweFont.sans(13))
                    .foregroundStyle(Color.floweMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            VStack(spacing: 12) {
                ForEach(reviews.prefix(3)) { ReviewRow(review: $0) }
            }
            if reviews.count > 3 {
                NavigationLink {
                    AllReviewsView(instructorName: instructor.name, reviews: reviews)
                } label: {
                    Text("Read all ^[\(reviews.count) review](inflect: true)")
                        .font(FloweFont.sans(14, .medium))
                        .foregroundStyle(Color.flowePinkDeep)
                }
                .accessibilityIdentifier("instructor.reviewsAll")
            }
        }
    }

    // MARK: - Action rail

    /// Booking is always available for a visible listing — no unavailable state — so this is a real
    /// CTA, never a disabled plate.
    private var actionRail: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.floweBorder).frame(height: 1)
            VStack(spacing: 8) {
                GradientButton(title: "Book a session · \(settings.money(instructor.price))") {
                    showBooking = true
                }
                .accessibilityIdentifier("instructor.book")
                Text("Free to book. You'll pay \(instructor.firstName) directly.")
                    .font(FloweFont.mono(9))
                    .foregroundStyle(Color.floweMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
        }
        .background(Color.flowWhite)
    }
}

// MARK: - All reviews

/// The full review wall, pushed from the profile when there are more than three. A plain list of the
/// same `ReviewRow`, in its own navigation child — no pagination story, it just renders whatever
/// `reviews(for:)` returned.
private struct AllReviewsView: View {
    let instructorName: String   // user-authored — shown verbatim, never localized
    let reviews: [Review]

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(reviews) { ReviewRow(review: $0) }
            }
            .padding(20)
        }
        .background(Color.flowWhite)
        .navigationTitle(Text(verbatim: instructorName))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    StudentInstructorProfileView(instructor: MockDataStore.preview.instructors[0], distanceMetres: 1400) {}
        .environment(MockDataStore.preview)
        .environment(AppSettings())
        .environment(AppSession())
}
