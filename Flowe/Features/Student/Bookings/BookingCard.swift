import SwiftUI

/// A single booking row: darkened image header band with avatar, name, meta and
/// status badge, over a body row with date / time and a trailing action button.
struct BookingCard: View {
    @Environment(MockDataStore.self) private var data
    @Environment(\.locale) private var locale

    let booking: Booking

    /// The card's two sheets share ONE presentation. Two `.sheet` modifiers on the same view is a
    /// SwiftUI trap — the later one shadows the earlier, so "Book again" set its state but never
    /// presented while a review sheet also existed on the row. One item-driven sheet, one route.
    private enum Route: Identifiable {
        case review
        case classmates
        case detail
        var id: String {
            switch self {
            case .review:             return "review"
            case .classmates:         return "classmates"
            case .detail:             return "detail"
            }
        }
    }

    /// The cancel confirmation is ONE dialog driven by this enum (a second `.confirmationDialog` shadows
    /// the first, the same trap as `.sheet`). A one-off booking → `.oneOff` (plain cancel); a standing
    /// weekly series → `.recurring`, whose dialog offers BOTH "skip this week" and "end series" — without
    /// this a student could only ever cancel single weeks, and the rolling top-up regrew the series.
    private enum CancelKind { case oneOff, recurring }

    /// Whether tapping cancel should present the standing-series dialog (skip-this-week vs end-series)
    /// rather than a plain one-off cancel: true for a recurring booking that isn't a waitlisted overflow
    /// week (a waitlisted week just leaves that week's waitlist). Pure + unit-tested — this is the wiring
    /// that was missing (the button used to always pick `.oneOff`). See [[flowe-recurring-series-cancel]].
    nonisolated static func offersSeriesCancel(isRecurring: Bool, isWaitlisted: Bool) -> Bool {
        isRecurring && !isWaitlisted
    }
    @State private var route: Route?
    /// "Book again" opens the full-screen profile via its OWN cover, kept off the sheet route.
    @State private var bookAgainInstructor: Instructor?
    @State private var cancelKind: CancelKind?

    private var instructor: Instructor? { data.instructor(id: booking.instructorId) }

    /// The instructor going out of studio addresses the student a `CoverageSession` — the ONE coverage
    /// record that names the student, and only the student it concerns can read it. The booking itself
    /// is never mutated (it's student-creator-write), so this is how a covered session shows up on the
    /// card the student already has. `status == 0` is an active cover; a cancelled one drops the badge.
    private var coverSession: RemoteCoverageSession? {
        guard let id = booking.remoteID,
              let session = data.coverSession(forBookingID: id),
              session.status == 0 else { return nil }
        return session
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let coverSession { coveredBanner(coverSession) }
            bodyRow
        }
        .floweCard()
        // The whole card opens a full detail sheet — a bigger, calmer surface where the review action
        // is an unmistakable full-width button (the inline link below is small and easy to miss). The
        // inner action buttons keep their own taps; SwiftUI gives a Button priority within its frame,
        // so this fires only for taps on the card's empty areas (header, date/time). contentShape makes
        // those empty areas hit-testable.
        .contentShape(Rectangle())
        .onTapGesture { route = .detail }
        .accessibilityIdentifier("booking.open")
        // "Book again" reopens the instructor's full profile, not the booking sheet directly. No
        // distance here — there is no location fix in the bookings tab — so the profile omits it.
        .sheet(item: $route) { route in
            switch route {
            case .review:
                ReviewSheet(booking: booking)
            case .classmates:
                ClassmatesSheet(booking: booking)
            case .detail:
                BookingDetailView(booking: booking)
            }
        }
        // A .sheet and a .fullScreenCover are different presentation types, so they coexist — unlike two
        // .sheets, which shadow (see the Route comment above). "Book again" gets the full-screen profile.
        .fullScreenCover(item: $bookAgainInstructor) { ins in
            StudentInstructorProfileView(instructor: ins) { bookAgainInstructor = nil }
        }
        .confirmationDialog(cancelTitle,
                            isPresented: cancelDialogBinding, titleVisibility: .visible) {
            switch cancelKind {
            case .recurring:
                Button("Skip this week", role: .destructive) { data.cancel(booking) }
                Button("End series", role: .destructive) { data.endSeriesAsStudent(booking) }
                Button("Keep it", role: .cancel) { }
            default:
                Button("Cancel session", role: .destructive) { data.cancel(booking) }
                Button("Keep it", role: .cancel) { }
            }
        } message: {
            switch cancelKind {
            case .recurring:
                Text("Skip just this week and keep your weekly slot, or end the series to cancel all upcoming weeks. Past sessions stay.")
            default:
                Text("Your instructor will be notified that you can no longer make it.")
            }
        }
    }

    /// Title for the shared cancel dialog, chosen by the pending `cancelKind`.
    private var cancelTitle: String {
        switch cancelKind {
        case .recurring: return String(localized: "Cancel this weekly session?")
        default:         return String(localized: "Cancel this session?")
        }
    }

    private var cancelDialogBinding: Binding<Bool> {
        Binding(get: { cancelKind != nil }, set: { if !$0 { cancelKind = nil } })
    }

    // MARK: Header band

    private var header: some View {
        ZStack {
            Color.flowePinkPale

            FlowGradients.grad
                .opacity(0.5)

            if let instructor {
                RemoteImage(id: instructor.img, photo: instructor.photo, width: 600, height: 136)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .blendMode(.multiply)
                    .opacity(0.6)
            }

            HStack(spacing: 12) {
                if let instructor {
                    AvatarView(id: instructor.img, photo: instructor.photo, size: 40)
                        .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 2))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(instructor?.name ?? "")
                        .font(FloweFont.serif(14, .medium))
                        .foregroundStyle(.white)
                    (Text(localizedTag: booking.type) + Text(" · ") + Text("\(data.bookingDurationMinutes(booking)) min"))
                        .font(FloweFont.mono(11))
                        .foregroundStyle(.white.opacity(0.8))
                }

                Spacer(minLength: 8)

                // On the waitlist (an overflow seat on a full group class) the row reads "Waitlisted #N"
                // instead of the plain status badge; it auto-flips to Pending/Confirmed on promotion
                // (derived from the seat index — no stored state).
                if data.isWaitlisted(booking) {
                    WaitlistBadge(rank: data.waitlistRank(for: booking))
                } else {
                    StatusBadge(status: booking.status)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 68)
    }

    // MARK: Covered banner
    //
    // Informational only — v1 has no student decline. Their session still happens, just with a
    // stand-in, so the card says who without turning into an action.

    private func coveredBanner(_ session: RemoteCoverageSession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "airplane")
                .font(.system(size: 12))
                .foregroundStyle(Color.flowePinkDeep)
            Text("Covered by \(session.coveringInstructorName)")
                .font(FloweFont.sans(12, .medium))
                .foregroundStyle(Color.flowePinkDeep)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.flowePink.opacity(0.10))
    }

    // MARK: Body row

    private var bodyRow: some View {
        HStack {
            HStack(spacing: 12) {
                if booking.pendingUpload {
                    // Honest about delivery: the request hasn't reached the instructor yet.
                    metaLabel(icon: "arrow.clockwise", text: "Not sent yet")
                } else {
                    metaLabel(icon: "calendar", text: booking.localizedDate(locale))
                    metaLabel(icon: "clock", text: booking.localizedTime(locale))
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 14) {
                // ✦ Class-mates (Flowe Community) — see familiar faces in a group class; opt-in handled
                // inside the sheet. Shown for group bookings that aren't cancelled. See [[Flowe-Community]].
                if data.isGroupBooking(booking), booking.status != .cancelled {
                    Button { route = .classmates } label: {
                        Text("Class-mates")
                            .font(FloweFont.sans(11))
                            .foregroundStyle(Color.flowePinkDeep)
                    }
                    .accessibilityIdentifier("booking.classmates")
                }

                if booking.status == .completed {
                    if data.canReview(booking) {
                        Button {
                            route = .review
                        } label: {
                            Text(LocalizedStringKey(data.myReview(for: booking) == nil ? "Leave a review" : "Edit review"))
                                .font(FloweFont.sans(11))
                                .foregroundStyle(Color.flowePinkDeep)
                        }
                        .accessibilityIdentifier("booking.review")
                    }

                    Button {
                        if let instructor { bookAgainInstructor = instructor }
                    } label: {
                        Text("Book again")
                            .font(FloweFont.sans(11))
                            .foregroundStyle(Color.floweMuted)
                    }
                    .accessibilityIdentifier("booking.bookAgain")
                } else if booking.status != .cancelled {
                    // A waitlisted row leaves the waitlist (the same one-off cancel path — it releases
                    // the overflow hold via `releaseSeat`); everything else cancels the session.
                    Button {
                        cancelKind = Self.offersSeriesCancel(
                            isRecurring: booking.isRecurring, isWaitlisted: data.isWaitlisted(booking)
                        ) ? .recurring : .oneOff
                    } label: {
                        Text(data.isWaitlisted(booking) ? "Leave waitlist" : "Cancel")
                            .font(FloweFont.sans(11))
                            .foregroundStyle(Color.floweMuted)
                    }
                    .accessibilityIdentifier("booking.cancel")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // Standard Flowe press feedback for the row's action buttons (review / book again / cancel),
        // which were plain-styled and had none. Scoped to bodyRow so it never reaches the card's
        // sheet or confirmation-dialog buttons, which keep their system styling.
        .flowePressable()
    }

    private func metaLabel(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Color.floweMuted)
            Text(text)
                .font(FloweFont.sans(12))
                .foregroundStyle(Color.floweInk)
        }
    }
}

// MARK: - Booking detail sheet

/// The full-height detail for one booking, opened by tapping its card. The card's inline "Leave a
/// review" link is small and sits in a crowded action row that's easy to miss or fat-finger; here the
/// review is a full-width primary button on a calm surface. Also offers "Book again" and, for a group
/// class, "Class-mates". Cancellation stays on the card — its recurring-vs-one-off dialog lives there,
/// and a destructive action doesn't belong behind an extra tap.
private struct BookingDetailView: View {
    @Environment(MockDataStore.self) private var data
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    let booking: Booking

    /// One item-driven sheet, one route — the same single-presentation discipline the card uses.
    private enum Route: Identifiable {
        case review
        case classmates
        var id: String {
            switch self {
            case .review:             return "review"
            case .classmates:         return "classmates"
            }
        }
    }
    @State private var route: Route?
    @State private var bookAgainInstructor: Instructor?

    private var instructor: Instructor? { data.instructor(id: booking.instructorId) }

    private var coverSession: RemoteCoverageSession? {
        guard let id = booking.remoteID,
              let session = data.coverSession(forBookingID: id),
              session.status == 0 else { return nil }
        return session
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    instructorHeader
                    infoCard
                    if let coverSession {
                        infoRow(icon: "airplane",
                                text: String(localized: "Covered by \(coverSession.coveringInstructorName)"))
                    }
                    actions
                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            .background(Color.flowWarmCream.ignoresSafeArea())
            .navigationTitle("Booking details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Color.flowePinkDeep)
                }
            }
            .sheet(item: $route) { r in
                switch r {
                case .review:
                    ReviewSheet(booking: booking)
                case .classmates:
                    ClassmatesSheet(booking: booking)
                }
            }
            .fullScreenCover(item: $bookAgainInstructor) { ins in
                StudentInstructorProfileView(instructor: ins) { bookAgainInstructor = nil }
            }
        }
    }

    // MARK: Sections

    private var instructorHeader: some View {
        HStack(spacing: 14) {
            if let instructor {
                AvatarView(id: instructor.img, photo: instructor.photo, size: 56)
                    .overlay(Circle().stroke(Color.flowePinkSoft, lineWidth: 2))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(instructor?.name ?? "")
                    .font(FloweFont.serif(20, .medium))
                    .foregroundStyle(Color.floweInk)
                (Text(localizedTag: booking.type) + Text(" · ") + Text("\(data.bookingDurationMinutes(booking)) min"))
                    .font(FloweFont.mono(12))
                    .foregroundStyle(Color.floweMuted)
            }
            Spacer(minLength: 8)
            if data.isWaitlisted(booking) {
                WaitlistBadge(rank: data.waitlistRank(for: booking))
            } else {
                StatusBadge(status: booking.status)
            }
        }
    }

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if booking.pendingUpload {
                infoRow(icon: "arrow.clockwise", text: String(localized: "Not sent yet"))
            } else {
                infoRow(icon: "calendar", text: booking.localizedDate(locale))
                Divider().padding(.vertical, 12)
                infoRow(icon: "clock", text: booking.localizedTime(locale))
            }
            if booking.isRecurring {
                Divider().padding(.vertical, 12)
                infoRow(icon: "repeat", text: String(localized: "Repeats weekly"))
            }
        }
        .padding(16)
        .floweCard()
    }

    private func infoRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color.flowePinkDeep)
                .frame(width: 22)
            Text(text)
                .font(FloweFont.sans(15))
                .foregroundStyle(Color.floweInk)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(spacing: 12) {
            if booking.status == .completed {
                if data.canReview(booking) {
                    PrimaryButton(title: data.myReview(for: booking) == nil ? "Leave a review" : "Edit review") {
                        route = .review
                    }
                    .accessibilityIdentifier("bookingDetail.review")
                }
                secondaryButton("Book again", id: "bookingDetail.bookAgain") {
                    if let instructor { bookAgainInstructor = instructor }
                }
            }
            if data.isGroupBooking(booking), booking.status != .cancelled {
                secondaryButton("Class-mates", id: "bookingDetail.classmates") {
                    route = .classmates
                }
            }
        }
    }

    private func secondaryButton(_ title: LocalizedStringKey, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(FloweFont.sans(15, .medium))
                .foregroundStyle(Color.flowePinkDeep)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.flowePinkPale)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .flowePressable()
        .accessibilityIdentifier(id)
    }
}
