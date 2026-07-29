import SwiftUI

/// Out of Studio — the instructor's "I can't teach this window, find me cover" surface.
///
/// The flow is deliberately hands-off: the instructor picks a time window, the app lists their own
/// confirmed sessions that fall inside it, and for each one it has already ranked the nearby eligible
/// instructors on-device (`oosCandidates`). "Request cover" auto-fans one addressed offer to each of
/// those candidates — there is no hand-pick step, because CloudKit can't run a geo query and a manual
/// picker over a world-readable database would leak who teaches whom. Awarding a winner, and the 50%
/// cover-pay ledger, live on the dashboard (see `CoveragePickerView` / `CoverageInboxView`).
///
/// Owns a `LocationService` exactly like `DiscoverView`: the fix never leaves the device and only
/// feeds the distance term in the candidate ranking. Without a fix, ranking falls back to tier +
/// rating, so the screen works refused just as the feed does.
struct OutOfStudioView: View {
    @Environment(MockDataStore.self) private var data
    @Environment(\.dismiss) private var dismiss

    /// On-device only — hands out distances for candidate ranking, never coordinates (see DiscoverView).
    @State private var location = LocationService()

    /// The coverage window. Defaults to "now → end of day-ish": most out-of-studio calls are same-day
    /// ("I'm sick, cover today"), and the instructor widens it from there.
    @State private var windowStart = Date()
    @State private var windowEnd = Calendar.current.date(byAdding: .hour, value: 8, to: Date()) ?? Date()

    /// The instructor's confirmed, upcoming sessions that start inside the chosen window.
    private var sessions: [Booking] {
        data.sessionsToCoverInWindow(start: windowStart, end: windowEnd)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    windowCard
                    locationBar

                    if sessions.isEmpty {
                        emptyState
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(text: "SESSIONS IN THIS WINDOW")
                            ForEach(sessions) { sessionRow($0) }
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.flowWhite)
            .navigationTitle("Out of Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .tint(Color.flowePinkDeep)
                        .fontWeight(.semibold)
                }
            }
            // Only when already granted — never springs the prompt on open, matching Discover. The pill
            // below is what raises it.
            .task { if location.isAuthorized { await location.refresh() } }
        }
    }

    // MARK: - Window

    private var windowCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("WHEN ARE YOU OUT?")
                    .font(FloweFont.mono(11))
                    .foregroundStyle(Color.floweMuted)
                Text("We'll find cover for every session that starts in this window.")
                    .font(FloweFont.sans(12))
                    .foregroundStyle(Color.floweMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DatePicker("From", selection: $windowStart, displayedComponents: [.date, .hourAndMinute])
                .font(FloweFont.sans(14))
            DatePicker("Until", selection: $windowEnd, in: windowStart...,
                       displayedComponents: [.date, .hourAndMinute])
                .font(FloweFont.sans(14))
        }
        .tint(Color.flowePinkDeep)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .floweCard(cornerRadius: 16)
    }

    // MARK: - Location opt-in
    //
    // Optional: candidate ranking works refused (tier + rating), a fix just adds the distance term.
    // So this is a quiet nudge, never a gate — no denied/settings branch, that lives in Discover.

    @ViewBuilder
    private var locationBar: some View {
        if !location.hasFix, !location.isDenied {
            Button {
                Task { await location.refresh() }
            } label: {
                HStack(spacing: 6) {
                    if location.isLocating {
                        ProgressView().controlSize(.mini).tint(Color.flowePinkDeep)
                    } else {
                        Image(systemName: "location").font(.system(size: 10))
                    }
                    Text("Rank cover by distance").font(FloweFont.sans(12, .medium))
                }
                .foregroundStyle(Color.flowePinkDeep)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.flowePink.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .disabled(location.isLocating)
        }
    }

    // MARK: - Session row

    @ViewBuilder
    private func sessionRow(_ booking: Booking) -> some View {
        let candidates = data.oosCandidates(for: booking, location: location)
        let requested = booking.coverRole == .handedOff
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AvatarView(id: "", photo: data.studentPhoto(forOwnerID: booking.studentID ?? ""), size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(booking.studentName.isEmpty ? "Client" : booking.studentName)
                        .font(FloweFont.serif(15))
                        .foregroundStyle(Color.floweInk)
                    Text("\(booking.date) · \(booking.time) · \(booking.type)")
                        .font(FloweFont.sans(12))
                        .foregroundStyle(Color.floweMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Button {
                data.requestCoverage(for: booking,
                                     windowStart: windowStart,
                                     windowEnd: windowEnd,
                                     candidates: candidates)
            } label: {
                Text(coverLabel(requested: requested, count: candidates.count))
                    .font(FloweFont.sans(13, .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(requested ? Color.floweMuted : .white)
                    .background(requested ? AnyShapeStyle(Color.floweCardBg)
                                          : AnyShapeStyle(FlowGradients.gradDark),
                                in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            // Nothing to fan out to, or already handed off: the button is inert either way.
            .disabled(requested || candidates.isEmpty)
        }
        .padding(14)
        .floweCard(cornerRadius: 14)
    }

    /// The offer button's copy: how many nearby instructors will be notified, or that it's done.
    private func coverLabel(requested: Bool, count: Int) -> String {
        if requested { return "Cover requested" }
        if count == 0 { return "No one available nearby" }
        return count == 1 ? "Request cover · 1 nearby" : "Request cover · \(count) nearby"
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: "airplane",
            title: "No sessions in this window",
            message: "Widen the window above to cover more of your schedule. Only confirmed, upcoming sessions can be handed off."
        )
        .padding(.top, 40)
    }
}

// MARK: - Owner picker (award a winner)

/// The out-of-studio owner's picker: every session they've requested cover for, and the instructors
/// who claimed it. Awarding flips `CoverageRequest.filledByID` (the owner's own record — their half of
/// the two-sided approval) and writes the student a `CoverageSession`; the local cover-pay ledger is
/// materialised on this side too. Last write wins, so re-awarding just moves the winner.
struct CoveragePickerView: View {
    @Environment(MockDataStore.self) private var data
    @Environment(\.dismiss) private var dismiss

    /// Open requests only — a filled or cancelled one has nothing left to decide.
    private var requests: [RemoteCoverageRequest] {
        data.myCoverRequests.filter { $0.status == 0 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if requests.isEmpty {
                        EmptyStateView(
                            icon: "person.2.slash",
                            title: "No open requests",
                            message: "When you request cover for a session, the instructors who claim it show up here to pick from."
                        )
                        .padding(.top, 40)
                    } else {
                        ForEach(requests, id: \.bookingID) { requestBlock($0) }
                    }
                }
                .padding(20)
            }
            .background(Color.flowWhite)
            .navigationTitle("Pick your cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .tint(Color.flowePinkDeep)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private func requestBlock(_ request: RemoteCoverageRequest) -> some View {
        let claims = data.myClaims.filter { $0.bookingID == request.bookingID }
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: "\(request.sessionDate) · \(request.sessionType)")
            if claims.isEmpty {
                Text("Waiting on a claim — nearby instructors have been notified.")
                    .font(FloweFont.sans(12))
                    .foregroundStyle(Color.floweMuted)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .floweCard(cornerRadius: 14)
            } else {
                ForEach(claims, id: \.replacerID) { claimRow($0, in: request) }
            }
        }
    }

    private func claimRow(_ claim: RemoteCoverageClaim, in request: RemoteCoverageRequest) -> some View {
        let awarded = request.filledByID == claim.replacerID
        return HStack(spacing: 12) {
            AvatarView(id: "", photo: nil, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(claim.replacerName.isEmpty ? "Instructor" : claim.replacerName)
                    .font(FloweFont.serif(15))
                    .foregroundStyle(Color.floweInk)
                Text(awarded ? "Awarded" : "Available to cover")
                    .font(FloweFont.mono(10))
                    .foregroundStyle(awarded ? Color.floweSuccess : Color.floweMuted)
            }
            Spacer(minLength: 8)
            Button {
                data.awardCoverage(bookingID: claim.bookingID,
                                   replacerID: claim.replacerID,
                                   replacerName: claim.replacerName,
                                   studentID: studentID(for: request))
            } label: {
                Text(awarded ? "Winner" : "Award")
                    .font(FloweFont.sans(13, .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .foregroundStyle(awarded ? Color.floweMuted : .white)
                    .background(awarded ? AnyShapeStyle(Color.floweCardBg)
                                        : AnyShapeStyle(FlowGradients.gradDark),
                                in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(awarded)
        }
        .padding(14)
        .floweCard(cornerRadius: 14)
    }

    /// The student the cover session must be addressed to — resolved from the local booking the request
    /// was raised for (the request itself never carries a studentID, by privacy design).
    private func studentID(for request: RemoteCoverageRequest) -> String {
        data.incomingBookings.first { $0.remoteID == request.bookingID }?.studentID ?? ""
    }
}

// MARK: - Replacer inbox (claim + 50% cover pay)

/// The covering instructor's side: sessions nearby that need cover (inbound `CoverageOffer`s) they can
/// claim, and — reusing the No-Show Shield layout exactly — the running tally of 50% cover pay owed to
/// them, collected off-app. Claiming writes a `CoverageClaim(accepted=1)`, the replacer's half of the
/// two-sided approval; the owner still has to award them.
struct CoverageInboxView: View {
    @Environment(MockDataStore.self) private var data
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    private var offers: [RemoteCoverageOffer] { data.myOffers }
    private var owed: [Booking] { data.coverOwed }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    owedHeader

                    if !offers.isEmpty {
                        section("SESSIONS NEEDING COVER") { ForEach(offers, id: \.bookingID) { offerRow($0) } }
                    }
                    if !owed.isEmpty {
                        section("COVER PAY OWED") { ForEach(owed) { owedRow($0) } }
                    }
                    if offers.isEmpty && owed.isEmpty { emptyState }
                }
                .padding(20)
            }
            .background(Color.flowWhite)
            .navigationTitle("Cover for others")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .tint(Color.flowePinkDeep)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: Owed header (cloned from NoShowShieldView.owedHeader)

    private var owedHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("COVER PAY OWED TO YOU")
                .font(FloweFont.mono(11))
                .foregroundStyle(Color.floweMuted)
            Text(settings.money(data.totalCoverOwed))
                .font(FloweFont.serif(34, .medium))
                .foregroundStyle(data.totalCoverOwed > 0 ? Color.flowePinkDeep : Color.floweInk)
            Text("Half the session price for every cover you teach — settled directly with the instructor. Flowe only keeps the tally.")
                .font(FloweFont.sans(12))
                .foregroundStyle(Color.floweMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .floweCard(cornerRadius: 16)
    }

    // MARK: Rows

    private func offerRow(_ offer: RemoteCoverageOffer) -> some View {
        let claimed = data.myClaims.contains { $0.bookingID == offer.bookingID }
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(offer.sessionType)
                    .font(FloweFont.serif(15))
                    .foregroundStyle(Color.floweInk)
                Text(offer.sessionDate)
                    .font(FloweFont.sans(12))
                    .foregroundStyle(Color.floweMuted)
            }
            Button {
                data.claimCoverage(bookingID: offer.bookingID, requesterID: offer.requesterID, accept: true)
            } label: {
                Text(claimed ? "Claimed — awaiting pick" : "Claim this cover")
                    .font(FloweFont.sans(13, .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(claimed ? Color.floweMuted : .white)
                    .background(claimed ? AnyShapeStyle(Color.floweCardBg)
                                        : AnyShapeStyle(FlowGradients.gradDark),
                                in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(claimed)
        }
        .padding(14)
        .floweCard(cornerRadius: 14)
    }

    private func owedRow(_ booking: Booking) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(booking.type)
                        .font(FloweFont.serif(15))
                        .foregroundStyle(Color.floweInk)
                    Text("\(booking.date) · \(booking.time)")
                        .font(FloweFont.sans(12))
                        .foregroundStyle(Color.floweMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(settings.money(booking.coverAmount))
                    .font(FloweFont.serif(17, .medium))
                    .foregroundStyle(Color.flowePinkDeep)
            }
            HStack(spacing: 10) {
                Button { data.resolveCover(booking, to: .collected) } label: {
                    Text("Collected")
                        .font(FloweFont.sans(13, .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(FlowGradients.gradDark, in: RoundedRectangle(cornerRadius: 12))
                }
                Button { data.resolveCover(booking, to: .waived) } label: {
                    Text("Waive")
                        .font(FloweFont.sans(13, .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(Color.floweMuted)
                        .background(Color.floweCardBg, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .floweCard(cornerRadius: 14)
    }

    // MARK: Pieces

    @ViewBuilder
    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: title)
            content()
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: "airplane",
            title: "Nothing to cover",
            message: "When an instructor near you goes out of studio, their open sessions show up here to claim."
        )
        .padding(.top, 40)
    }
}

#Preview {
    OutOfStudioView()
        .environment(MockDataStore.preview)
        .environment(AppSettings())
}
