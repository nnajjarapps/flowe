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
    /// Metres to the instructor's exact studio location, threaded in from Discover (which owns the
    /// `LocationService` fix). Nil at the other two entry points and whenever either side has no
    /// location — the profile renders fine without it, showing an address and nothing else.
    var distanceMetres: Double? = nil
    let onClose: () -> Void

    @Environment(MockDataStore.self) private var data
    @Environment(AppSettings.self) private var settings
    @Environment(AppSession.self) private var session

    @State private var showReport = false
    @State private var confirmBlock = false
    @State private var showCertificate = false
    @State private var showHeroZoom = false
    @State private var showBooking = false
    @State private var showGuestSignIn = false

    /// App Store 5.1.1(v): a guest may VIEW this profile but any account action (book, save, join,
    /// report, block) prompts sign-in instead of running. After signing in, `AppRouter` swaps into the
    /// real student shell and the user re-taps. Also fences the write off — a guest never mutates data.
    private func requireAccount(_ action: () -> Void) {
        if session.isGuest { showGuestSignIn = true } else { action() }
    }

    /// Payment methods we know how to render, in canonical order — an unknown one never reaches a chip.
    private var methods: [String] { PaymentMethod.known(instructor.paymentMethods) }

    /// The rating summary. PREFER the summary derived from real `Review` rows this device has cached
    /// (freshest, review-backed). A browsing student usually has none cached, so FALL BACK to the
    /// listing's PUBLISHED aggregate (`instructor.rating`/`.reviews`) whenever it carries at least one
    /// review — that published number IS the real, review-derived aggregate (see `syncReviews` →
    /// `me.rating = summary.average`), and it is exactly what Discover cards and the booking sheet show,
    /// so the profile no longer contradicts them with "New". Only a genuinely review-less instructor
    /// (published count 0) reads "New" — never a fabricated 0.0.
    private var ratingSummary: (average: Double, count: Int)? {
        if let derived = instructor.ownerID.flatMap({ data.rating(for: $0) }) { return derived }
        return instructor.reviews > 0 ? (instructor.rating, instructor.reviews) : nil
    }

    private var reviews: [Review] {
        instructor.ownerID.map { data.reviews(for: $0) } ?? []
    }

    /// Peer recommendations of this instructor (Flowe Pro) — social proof from fellow instructors.
    private var recommendations: [InstructorRecommendation] {
        instructor.ownerID.map { data.recommendations(for: $0) } ?? []
    }

    /// The instructor's community circle (Flowe Community slice 4) — community-visible students who train
    /// here. Loaded on-demand (a student doesn't cache others' bookings).
    @State private var circle: [(id: String, name: String)] = []
    @State private var circleLoaded = false
    @State private var showCircleChat = false
    @State private var selectedFriend: PeerRef?

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
                    recommendationsSection
                        .padding(.top, 24)
                    communitySection
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
            if let id = instructor.ownerID {
                await data.syncReviews(forInstructor: id)
                // Warm the reviewers' live identities by their KNOWN ownerIDs so a renamed reviewer
                // resolves fresh instead of the frozen `Review.studentName` snapshot. `syncStudentProfiles`
                // is instructor-only, so on this student-facing wall nothing else populates that cache.
                await data.fetchAuthorProfiles(Set(data.reviews(for: id).compactMap { $0.studentID }))
                // Peer recommendations shown on this profile (Flowe Pro social proof).
                await data.syncRecommendations(forInstructor: id)
                // The instructor's community circle (Flowe Community) — only when the viewer opted in.
                if data.isCommunityVisible {
                    await data.syncFollows()   // so circle chips show the right follow state
                    circle = await data.fetchInstructorCircle(ownerID: id)
                    // Circle chat count for members (train here + opted in).
                    if data.canDiscussCircle(ownerID: id) { await data.syncCircleComments(for: id) }
                }
                circleLoaded = true
            }
            // Pull the instructor's rich lesson types so the OFFERS cards and the booking picker show
            // capacity/details/photos, not just the denormalised name cache. Same non-pruning pattern
            // as reviews: a student viewing this profile fetches all of one instructor's types.
            await data.syncLessonTypes(for: instructor)
        }
        .sheet(item: $selectedFriend) { PracticeFriendSheet(peer: $0) }
        .sheet(isPresented: $showCircleChat) {
            if let id = instructor.ownerID {
                DiscussionSheet(
                    title: "Circle chat",
                    emptyHint: String(localized: "Say hi to the others who train with \(instructor.firstName)."),
                    comments: { data.circleComments(for: id) },
                    onSend: { data.addCircleComment(to: id, text: $0) },
                    onSync: { await data.syncCircleComments(for: id) }
                )
            }
        }
        .sheet(isPresented: $showGuestSignIn) { GuestSignInSheet() }
        .sheet(isPresented: $showReport) {
            ReportSheet(
                reportedID: instructor.ownerID ?? "",
                reportedName: instructor.name,
                content: .instructorListing,
                contentID: instructor.ownerID ?? "",
                snapshot: [instructor.name, instructor.address, instructor.cert, instructor.bio ?? ""]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
            )
        }
        // The certificate photo, and the full-bleed listing hero, both open the shared
        // pinch/double-tap/drag-down zoomable viewer instead of a plain full-screen still.
        .fullScreenImageZoom(source: .data(instructor.certPhoto), isPresented: $showCertificate)
        .fullScreenImageZoom(source: .remote(id: instructor.img, photo: instructor.photo),
                             isPresented: $showHeroZoom)
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
            // Tap the listing photo to open it full-screen and zoomable. The overlaid xmark /
            // moderation Buttons take hit priority in their own corners, so this only fires on the
            // photo itself; guarded so an image-less gradient hero stays inert.
            .contentShape(Rectangle())
            .onTapGesture {
                guard instructor.photo != nil || !instructor.img.isEmpty else { return }
                Haptic.tap()
                showHeroZoom = true
            }
    }

    @ViewBuilder
    private var heroPhoto: some View {
        if let cover = instructor.coverPhoto, let ui = UIImage(data: cover) {
            // Flowe Pro brand cover wins the hero when set — it's a wide brand banner, exactly this slot.
            Image(uiImage: ui).resizable().scaledToFill()
        } else if instructor.photo != nil || !instructor.img.isEmpty {
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
            // Flowe Pro: the professional headline sits under the name on the hero. See [[FlowePro]].
            if !instructor.headline.isEmpty {
                Text(instructor.headline)
                    .font(FloweFont.sans(13, .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .shadow(color: Color.floweInk.opacity(0.35), radius: 6, y: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var heroButtons: some View {
        HStack(spacing: 10) {
            circleButton("xmark") { onClose() }
                .accessibilityLabel(Text("Close"))
            Spacer(minLength: 0)
            saveButton
            moderationMenu
        }
        .padding(.horizontal, 16)
        // Push clear of the status bar — the hero ignores the top safe area.
        .padding(.top, 56)
    }

    /// Save this instructor to the local wishlist (heart). Filled + pink when saved.
    private var saveButton: some View {
        let saved = data.isSaved(instructor.ownerID)
        return Button {
            requireAccount {
                Haptic.tap()
                withAnimation(FloweMotion.pop) { data.toggleSaved(instructor.ownerID) }
            }
        } label: {
            Image(systemName: saved ? "heart.fill" : "heart")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(saved ? Color.flowePinkDeep : Color.floweInk)
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(saved ? "Saved — tap to remove" : "Save instructor"))
        .accessibilityIdentifier("instructor.save")
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
            // A listing's name, address, bio and certification are user-written and public, so students
            // need a way to flag one (App Store Review Guideline 1.2).
            Button("Report this profile", systemImage: "flag") { requireAccount { showReport = true } }
            Button("Block \(instructor.firstName)", systemImage: "hand.raised",
                   role: .destructive) { requireAccount { confirmBlock = true } }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.floweInk)
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityIdentifier("instructor.moderation")
    }

    /// Address · distance, built from SEPARATE `Text` runs so the system lays it out bidirectionally —
    /// a baked "Address · ~2 km" string would read backwards in Arabic. Distance only appears when it was
    /// threaded in; `address` is user text and passes through unlocalized. Mirrors InstructorCard.
    private var metaText: Text {
        // A guest (unauthenticated) must NOT see the instructor's exact home address — only the coarse
        // distance chip, if any. The full address is revealed once they sign in (matching reveal-at-booking).
        let address = session.isGuest ? "" : instructor.address
        var run = Text(address)
        if let d = distanceMetres {
            if !address.isEmpty { run = run + Text(verbatim: " · ") }
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
                StatTile(value: String(localized: "New"), label: "RATING", accent: .floweMuted)
            }

            StatTile(value: instructor.yearsExp > 0 ? "\(instructor.yearsExp)" : "—",
                     label: "YEARS",
                     accent: instructor.yearsExp > 0 ? .flowePinkDeep : .floweMuted)

            // Derived "starting from" price (cheapest lesson type). "—" when no type is priced yet,
            // never a fabricated 0. A specific type's price is shown once one is chosen in BookingSheet.
            StatTile(value: instructor.price == 0 ? "—" : settings.money(instructor.price),
                     label: "STARTING", accent: .flowePinkDeep)
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

            brandStoryBlock

            if !instructor.specialties.isEmpty {
                section("SPECIALTIES") {
                    FlowLayout(spacing: 6) {
                        // Raw user strings — passed through, never localized.
                        ForEach(instructor.specialties, id: \.self) { SpecialtyTag(text: $0) }
                    }
                }
            }

            // Flowe Pro: the instructor's work history, same pink-dot timeline as their own profile.
            let experience = instructor.experience
            if !experience.isEmpty {
                section("EXPERIENCE") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(experience) { entry in
                            experienceRow(entry)
                        }
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

            studioLocation
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

    /// Flowe Pro brand kit: the studio "story" in a brand-accented card (left rule + faint brand tint),
    /// mirroring the instructor's own profile. Only when a story is set. See [[FlowePro]].
    @ViewBuilder
    private var brandStoryBlock: some View {
        if !instructor.story.isEmpty {
            let tint = Color(hexString: instructor.brandColor) ?? Color.flowePink
            section("MY STUDIO") {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3)
                    Text(instructor.story)
                        .font(FloweFont.sans(15))
                        .foregroundStyle(Color.floweInk.opacity(0.9))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    /// One work-history row: a pink timeline dot, the role + place, and the period. Flowe Pro — mirrors
    /// the instructor's own-profile timeline so a student sees the same résumé.
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

    // MARK: - Studio location

    @ViewBuilder
    private var studioLocation: some View {
        let hasAddress = !instructor.address.isEmpty
        // A guest never sees the exact address (privacy) — only the coarse distance and a sign-in hint.
        let showsAddress = hasAddress && !session.isGuest
        // With neither a distance fix nor an address there is nothing true to show, so omit the block
        // rather than print an empty pin.
        if distanceMetres != nil || hasAddress {
            section("STUDIO LOCATION") {
                HStack(spacing: 8) {
                    Image(systemName: "mappin.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.flowePinkDeep)
                    // Separate runs (RTL-safe): distance, then the exact studio address.
                    if let d = distanceMetres {
                        Text(FloweDistance.label(metres: d))
                            .font(FloweFont.mono(12))
                            .foregroundStyle(Color.flowePinkDeep)
                    }
                    if showsAddress {
                        Text(instructor.address)
                            .font(FloweFont.sans(14))
                            .foregroundStyle(Color.floweInk)
                    }
                }
                Text(session.isGuest && hasAddress
                     ? "Sign in to see the exact studio location."
                     : "The studio where you'll meet.")
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
                    Button { Haptic.tap(); showCertificate = true } label: {
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
    /// Non-empty review bodies — input to the on-device "What students say" digest.
    private var reviewTextsForDigest: [String] { reviews.map(\.text).filter { !$0.isEmpty } }

    private var reviewsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ✨ On-device review digest (Flowe Intelligence) — a summary a student can read at a glance.
            // Only when the model is available and there's enough to summarize.
            if #available(iOS 26, *), FloweAI.isAvailable, reviewTextsForDigest.count >= 3 {
                ReviewDigestCard(reviewTexts: reviewTextsForDigest)
            }
            HStack {
                SectionHeader(text: "REVIEWS")
                Spacer()
                // Gate the header star cluster on ACTUAL cached review rows, not just `ratingSummary`:
                // the published-aggregate fallback fires exactly when no Review rows are cached, which is
                // the same state the body renders "No reviews yet" — so keying the header on the aggregate
                // put "★ N reviews" directly above "No reviews yet". The hero/statTrio still shows the
                // aggregate (there is no review LIST there to contradict).
                if !reviews.isEmpty, let summary = ratingSummary {
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

    // MARK: - Peer recommendations (Flowe Pro)

    /// Peer endorsements from fellow instructors — strong social proof for a student choosing who to book.
    /// Self-hides when there are none. See [[FlowePro]].
    @ViewBuilder
    private var recommendationsSection: some View {
        if !recommendations.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(text: "PEER RECOMMENDATIONS")
                VStack(spacing: 12) {
                    ForEach(recommendations.prefix(3)) { RecommendationRow(recommendation: $0) }
                }
                if recommendations.count > 3 {
                    Text("^[\(recommendations.count) recommendation](inflect: true) from fellow instructors")
                        .font(FloweFont.mono(9))
                        .foregroundStyle(Color.floweMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .accessibilityIdentifier("instructor.recommendations")
        }
    }

    // MARK: - Community circle (Flowe Community)

    /// The instructor's community circle — the students who train here (opt-in). Reciprocity, like the
    /// event roster: opted-in viewers see the circle AND appear in it; others get the invite. This is the
    /// instructor-anchored hub that makes each circle exist from day one. See [[Flowe-Community]].
    @ViewBuilder
    private var communitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(text: "COMMUNITY")
            if data.isCommunityVisible {
                if !circleLoaded {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading the community…")
                            .font(FloweFont.sans(12)).foregroundStyle(Color.floweMuted)
                    }
                } else if circle.isEmpty {
                    Text("You're the first here from the Flowe community — others who train with \(instructor.firstName) will show up as they join.")
                        .font(FloweFont.sans(13))
                        .foregroundStyle(Color.floweMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("^[\(circle.count) student](inflect: true) from the community train with \(instructor.firstName)")
                        .font(FloweFont.mono(9))
                        .foregroundStyle(Color.floweMuted)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) { ForEach(circle, id: \.id) { memberChip($0) } }
                    }
                }
                // Members (train here + opted in) can chat with the circle.
                if let id = instructor.ownerID, data.canDiscussCircle(ownerID: id) {
                    circleChatButton(id)
                }
            } else {
                Text("Join the Flowe community to meet the students who train with \(instructor.firstName).")
                    .font(FloweFont.sans(13))
                    .foregroundStyle(Color.floweInk)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    // Gate for guests: setCommunityVisible publishes a public StudentProfile and would
                    // fall back to the placeholder owner even with a nil currentUserID — so this MUST be
                    // its own guest guard, not left to the nil-owner backstop.
                    requireAccount {
                        data.setCommunityVisible(true)
                        Task {
                            if let id = instructor.ownerID {
                                circle = await data.fetchInstructorCircle(ownerID: id)
                                circleLoaded = true
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.fill").font(.system(size: 12))
                        Text("Join the community")
                    }
                    .font(FloweFont.sans(13, .medium))
                    .foregroundStyle(Color.flowePinkDeep)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color.flowePink.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .accessibilityIdentifier("instructor.community")
    }

    /// Entry into the instructor's circle chat — for members (train here + opted in).
    private func circleChatButton(_ id: String) -> some View {
        let n = data.circleComments(for: id).count
        return Button { showCircleChat = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.flowePinkDeep)
                Text(n == 0 ? String(localized: "Say hi to the circle")
                            : String(localized: "Circle chat · \(n) messages"))
                    .font(FloweFont.sans(13, .medium))
                    .foregroundStyle(Color.flowePinkDeep)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.floweMuted)
            }
            .padding(12)
            .background(Color.flowePink.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.flowePink.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .accessibilityIdentifier("circle.chat")
    }

    private func memberChip(_ m: (id: String, name: String)) -> some View {
        let first = m.name.split(separator: " ").first.map(String.init) ?? m.name
        // Tap a circle member to follow them (Flowe Community slice 6) — shared-context, never cold.
        return Button { selectedFriend = PeerRef(id: m.id, name: m.name) } label: {
            VStack(spacing: 6) {
                if let photo = data.peerPhoto(forOwnerID: m.id) {
                    AvatarView(id: "", photo: photo, size: 50)
                } else {
                    InitialAvatar(name: m.name, size: 50)
                }
                Text(first.isEmpty ? String(localized: "Someone") : first)
                    .font(FloweFont.sans(11, .medium))
                    .foregroundStyle(Color.floweInk)
                    .lineLimit(1)
                    .frame(maxWidth: 60)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Action rail

    /// Booking is always available for a visible listing — no unavailable state — so this is a real
    /// CTA, never a disabled plate.
    private var actionRail: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.floweBorder).frame(height: 1)
            VStack(spacing: 8) {
                // Pre-type CTA: the price hint is the "from" starting price (cheapest lesson type), and
                // is dropped entirely when no type is priced. The nested localization reuses the
                // existing "from %@" + "Book a session · %@" keys.
                GradientButton(title: instructor.price > 0
                    ? "Book a session · \(String(localized: "from \(settings.money(instructor.price))"))"
                    : "Book a session") {
                    Haptic.tap()
                    requireAccount { showBooking = true }   // 5.1.1(v): booking is account-based
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
