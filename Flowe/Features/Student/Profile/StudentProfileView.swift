import SwiftUI

/// The instructor-facing, read-only, Instagram-style look at a STUDENT — the mirror of
/// `StudentInstructorProfileView`, pared down to what an instructor is allowed to see. It reuses that
/// screen's skeleton exactly (full-bleed hero, an identity card overlapping the hero's lower edge, an
/// honest stat trio, a conditional section stack, a pinned bottom action rail) and is presented as a
/// sheet / full-screen cover with an `onClose` closure, the same as its instructor counterpart.
///
/// Two data sources, kept strictly separate:
///  • PUBLIC — the student's own authored profile (`data.studentProfile(forOwnerID:)`, refreshed by the
///    NON-pruning `syncStudentProfile(ownerID:)`): photo, name, "Member since", bio. Absent (no cached
///    row yet) → placeholder hero + the passed-in `studentName`, never a crash.
///  • RELATIONSHIP CONTEXT — computed ONLY from the viewing instructor's own bookings
///    (`data.incomingBookings.filter { $0.studentID == studentID }`), never the student's private
///    global stats: sessions-with-you (completed), the next upcoming session, the last completed one.
///
/// There is deliberately NO report / block menu here — moderating a student already lives in
/// `ConversationView`. The single primary action is Message.
struct StudentProfileView: View {
    let studentID: String
    /// Passed-in name, used as the fallback when no public profile row is cached yet (and to derive a
    /// first name for the Message button before the profile loads).
    let studentName: String
    /// Invoked by the Message CTA. Nil at call sites that only want to view (falls back to `onClose`).
    var onMessage: (() -> Void)? = nil
    let onClose: () -> Void

    @Environment(MockDataStore.self) private var data

    // MARK: - Resolved data

    /// The student's cached public profile, or nil until the first fetch lands.
    private var profile: StudentProfile? { data.studentProfile(forOwnerID: studentID) }

    /// The instructor's OWN bookings with this student — the sole source of relationship context.
    private var mySessions: [Booking] {
        data.incomingBookings.filter { $0.studentID == studentID }
    }

    /// Completed sessions this instructor has actually taught this student.
    private var sessionsWithYou: Int {
        mySessions.filter { $0.status == .completed }.count
    }

    /// The soonest still-to-happen session, earliest by reconstructed end time. Unparseable bookings
    /// drop out (compactMap on `sessionEnd()`), so a session we can't date never masquerades as "next".
    private var nextSession: Booking? {
        mySessions
            .filter { $0.status.isUpcoming }
            .compactMap { booking in booking.sessionEnd().map { (booking, $0) } }
            .min { $0.1 < $1.1 }?
            .0
    }

    /// The most recent completed session, latest by reconstructed end time.
    private var lastSession: Booking? {
        mySessions
            .filter { $0.status == .completed }
            .compactMap { booking in booking.sessionEnd().map { (booking, $0) } }
            .max { $0.1 < $1.1 }?
            .0
    }

    /// Display name: the authored profile name when present, else the passed-in fallback.
    private var displayName: String {
        if let name = profile?.name, !name.isEmpty { return name }
        return studentName
    }

    /// First name for the Message CTA — the profile's own derivation when loaded, else split locally.
    private var firstName: String {
        if let first = profile?.firstName, !first.isEmpty { return first }
        return studentName.split(separator: " ").first.map(String.init) ?? studentName
    }

    /// Year the student joined, or nil when unknown (no row cached, or a distant-past sentinel).
    private var memberSinceYear: String? {
        guard let joined = profile?.memberSince, joined != .distantPast else { return nil }
        return Self.yearFormatter.string(from: joined)
    }

    // MARK: - Body

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
                }
                .padding(.bottom, 24)
            }
            .ignoresSafeArea(edges: .top)
            .background(Color.flowWhite)
            .navigationBarHidden(true)
            .safeAreaInset(edge: .bottom) { actionRail }
        }
        .presentationDragIndicator(.hidden)   // the hero owns a custom xmark; no grabber over the photo
        .accessibilityIdentifier("student.profile")
        .task {
            // Non-pruning single fetch — it can only insert or update this student's row, never delete
            // the one this open view is rendering.
            await data.syncStudentProfile(ownerID: studentID)
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
        if let photo = profile?.photo {
            RemoteImage(id: "", photo: photo, width: 800, height: 600)
        } else {
            // No uploaded photo → the designed empty state (flat gradient + watermark), matching the
            // instructor hero, not a failed-load blank.
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
            // The name set large in Fraunces, white, over the darkened photo — the striking move
            // borrowed from the instructor profile.
            Text(displayName)
                .font(FloweFont.serif(30, .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .shadow(color: Color.floweInk.opacity(0.35), radius: 8, y: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    /// "STUDENT", plus "· N sessions with you" once there is any completed history. Built from separate
    /// `Text` runs so the system lays it out bidirectionally rather than baking a fixed order.
    private var metaText: Text {
        var run = Text("STUDENT")
        if sessionsWithYou > 0 {
            run = run + Text(verbatim: " · ")
                + Text("^[\(sessionsWithYou) session](inflect: true) with you")
        }
        return run
    }

    private var heroButtons: some View {
        // A single ultraThinMaterial circle xmark — no moderation menu (reporting/blocking a student
        // lives in ConversationView, not here).
        Button { onClose() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.floweInk)
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Close"))
        .padding(.horizontal, 16)
        // Push clear of the status bar — the hero ignores the top safe area.
        .padding(.top, 56)
    }

    // MARK: - Identity card

    private var identityCard: some View {
        HStack(spacing: 12) {
            AvatarView(id: "", photo: profile?.photo, size: 44, ring: true)

            VStack(alignment: .leading, spacing: 2) {
                Text("STUDENT")
                    .font(FloweFont.mono(9))
                    .foregroundStyle(Color.floweMuted)
                Text(displayName)
                    .font(FloweFont.sans(15, .medium))
                    .foregroundStyle(Color.floweInk)
                    .lineLimit(1)
                if let year = memberSinceYear {
                    Text("Member since \(year)")
                        .font(FloweFont.sans(11))
                        .foregroundStyle(Color.floweMuted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(16)
        .floweCard(cornerRadius: 18)
        .padding(.horizontal, 20)
    }

    // MARK: - Stat trio

    /// Three honest tiles — every unknown renders an em dash on a muted accent, never a fabricated 0.
    private var statTrio: some View {
        HStack(spacing: 12) {
            StatTile(value: sessionsWithYou > 0 ? "\(sessionsWithYou)" : "—",
                     label: "WITH YOU",
                     accent: sessionsWithYou > 0 ? .flowePinkDeep : .floweMuted)

            StatTile(value: nextSession.map(shortDate) ?? "—",
                     label: "NEXT",
                     accent: nextSession != nil ? .flowePinkDeep : .floweMuted)

            StatTile(value: memberSinceYear ?? "—",
                     label: "SINCE",
                     accent: memberSinceYear != nil ? .flowePinkDeep : .floweMuted)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Sections

    /// Conditional blocks — a sparse profile still reads as a finished screen rather than a form with
    /// holes: an empty field yields no empty block.
    private var sections: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let bio = profile?.bio, !bio.isEmpty {
                section("ABOUT") {
                    Text(bio)
                        .font(FloweFont.sans(15))
                        .foregroundStyle(Color.floweInk)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            yourHistory
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    private func section<Content: View>(_ title: LocalizedStringKey,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(text: title)
            content()
        }
    }

    /// The instructor's shared history with this student — explicitly "with you", drawn only from the
    /// instructor's own bookings, never the student's global activity. Shown only when there is a real
    /// last or next session to name (a relationship of only cancelled sessions shows nothing).
    @ViewBuilder
    private var yourHistory: some View {
        if lastSession != nil || nextSession != nil {
            section("YOUR HISTORY") {
                VStack(alignment: .leading, spacing: 8) {
                    if let last = lastSession {
                        historyRow(icon: "clock.arrow.circlepath",
                                   label: "Last session · \(last.date)")
                    }
                    if let next = nextSession {
                        historyRow(icon: "calendar",
                                   label: "Next session · \(next.date)")
                    }
                }
            }
        }
    }

    private func historyRow(icon: String, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color.flowePinkDeep)
            // `label` mixes a localized prefix with the booking's language-neutral display date, so it
            // is assembled at the call site and shown verbatim here.
            Text(verbatim: label)
                .font(FloweFont.sans(14))
                .foregroundStyle(Color.floweInk)
        }
    }

    // MARK: - Action rail

    /// The single primary action. Message returns the instructor to the thread (or simply closes when
    /// no handler was supplied).
    private var actionRail: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.floweBorder).frame(height: 1)
            VStack(spacing: 8) {
                GradientButton(title: "Message \(firstName)") {
                    onMessage?() ?? onClose()
                }
                .accessibilityIdentifier("student.message")
                Text("Only you can see your history together.")
                    .font(FloweFont.mono(9))
                    .foregroundStyle(Color.floweMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
        }
        .background(Color.flowWhite)
    }

    // MARK: - Formatting

    /// Compact date for the NEXT stat tile — the booking's own display date with the weekday dropped
    /// ("Thu, Jul 17" → "Jul 17"), keeping the tile short without reparsing into a real timestamp.
    private func shortDate(_ booking: Booking) -> String {
        booking.date.split(separator: ",").last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? booking.date
    }

    private static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy"
        return f
    }()
}
