import SwiftUI
import CoreLocation

/// Out of Studio — the instructor's "I can't teach this window, find me cover" surface.
///
/// The flow is deliberately hands-off: the instructor picks a time window, the app lists their own
/// confirmed sessions that fall inside it, and for each one it has already ranked the nearby eligible
/// instructors on-device (`oosCandidates`). "Request cover" auto-fans one addressed offer to each of
/// those candidates — there is no hand-pick step, because CloudKit can't run a geo query and a manual
/// picker over a world-readable database would leak who teaches whom. Awarding a winner, and the 50%
/// cover-pay ledger, live on the dashboard (see `CoveragePickerView` / `CoverageInboxView`).
///
/// Distance is measured from the instructor's own published **studio location** (their exact studio
/// coordinate — where the session actually happens), never the device's live GPS fix. That studio
/// location is the source of truth for both the candidate ranking and the "SEARCH RADIUS" cutoff. With
/// no studio location published, ranking falls back to tier + rating so the screen still works.
struct OutOfStudioView: View {
    @Environment(MockDataStore.self) private var data
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    // The coverage window now lives in AppSettings (persisted, mirrors coverageRadiusKm) so the chosen
    // From/Until survive closing the sheet; `rollForwardWindowIfStale` freshens a past window on appear
    // while preserving its DURATION.

    /// The session whose cover-candidate picker is open — the manual "pick who to ask" sheet.
    @State private var pickerTarget: Booking?

    /// Sessions the instructor just tapped "Request cover" on, keyed by `booking.remoteID`. Optimistic:
    /// the CloudKit publish + fan-out is async (and a whole no-op in the seeded sim), so the button had
    /// no way to acknowledge the tap — its only "requested" signal was `coverRole`, which is set at
    /// *award* time, not request time. This flips the button instantly and reconciles with the synced
    /// open requests (`data.myCoverRequests`) once the round-trip lands.
    @State private var requestedIDs: Set<String> = []

    /// The session whose cover request is pending cancellation (drives the confirm dialog).
    @State private var cancelTarget: Booking?

    /// The instructor's confirmed, upcoming sessions that start inside the chosen window.
    private var sessions: [Booking] {
        data.sessionsToCoverInWindow(start: settings.oosWindowStart, end: settings.oosWindowEnd)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    windowCard
                    radiusCard

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
            // Cancelling withdraws the offers from every instructor you asked, and lets you re-request
            // (e.g. for a different date). Confirmed because those instructors already saw it.
            .confirmationDialog("Cancel this cover request?",
                                isPresented: Binding(get: { cancelTarget != nil },
                                                     set: { if !$0 { cancelTarget = nil } }),
                                titleVisibility: .visible,
                                presenting: cancelTarget) { booking in
                Button("Cancel request", role: .destructive) {
                    if let id = booking.remoteID { requestedIDs.remove(id) }
                    data.cancelCoverage(for: booking)
                    cancelTarget = nil
                }
                Button("Keep it", role: .cancel) { cancelTarget = nil }
            } message: { _ in
                Text("The instructors you asked will no longer see it. You can request cover again after.")
            }
            .onAppear { rollForwardWindowIfStale() }
            .sheet(item: $pickerTarget) { booking in
                CoverageCandidatePicker(
                    candidates: data.oosCandidates(for: booking, radiusKm: settings.coverageRadiusKm),
                    origin: data.currentInstructor?.studioCoordinate
                ) { selected in requestCover(for: booking, to: selected) }
            }
        }
    }

    // MARK: - Window

    private var windowCard: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("WHEN ARE YOU OUT?")
                    .font(FloweFont.mono(11))
                    .foregroundStyle(Color.floweMuted)
                Text("We'll find cover for every session that starts in this window. Your window is saved.")
                    .font(FloweFont.sans(12))
                    .foregroundStyle(Color.floweMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DatePicker("From", selection: $settings.oosWindowStart, displayedComponents: [.date, .hourAndMinute])
                .font(FloweFont.sans(14))
            DatePicker("Until", selection: $settings.oosWindowEnd, in: settings.oosWindowStart...,
                       displayedComponents: [.date, .hourAndMinute])
                .font(FloweFont.sans(14))
        }
        .tint(Color.flowePinkDeep)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .floweCard(cornerRadius: 16)
    }

    // MARK: - Search radius
    //
    // How far the coverage fan-out reaches, measured from the instructor's STUDIO LOCATION (not the
    // device) — see `oosCandidates`. Bites only when a studio location is published; with none, ranking
    // runs over everyone. Persisted in AppSettings, clamped there to a 1–100 km band.

    private var radiusCard: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SEARCH RADIUS")
                    .font(FloweFont.mono(11))
                    .foregroundStyle(Color.floweMuted)
                Text("Only instructors within this distance of your studio location are offered your session.")
                    .font(FloweFont.sans(12))
                    .foregroundStyle(Color.floweMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Stepper(value: $settings.coverageRadiusKm,
                    in: AppSettings.minCoverageRadiusKm...AppSettings.maxCoverageRadiusKm,
                    step: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "scope").font(.system(size: 12)).foregroundStyle(Color.flowePinkDeep)
                    Text("\(Int(settings.coverageRadiusKm)) km")
                        .font(FloweFont.sans(15, .medium))
                        .foregroundStyle(Color.floweInk)
                        .contentTransition(.numericText())
                }
            }
            .tint(Color.flowePinkDeep)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .floweCard(cornerRadius: 16)
    }

    // MARK: - Session row

    @ViewBuilder
    private func sessionRow(_ booking: Booking) -> some View {
        let candidates = data.oosCandidates(for: booking, radiusKm: settings.coverageRadiusKm)
        let coverID = booking.remoteID
        let arranged = booking.coverRole == .handedOff   // a winner was awarded — past the cancel window here
        // An OPEN request: the DURABLE persisted flag (survives re-open) OR the optimistic tap flag OR a
        // synced request that isn't cancelled/filled. Status 0 only, so a cancelled request (status 2,
        // still returned by the fetch) correctly reads as not-requested. `.requested` is reconciled away
        // in `syncCoverage` once the server shows the request cancelled/filled.
        let requestedOpen = !arranged && (
            booking.coverRole == .requested
            || (coverID.map { id in
                requestedIDs.contains(id) || data.myCoverRequests.contains { $0.bookingID == id && $0.status == 0 }
            } ?? false)
        )
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AvatarView(id: "", photo: data.studentPhoto(forOwnerID: booking.studentID ?? ""), size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(booking.studentName.isEmpty ? "Client" : booking.studentName)
                        .font(FloweFont.serif(15))
                        .foregroundStyle(Color.floweInk)
                    (Text(booking.localizedDate(locale)) + Text(" · ") + Text(booking.localizedTime(locale)) + Text(" · ") + Text(localizedTag: booking.type))
                        .font(FloweFont.sans(12))
                        .foregroundStyle(Color.floweMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if arranged {
                statusPill("Cover arranged")
            } else if requestedOpen {
                // Requested but not yet awarded → show the state AND let the owner cancel/withdraw it.
                HStack(spacing: 10) {
                    statusPill("Cover requested")
                    Button {
                        cancelTarget = booking
                    } label: {
                        Text("Cancel")
                            .font(FloweFont.sans(13, .medium))
                            .foregroundStyle(Color.floweCancel)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.floweCancel.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("oos.cancelRequest")
                }
            } else {
                Button {
                    pickerTarget = booking          // open the manual "pick who to ask" sheet
                } label: {
                    Text(coverLabel(requested: false, count: candidates.count))
                        .font(FloweFont.sans(13, .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(FlowGradients.gradDark, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(candidates.isEmpty)
            }
        }
        .padding(14)
        .floweCard(cornerRadius: 14)
    }

    /// A neutral status chip filling the row's action slot (requested / arranged).
    private func statusPill(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(FloweFont.sans(13, .medium))
            .foregroundStyle(Color.floweMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color.floweCardBg, in: RoundedRectangle(cornerRadius: 12))
    }

    /// The offer button's copy: how many nearby instructors will be notified, or that it's done.
    private func coverLabel(requested: Bool, count: Int) -> String {
        if requested { return "Cover requested" }
        if count == 0 { return "No one available nearby" }
        return count == 1 ? "Request cover · 1 nearby" : "Request cover · \(count) nearby"
    }

    /// Send the cover request to the instructors the owner hand-picked in the sheet (was an auto fan-out
    /// to every candidate). Optimistically flips the row to "Cover requested" before the network lands.
    private func requestCover(for booking: Booking, to selected: [Instructor]) {
        guard !selected.isEmpty else { return }
        if let id = booking.remoteID { requestedIDs.insert(id) }
        data.requestCoverage(for: booking,
                             windowStart: settings.oosWindowStart,
                             windowEnd: settings.oosWindowEnd,
                             candidates: selected)
    }

    /// A saved window whose end is already in the past is useless — roll it to start now, KEEPING the
    /// duration the instructor set, so the persisted window stays actionable across days.
    private func rollForwardWindowIfStale() {
        guard settings.oosWindowEnd <= Date() else { return }
        let duration = max(settings.oosWindowEnd.timeIntervalSince(settings.oosWindowStart), 3600)
        settings.oosWindowStart = Date()
        settings.oosWindowEnd = Date().addingTimeInterval(duration)
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

// MARK: - Cover-candidate picker (manual: choose WHO to ask)

/// The instructor hand-picks which nearby instructors to ask to cover a session — replacing the old
/// auto-fan-out to every candidate. Candidates arrive pre-ranked by distance from `oosCandidates`; only
/// the selected instructors are notified. Distance shows when both studios publish a coordinate.
struct CoverageCandidatePicker: View {
    @Environment(\.dismiss) private var dismiss
    let candidates: [Instructor]
    let origin: CLLocationCoordinate2D?
    let onRequest: ([Instructor]) -> Void

    @State private var selected: Set<String> = []

    private var chosen: [Instructor] {
        candidates.filter { $0.ownerID.map(selected.contains) ?? false }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pick the instructors you want to ask. Only the ones you select are notified — no one else sees your request.")
                        .font(FloweFont.sans(13))
                        .foregroundStyle(Color.floweMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    if candidates.isEmpty {
                        EmptyStateView(icon: "person.2.slash",
                                       title: "No instructors nearby",
                                       message: "Widen your search radius, or check back — no eligible instructors are within range right now.")
                            .padding(.top, 30)
                    } else {
                        ForEach(candidates, id: \.legacyId) { candidateRow($0) }
                    }
                }
                .padding(20)
            }
            .background(Color.flowWhite)
            .navigationTitle("Request cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Color.floweMuted)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !candidates.isEmpty {
                    Button {
                        onRequest(chosen)
                        dismiss()
                    } label: {
                        Text(sendLabel)
                            .font(FloweFont.sans(15, .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundStyle(.white)
                            .background(FlowGradients.gradDark, in: RoundedRectangle(cornerRadius: 14))
                            .opacity(selected.isEmpty ? 0.5 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(selected.isEmpty)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .background(.ultraThinMaterial)
                }
            }
        }
    }

    private var sendLabel: LocalizedStringKey {
        selected.isEmpty ? "Select instructors to ask"
                         : "^[Request cover from \(selected.count) instructor](inflect: true)"
    }

    @ViewBuilder
    private func candidateRow(_ ins: Instructor) -> some View {
        let isOn = ins.ownerID.map(selected.contains) ?? false
        Button {
            guard let id = ins.ownerID else { return }
            if isOn { selected.remove(id) } else { selected.insert(id) }
            Haptic.selection()
        } label: {
            HStack(spacing: 12) {
                AvatarView(id: "", photo: ins.photo, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ins.name.isEmpty ? "Instructor" : ins.name)
                        .font(FloweFont.serif(15)).foregroundStyle(Color.floweInk).lineLimit(1)
                    if let sub = subtitle(ins) {
                        Text(verbatim: sub).font(FloweFont.sans(12)).foregroundStyle(Color.floweMuted).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isOn ? Color.flowePinkDeep : Color.floweMuted.opacity(0.45))
            }
            .padding(14)
            .floweCard(cornerRadius: 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ins.name.isEmpty ? "Instructor" : ins.name)
        .accessibilityValue(isOn ? "Selected" : "Not selected")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// Distance (when both studios have a coordinate) + rating — the "nearby" signal.
    private func subtitle(_ ins: Instructor) -> String? {
        var parts: [String] = []
        if let o = origin, let c = ins.studioCoordinate {
            let m = CLLocation(latitude: o.latitude, longitude: o.longitude)
                .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            parts.append(m < 1000 ? "\(Int(m)) m away" : String(format: "%.1f km away", m / 1000))
        }
        if ins.reviews > 0 { parts.append(String(format: "★ %.1f", ins.rating)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
            .refreshable { await data.syncCoverage(asInstructor: true) }
            .task {
                // Pull fresh requests + claims on open, so a claim just filed from the OTHER instructor's
                // device shows up here — not only after the last dashboard-appear sync. This is what makes
                // the owner see (and be able to award) an inbound claim as soon as they open the picker.
                await data.syncCoverage(asInstructor: true)
                // Warm each claimant's listing so `claimRow` can show their real name + photo (a claim
                // only carries an id + a frozen name; the catalog cache holds the current identity).
                let replacerIDs = Set(requests.flatMap { req in
                    data.myClaims.filter { $0.bookingID == req.bookingID }.map(\.replacerID)
                })
                for id in replacerIDs where data.instructor(ownerID: id) == nil {
                    _ = await data.loadInstructor(ownerID: id)
                }
            }
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
        // Resolve the replacer's CURRENT listing — name, photo and avatar — instead of a blank avatar and
        // the frozen/empty claim name (which rendered as "Instructor" with no picture). Warmed in the
        // view's `.task` via `loadInstructor`.
        let who = data.displayIdentity(ownerID: claim.replacerID, fallbackName: claim.replacerName)
        let name = who.name.isEmpty ? String(localized: "Instructor") : who.name
        return HStack(spacing: 12) {
            AvatarView(id: who.img, photo: who.photo, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
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
                                   replacerName: who.name.isEmpty ? claim.replacerName : who.name,
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
    @Environment(\.locale) private var locale

    private var offers: [RemoteCoverageOffer] { data.myOffers }
    private var owed: [Booking] { data.coverOwed }

    /// Offers the instructor just tapped "Claim" on, keyed by `bookingID`. Optimistic, for the same
    /// reason as OutOfStudioView.requestedIDs: `claimCoverage` publishes async (and no-ops entirely in
    /// the seeded sim), and the only "claimed" signal — `data.myClaims` — isn't populated until the
    /// round-trip syncs, so the button looked dead. This flips it instantly and reconciles with myClaims.
    @State private var claimedIDs: Set<String> = []

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
        let claimed = claimedIDs.contains(offer.bookingID)
            || data.myClaims.contains { $0.bookingID == offer.bookingID }
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(localizedTag: offer.sessionType)
                    .font(FloweFont.serif(15))
                    .foregroundStyle(Color.floweInk)
                Text(offer.sessionDate)
                    .font(FloweFont.sans(12))
                    .foregroundStyle(Color.floweMuted)
            }
            Button {
                claimedIDs.insert(offer.bookingID)   // flip the button now, don't wait on the network
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
            HStack(alignment: .top, spacing: 10) {
                // The student I'm covering — resolved from the CoverageSession the owner published on
                // award (see `resolveCovering`). Absent until then, so this shows a real face once the
                // swap is confirmed rather than the "cover-…" placeholder.
                AvatarView(id: "", photo: data.studentPhoto(forOwnerID: booking.studentID ?? ""), size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(booking.studentName.isEmpty ? "Client" : booking.studentName)
                        .font(FloweFont.serif(15))
                        .foregroundStyle(Color.floweInk)
                    (Text(localizedTag: booking.type) + Text(" · ") + Text(booking.localizedDate(locale)) + Text(" · ") + Text(booking.localizedTime(locale)))
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
