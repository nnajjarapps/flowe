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
        case bookAgain(Instructor)
        case review
        var id: String {
            switch self {
            case .bookAgain(let ins): return "book-\(ins.legacyId)"
            case .review:             return "review"
            }
        }
    }

    /// The cancel confirmation is ONE dialog driven by this enum (a second `.confirmationDialog` shadows
    /// the first, the same trap as `.sheet`). One-off → `.oneOff`; a standing week → `.skip` (this week
    /// only) or `.endSeries` (all future weeks).
    private enum CancelKind { case oneOff, skip, endSeries }
    @State private var route: Route?
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
        // "Book again" reopens the instructor's full profile, not the booking sheet directly. No
        // distance here — there is no location fix in the bookings tab — so the profile omits it.
        .sheet(item: $route) { route in
            switch route {
            case .bookAgain(let ins):
                StudentInstructorProfileView(instructor: ins) { self.route = nil }
            case .review:
                ReviewSheet(booking: booking)
            }
        }
        .confirmationDialog(cancelTitle,
                            isPresented: cancelDialogBinding, titleVisibility: .visible) {
            switch cancelKind {
            case .skip:
                Button("Skip this week", role: .destructive) { data.cancel(booking) }
                Button("Keep it", role: .cancel) { }
            case .endSeries:
                Button("End series", role: .destructive) { data.endSeriesAsStudent(booking) }
                Button("Keep it", role: .cancel) { }
            default:
                Button("Cancel session", role: .destructive) { data.cancel(booking) }
                Button("Keep it", role: .cancel) { }
            }
        } message: {
            switch cancelKind {
            case .skip:
                Text("This cancels only this week. Your weekly slot stays booked.")
            case .endSeries:
                Text("This cancels all upcoming weeks. Past sessions stay.")
            default:
                Text("Your instructor will be notified that you can no longer make it.")
            }
        }
    }

    /// Title for the shared cancel dialog, chosen by the pending `cancelKind`.
    private var cancelTitle: String {
        switch cancelKind {
        case .skip:      return String(localized: "Skip just this week?")
        case .endSeries: return String(localized: "End this weekly series?")
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
                    (Text(localizedTag: booking.type) + Text(" · ") + Text("\(booking.durationMinutes) min"))
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

            if booking.status == .completed {
                HStack(spacing: 14) {
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
                        if let instructor { route = .bookAgain(instructor) }
                    } label: {
                        Text("Book again")
                            .font(FloweFont.sans(11))
                            .foregroundStyle(Color.floweMuted)
                    }
                    .accessibilityIdentifier("booking.bookAgain")
                }
            } else if booking.status != .cancelled {
                // A waitlisted row leaves the waitlist (the same one-off cancel path — it releases
                // the overflow hold via `releaseSeat`); everything else cancels the session.
                Button {
                    cancelKind = .oneOff
                } label: {
                    Text(data.isWaitlisted(booking) ? "Leave waitlist" : "Cancel")
                        .font(FloweFont.sans(11))
                        .foregroundStyle(Color.floweMuted)
                }
                .accessibilityIdentifier("booking.cancel")
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
