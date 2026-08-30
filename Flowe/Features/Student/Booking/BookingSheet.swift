import SwiftUI
import UIKit

struct BookingSheet: View {
    let instructor: Instructor
    /// Called when the sheet closes, reporting whether a booking was actually made. A presenter that
    /// stacked this on top of something else (the profile) needs the distinction: on a completed
    /// booking it should tear the whole stack down and return to the app, but on a mid-flow
    /// cancel/back it should stay put — otherwise "Done" leaves the profile covering the tab bar.
    let onClose: (_ booked: Bool) -> Void

    @Environment(MockDataStore.self) private var data
    @Environment(AppSettings.self) private var settings

    @State private var step: Int
    @State private var day = ""
    // The real `Date` behind the chosen day. The pickerValue (`day`) carries no year, so it can't key a
    // date-specific availability override; this drives the date-aware `hours(onDate:)` resolver.
    @State private var dayDate: Date?
    @State private var dayLabel = ""   // localized display of `day` (pickerValue stays English for lookup)
    @State private var time = ""
    @State private var type = ""
    @State private var booked = false
    @State private var waitlisted = false      // the confirmed booking landed on the waitlist (group class was full)
    @State private var isConfirming = false   // synchronous in-flight guard against a double-tap self-race
    @State private var weekOffset = 0   // which forward week the day picker is showing (0 = this week)
    // Live slot occupancy for the chosen day: [HHmm token: seats taken]. A DISPLAY hint (best-effort);
    // the atomic seat claim at confirm is the real guarantee. Loaded on entering step 2 and on day change.
    @State private var occupancy: [String: Int] = [:]
    @State private var occupancyLoading = false
    @State private var showBookingAlert = false
    @State private var bookingAlertMessage = ""
    @State private var showReport = false
    @State private var confirmBlock = false
    @State private var showCertificate = false
    @State private var badgePop = false   // the confirmation checkmark's celebratory scale-in
    @State private var creditBalance = 0   // class-credits the student holds with THIS instructor
    @State private var useCredit = true    // redeem one on confirm (only surfaced when creditBalance > 0)
    @State private var usedCredit = false  // a credit was actually spent (drives the confirm receipt)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Route A handoff: a caller that already showed the profile (InstructorProfileView) opens the
    /// sheet at the day picker with `startStep: 1`, skipping the intro it just rendered. Default 0
    /// keeps stepIntro as the entry for the Xcode preview and any existing caller.
    /// The step this sheet opened at. When it is the day picker (1), the profile above already served
    /// as the intro, so the day picker's "back" dismisses to it rather than descending into the
    /// orphaned `stepIntro` — which still carries the thin stats the profile exists to replace.
    private let startStep: Int

    init(instructor: Instructor, startStep: Int = 0, onClose: @escaping (Bool) -> Void) {
        self.instructor = instructor
        self.onClose = onClose
        self.startStep = startStep
        _step = State(initialValue: startStep)
    }

    /// Payment methods we know how to render, in canonical order.
    private var methods: [String] { PaymentMethod.known(instructor.paymentMethods) }

    var body: some View {
        VStack(spacing: 0) {
            hero
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch step {
                    case 0: stepIntro
                    case 1: stepDay
                    case 2: stepTimeType
                    default: stepConfirm
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .background(Color.flowWhite)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            // Default to the first resolved (rich) type's name; fall back to the raw name cache so an
            // un-upgraded remote instructor still preselects. Empty only when the instructor authored none.
            if type.isEmpty {
                type = data.lessonTypes(for: instructor).first?.name ?? instructor.sessionTypes.first ?? ""
            }
        }
        // The presenting profile already syncs types, but the fetch is idempotent — so a BookingSheet
        // reached by any other path still populates the picker rather than showing only the name cache.
        .task { await data.syncLessonTypes(for: instructor) }
        // The student's class-credit balance with this instructor — gates the redeem toggle + "N left".
        .task { if let id = instructor.ownerID { creditBalance = await data.refreshBalance(with: id)?.balance ?? 0 } }
        // Load live occupancy whenever the time/type step is shown or the chosen day changes, so taken
        // slots render Full instead of a stale slate that looks freely bookable.
        .onChange(of: step) { _, newValue in if newValue == 2 { Task { await loadOccupancy() } } }
        .onChange(of: day) { _, _ in if step == 2 { Task { await loadOccupancy() } } }
        .floweDialog(
            isPresented: $showBookingAlert,
            titleText: Text(verbatim: bookingAlertMessage),
            actions: [FloweDialogAction("OK", role: .cancel)]
        )
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
        .fullScreenCover(isPresented: $showCertificate) { certificateViewer }
        .floweConfirm(
            isPresented: $confirmBlock,
            title: "Block \(instructor.firstName)?",
            message: "You won't see their profile or messages. You can undo this in Settings.",
            confirmTitle: "Block",
            isDestructive: true
        ) {
            if let id = instructor.ownerID {
                data.block(id: id, name: instructor.name)
            }
            onClose(false)
        }
    }

    // MARK: - Hero band

    private var hero: some View {
        ZStack {
            RemoteImage(id: instructor.img, photo: instructor.photo, width: 600, height: 280)
                .frame(height: 144)
                .clipped()
            FlowGradients.grad.opacity(0.7)
            LinearGradient(
                colors: [Color.black.opacity(0.35), .clear],
                startPoint: .bottom, endPoint: .top
            )

            VStack {
                HStack {
                    Spacer()
                    // A listing's name, city, bio and certification are user-written and public, so
                    // students need a way to flag one (Guideline 1.2).
                    Menu {
                        Button("Report this profile", systemImage: "flag") { showReport = true }
                        Button("Block \(instructor.firstName)", systemImage: "hand.raised",
                               role: .destructive) { confirmBlock = true }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("More options")
                    .accessibilityIdentifier("booking.moderation")

                    Button(action: { onClose(false) }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Close")
                }
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(instructor.name)
                            .font(FloweFont.serif(17))
                            .foregroundStyle(.white)
                        HStack(spacing: 4) {
                            Image(systemName: "mappin").font(.system(size: 10))
                            Text(instructor.address).font(FloweFont.mono(11))
                        }
                        .foregroundStyle(.white.opacity(0.75))
                    }
                    Spacer()
                    // A review-less instructor reads "New", never a fabricated 0.0 (0).
                    HStack(spacing: 4) {
                        if instructor.reviews > 0 {
                            Image(systemName: "star.fill").font(.system(size: 10))
                            Text("\(instructor.rating, specifier: "%.1f") (\(instructor.reviews))")
                                .font(FloweFont.mono(11))
                        } else {
                            Text("New").font(FloweFont.mono(11))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(12)
        }
        .frame(height: 144)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    // MARK: - Step 0

    private var stepIntro: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                statCol("\(instructor.students)", "Students")
                // "—" rather than "0yrs" when unstated: 0 is the empty value of an optional text
                // field, and printing it claims the instructor has no experience at all.
                statCol(instructor.yearsExp > 0 ? "\(instructor.yearsExp)yrs" : "—", "Exp.")
                statCol("\(instructor.reviews)", "Reviews")
            }
            .padding(.bottom, 16)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.floweBorder).frame(height: 1)
            }
            .padding(.bottom, 16)

            Text(instructor.bio ?? "Certified Pilates instructor.")
                .font(FloweFont.sans(13))
                .foregroundStyle(Color.floweInk)
                .lineSpacing(4)
                .padding(.bottom, 16)

            FlowLayout(spacing: 6) {
                ForEach(instructor.specialties, id: \.self) { s in
                    Text(localizedTag: s)
                        .font(FloweFont.mono(11))
                        .foregroundStyle(Color.flowePinkDeep)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.flowePink.opacity(0.12), in: Capsule())
                }
            }
            .padding(.bottom, 20)

            certificationBlock
            paymentBlock

            // Pre-type intro: the price hint is the "from" starting price (cheapest lesson type),
            // dropped when no type is priced. Nested localization reuses "from %@" + "Book a Session · %@".
            GradientButton(title: instructor.price > 0
                ? "Book a Session · \(String(localized: "from \(settings.money(instructor.price))"))"
                : "Book a Session") { withAnimation(FloweMotion.spring) { step = 1 } }
        }
    }

    // MARK: - Certification

    private var hasCertification: Bool { !instructor.cert.isEmpty || instructor.certPhoto != nil }

    /// The instructor's own certification claim — text, and the certificate photo if they uploaded
    /// one. The disclaimer travels with it: a photo makes the claim look official, and Flowe checks
    /// none of it.
    @ViewBuilder
    private var certificationBlock: some View {
        if hasCertification {
            VStack(alignment: .leading, spacing: 8) {
                Text("CERTIFICATION")
                    .font(FloweFont.mono(11))
                    .foregroundStyle(Color.floweMuted)

                if !instructor.cert.isEmpty {
                    Text(instructor.cert)
                        .font(FloweFont.sans(13))
                        .foregroundStyle(Color.floweInk)
                }

                if let data = instructor.certPhoto, let image = UIImage(data: data) {
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
                    .accessibilityIdentifier("booking.certPhoto")
                }

                Text("Flowe doesn't verify certifications.")
                    .font(FloweFont.mono(10))
                    .foregroundStyle(Color.floweMuted)
            }
            .padding(.bottom, 20)
        }
    }

    /// Full-screen look at the certificate — the credential and its date are often small print.
    private var certificateViewer: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Spacer(minLength: 0)
                if let data = instructor.certPhoto, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
                Spacer(minLength: 0)
                // The disclaimer follows the certificate everywhere it is shown, including here,
                // where the photo fills the screen and reads most like an endorsement.
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
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("booking.certPhotoClose")
                }
                Spacer()
            }
            .padding(16)
        }
    }

    // MARK: - Payment

    /// How the student will actually pay. Flowe collects nothing, so this belongs before the
    /// booking button rather than in the fine print afterwards.
    private var paymentBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PAYMENT")
                .font(FloweFont.mono(11))
                .foregroundStyle(Color.floweMuted)

            if methods.isEmpty {
                // No empty row: an instructor who never picked a method still has to be paid, so
                // say what the student should actually do.
                Text("\(instructor.firstName) hasn't listed how they take payment — ask them before your session.")
                    .font(FloweFont.sans(13))
                    .foregroundStyle(Color.floweInk)
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
        .accessibilityIdentifier("booking.payment")
        .padding(.bottom, 20)
    }

    private func statCol(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(FloweFont.serif(18, .medium))
                .foregroundStyle(Color.floweInk)
            Text(label)
                .font(FloweFont.mono(9))
                .foregroundStyle(Color.floweMuted)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Step 1

    private var stepDay: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // Opened from the profile (startStep 1) → back returns to it; opened at the intro →
                // back steps up to it. Never strands the profile-first flow on the orphaned intro.
                backButton { if startStep >= 1 { onClose(false) } else { withAnimation(FloweMotion.spring) { step = 0 } } }
                Text("Choose a day")
                    .font(FloweFont.serif(17))
                    .foregroundStyle(Color.floweInk)
            }
            .padding(.bottom, 12)

            Text("Available: \(instructor.available.map { String(localized: String.LocalizationValue($0)) }.joined(separator: ", "))")
                .font(FloweFont.mono(11))
                .foregroundStyle(Color.floweMuted)
                .padding(.bottom, 12)

            // Week paging around the day grid: chevrons auto-mirror in RTL; back stops at this week,
            // forward at the horizon cap. Availability is weekly-recurring, so paged future weeks need
            // no data change — a picked day persists across paging (its pickerValue carries month+day).
            HStack {
                IconButton(systemName: "chevron.left", action: { withAnimation { weekOffset -= 1 } }, size: 34)
                    .disabled(weekOffset == 0)
                    .opacity(weekOffset == 0 ? 0.4 : 1)
                    .accessibilityLabel("Previous week")
                Spacer()
                Text(FloweWeek.rangeLabel(offset: weekOffset))
                    .font(FloweFont.mono(12))
                    .foregroundStyle(Color.floweInk)
                Spacer()
                IconButton(systemName: "chevron.right", action: { withAnimation { weekOffset += 1 } }, size: 34)
                    .disabled(weekOffset == FloweWeek.maxWeekOffset)
                    .opacity(weekOffset == FloweWeek.maxWeekOffset ? 0.4 : 1)
                    .accessibilityLabel("Next week")
            }
            .padding(.bottom, 12)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(FloweWeek.week(offset: weekOffset)) { d in
                    // Date-aware, not weekday-only: a closed override (vacation) dims/disables the day,
                    // and an OPEN override on a normally-closed weekday makes it tappable.
                    let avail = instructor.isBookable(onDate: d.date)
                    let sel = day == d.pickerValue
                    Button {
                        guard avail else { return }
                        Haptic.selection()
                        // Changing the day can invalidate an already-picked time — Tuesday
                        // 9am may not exist on Thursday.
                        if day != d.pickerValue { time = "" }
                        day = d.pickerValue
                        dayDate = d.date
                        // Keep an already-localized label for the day (pickerValue stays English —
                        // it is the availability lookup key — so it can't be shown directly).
                        dayLabel = (d.isToday ? String(localized: "Today") : d.displayWeekday) + " · " + d.displayShortDate
                    } label: {
                        VStack(spacing: 2) {
                            (d.isToday ? Text("Today") : Text(verbatim: d.displayWeekday))
                                .font(FloweFont.mono(10))
                                .foregroundStyle(sel ? .white : Color.floweInk)
                            Text(verbatim: d.displayShortDate)
                                .font(FloweFont.sans(11))
                                .foregroundStyle(sel ? .white : Color.floweInk)
                            // A date the instructor closed off (vacation) reads Closed, so the student
                            // doesn't tap into an empty day.
                            if instructor.isClosedOverride(onDate: d.date) {
                                Text("Closed")
                                    .font(FloweFont.mono(8))
                                    .foregroundStyle(sel ? .white.opacity(0.8) : Color.floweMuted)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background {
                            if sel {
                                RoundedRectangle(cornerRadius: 12).fill(FlowGradients.gradDark)
                            } else {
                                RoundedRectangle(cornerRadius: 12).fill(avail ? Color.floweCardBg : Color.floweBorder.opacity(0.25))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.floweBorder, lineWidth: 1))
                            }
                        }
                        .opacity(avail ? 1 : 0.35)
                    }
                    .disabled(!avail)
                }
            }
            .padding(.bottom, 20)

            GradientButton(title: "Continue", enabled: !day.isEmpty) { withAnimation(FloweMotion.spring) { step = 2 } }
        }
        // Lets a UI test confirm the profile→booking handoff landed on the day picker (startStep: 1),
        // not the orphaned intro.
        .accessibilityIdentifier("booking.dayStep")
    }

    // MARK: - Step 2

    /// The instructor's bookable hours on the chosen day — not the full house slate. An instructor
    /// who teaches Tuesday mornings only should not appear bookable at 6pm.
    private var availableTimes: [String] {
        // Keyed on the DATE, not the weekday: a vacation date returns [] ("No times left on this day")
        // and a custom date shows its overridden slate.
        guard let dayDate else { return [] }
        return instructor.hours(onDate: dayDate)
    }

    private var stepTimeType: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                backButton { withAnimation(FloweMotion.spring) { step = 1 } }
                Text("Time & type")
                    .font(FloweFont.serif(17))
                    .foregroundStyle(Color.floweInk)
            }
            .padding(.bottom, 4)

            Text(verbatim: dayLabel.isEmpty ? day : dayLabel)
                .font(FloweFont.mono(11))
                .foregroundStyle(Color.floweMuted)
                .padding(.bottom, 12)

            if availableTimes.isEmpty {
                Text("No times left on this day. Try another one.")
                    .font(FloweFont.sans(13))
                    .foregroundStyle(Color.floweMuted)
                    .padding(.bottom, 16)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(availableTimes, id: \.self) { t in
                    let sel = time == t
                    // A slot on TODAY whose start time has already passed can never be booked.
                    let past = isPast(t)
                    let full = isFull(t)
                    // A full 1-on-1 (cap < 2) is a dead end and stays disabled exactly as before. A full
                    // GROUP/duet cell (cap >= 2) stays TAPPABLE — selecting it routes the CTA to "Join
                    // waitlist" — so a full class is never a dead end. A PAST slot is never waitlistable.
                    let waitlistable = full && !past && max(selectedTypeCapacity, 1) >= 2
                    // Dead end = past, or a full cell that can't fall through to a waitlist. Dim + disable.
                    let deadEnd = past || (full && !waitlistable)
                    Button { Haptic.selection(); time = t } label: {
                        VStack(spacing: 2) {
                            Text(verbatim: t.localizedTimeSlot)
                                .font(FloweFont.mono(11))
                                .foregroundStyle(sel ? .white : Color.floweInk)
                            // A passed time reads "Passed"; else group/duet shows "N spots left" / "Full"
                            // (full still tappable → waitlist); 1-on-1 keeps the binary Full/nothing.
                            if past {
                                Text("Passed")
                                    .font(FloweFont.mono(8))
                                    .foregroundStyle(sel ? .white.opacity(0.8) : Color.floweMuted)
                            } else if full {
                                Text("Full")
                                    .font(FloweFont.mono(8))
                                    .foregroundStyle(sel ? .white.opacity(0.8) : Color.floweMuted)
                            } else if let spots = spotsLeftLabel(t) {
                                spots
                                    .font(FloweFont.mono(8))
                                    .foregroundStyle(sel ? .white.opacity(0.85) : Color.flowePinkDeep)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background {
                            if sel {
                                RoundedRectangle(cornerRadius: 12).fill(FlowGradients.gradDark)
                            } else {
                                RoundedRectangle(cornerRadius: 12).fill(Color.floweCardBg)
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.floweBorder, lineWidth: 1))
                            }
                        }
                        .opacity(deadEnd ? 0.35 : 1)
                    }
                    .disabled(deadEnd)
                }
            }
            .padding(.bottom, 16)
            // While the occupancy query is in flight, dim + spin over the grid so a stale slate is never
            // presented as freely bookable (the count is best-effort, but the display shouldn't mislead).
            .overlay {
                if occupancyLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
            .opacity(occupancyLoading ? 0.5 : 1)

            Text("SESSION TYPE")
                .font(FloweFont.mono(11))
                .foregroundStyle(Color.floweMuted)
                .padding(.bottom, 8)

            HStack(spacing: 8) {
                // The rich resolver, not `instructor.sessionTypes`: each cell now shows the authored
                // name plus a compact capacity/price subtitle. No per-type icon — a custom-named type
                // has no predefined glyph. If the resolver is empty the row collapses and booking
                // proceeds with an empty type (honest — the instructor authored none).
                ForEach(Array(data.lessonTypes(for: instructor).enumerated()), id: \.element.id) { index, resolved in
                    let sel = type == resolved.name
                    Button { Haptic.selection(); type = resolved.name } label: {
                        VStack(spacing: 3) {
                            Text(resolved.name)
                                .font(FloweFont.sans(12))
                                .lineLimit(1)
                            if let subtitle = typeSubtitle(resolved) {
                                subtitle.font(FloweFont.mono(9))
                            }
                        }
                        .foregroundStyle(sel ? .white : Color.floweMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 6)
                        .background {
                            if sel {
                                RoundedRectangle(cornerRadius: 12).fill(FlowGradients.gradDark)
                            } else {
                                RoundedRectangle(cornerRadius: 12).fill(Color.floweCardBg)
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.floweBorder, lineWidth: 1))
                            }
                        }
                    }
                    .accessibilityIdentifier("booking.type.\(index)")
                }
            }
            .padding(.bottom, 20)

            if let policyLine {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.floweMuted)
                    Text(policyLine)
                        .font(FloweFont.sans(11))
                        .foregroundStyle(Color.floweMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 14)
            }

            // The class-credit redeem control — only when the student holds credits with this instructor
            // and the slot isn't a waitlist route (a waitlisted seat never spends a credit).
            if creditBalance > 0 && !isWaitlistSelected {
                CreditRedeemToggle(remaining: creditBalance, useCredit: $useCredit)
                    .padding(.bottom, 14)
            }

            GradientButton(title: ctaTitle, enabled: !time.isEmpty, isLoading: isConfirming) {
                Task { await confirmBooking() }
            }
        }
    }

    /// The currently-selected slot would route to the waitlist (a full group/duet seat) — never on a credit.
    private var isWaitlistSelected: Bool {
        !time.isEmpty && isFull(time) && max(selectedTypeCapacity, 1) >= 2
    }
    /// Whether confirming will actually redeem a class-credit.
    private var willUseCredit: Bool { useCredit && creditBalance > 0 && !isWaitlistSelected }

    /// The request CTA. A full group/duet time (still selectable) routes to the waitlist, so the button
    /// says so; everything else keeps the priced "Request" label.
    private var ctaTitle: LocalizedStringKey {
        // A full group/duet time (still selectable) routes to the waitlist.
        if !time.isEmpty && isFull(time) && max(selectedTypeCapacity, 1) >= 2 {
            return "Join waitlist"
        }
        if willUseCredit { return "Book with 1 credit" }
        // A type is chosen at this step, so charge THAT type's price, not the listing's starting rate.
        // An unpriced type shows just "Request" (no misleading "· 0"); Free shows "· Free".
        if let priceText = selectedPriceText { return "Request · \(priceText)" }
        return "Request"
    }

    /// Seats already taken at a time, from the live occupancy hint (0 when unknown / query failed).
    private func seatsUsed(_ t: String) -> Int {
        occupancy[Booking.timeToken(t) ?? ""] ?? 0
    }

    /// The seat capacity of the currently-selected session type (0 unstated → treated as 1, so an
    /// unstated Private is never overbooked). Recomputed on every render, so switching type re-evaluates
    /// which times read Full.
    private var selectedTypeCapacity: Int {
        data.lessonTypes(for: instructor).first { $0.name == type }?.capacity ?? 0
    }

    /// The price of the currently-selected lesson type — the SPECIFIC price the student pays, not the
    /// listing's derived "starting from" rate. nil when no type is chosen yet or the type is unpriced;
    /// callers render `?? 0` (an honest money(0)) rather than falling back to `instructor.price`, which
    /// would reintroduce the bug where the receipt showed the general rate for any chosen type.
    private var selectedTypePrice: Int? {
        data.lessonTypes(for: instructor).first { $0.name == type }?.price
    }

    /// The display string for the selected type's price, keeping the tri-state honest (matches
    /// `LessonTypeCard`): nil (not stated) → no price shown, an explicit 0 → "Free", n → money(n). The
    /// old `money(selectedTypePrice ?? 0)` printed a real "0" for an unpriced type, reading as free.
    private var selectedPriceText: String? {
        guard let p = selectedTypePrice else { return nil }
        return p == 0 ? String(localized: "Free") : settings.money(p)
    }

    /// Whether a time is fully booked for the selected type — reactive to both live occupancy and the
    /// chosen type's capacity.
    private func isFull(_ t: String) -> Bool {
        seatsUsed(t) >= max(selectedTypeCapacity, 1)
    }

    /// Whether a slot's start time has already passed for the chosen day — so a session that's over (or
    /// under way) is never bookable. Only bites on TODAY: a future day's slots are always ahead of `now`;
    /// the picker never shows past days. Builds the slot's absolute instant from the chosen day's date and
    /// the time's 24h "HHmm" token (POSIX-stable), independent of device locale.
    private func isPast(_ t: String, now: Date = Date()) -> Bool {
        guard let dayDate,
              let token = Booking.timeToken(t), token.count == 4,
              let hh = Int(token.prefix(2)), let mm = Int(token.suffix(2)),
              let slot = Calendar.current.date(bySettingHour: hh, minute: mm, second: 0, of: dayDate)
        else { return false }
        return slot <= now   // at-or-after start counts as passed (a slot starting this exact minute is gone)
    }

    /// The "N spots left" sub-label for a GROUP/duet time (capacity >= 2), driven by the SAME PII-free
    /// occupancy count as `isFull`. Nil for a 1-on-1 (capacity < 2 keeps today's binary Full/nothing —
    /// the shipped 1-on-1 display never regresses) and nil at 0 spots (the cell shows "Full" instead).
    /// A duet (cap 2) reads "2 spots left", a group (cap 8) "8 spots left", down to "1 spot left".
    private func spotsLeftLabel(_ t: String) -> Text? {
        guard selectedTypeCapacity >= 2 else { return nil }
        let spots = max(selectedTypeCapacity - seatsUsed(t), 0)
        guard spots > 0 else { return nil }
        return Text("^[\(spots) spot](inflect: true) left")
    }

    /// Fetch live occupancy for the chosen day. Best-effort — on failure it returns empty and the grid
    /// falls back to showing everything bookable; the atomic claim at confirm is the real guard. Clears a
    /// selected time that has just become Full so the user can't submit a taken slot.
    private func loadOccupancy() async {
        guard !day.isEmpty else { return }
        occupancyLoading = true
        occupancy = await data.slotOccupancy(for: instructor, day: day)
        occupancyLoading = false
        // Clear a now-full selection only for a 1-on-1 (a dead end). A full GROUP/duet time stays
        // selected so the student can proceed to Join the waitlist instead of being bounced off it.
        if !time.isEmpty && isFull(time) && max(selectedTypeCapacity, 1) < 2 { time = "" }
        // Clear a selection whose start time has since passed — never leave a bookable past slot chosen.
        if !time.isEmpty && isPast(time) { time = "" }
    }

    /// The cancellation policy for the currently selected session type, shown before the student
    /// commits — the deterrent half of No-Show Shield. Nil when the type has no policy.
    private var policyLine: String? {
        let policy = data.lessonTypes(for: instructor)
            .first { $0.name == type }?.cancellationPolicy ?? CancellationPolicy()
        guard policy.isActive else { return nil }
        let fee = policy.feeIsPercent ? "\(policy.fee)% of the session" : settings.money(policy.fee)
        return "Free cancellation up to \(policy.windowHours)h before — after that, a \(fee) late-cancel / no-show fee applies."
    }

    /// Persist the booking exactly once when the user confirms, gating the success screen on the atomic
    /// seat claim: a lost race (`.slotTaken`) or a self-duplicate keeps the user on the picker with a
    /// clear alert and refreshed availability instead of showing a false "Request sent!".
    private func confirmBooking() async {
        // `booked` only flips AFTER the await, so it can't stop a second tap fired in the same runloop turn
        // from starting its own claim (a self-race that would wrongly report "just booked" for the user's
        // own in-flight booking). `isConfirming` is set synchronously before the first await to block that.
        guard !booked, !isConfirming else { return }
        // Defensive backstop: a slot that was valid when selected may have passed while the sheet sat open.
        // The picker already disables past cells, so this only catches that lingering-open case.
        if isPast(time) {
            bookingAlertMessage = String(localized: "That time has already passed. Pick another.")
            showBookingAlert = true
            time = ""
            return
        }
        isConfirming = true
        defer { isConfirming = false }
        let credit = willUseCredit
        let result = await data.addBooking(instructor: instructor, day: day, time: time, type: type, useCredit: credit)
        switch result {
        case .booked, .failed:
            // .failed never occurs for a booking today (a claim failure degrades to .booked, unlocked),
            // but is handled the same way defensively — the row exists, advance to confirmation.
            booked = true
            usedCredit = credit   // optimistic; the balance refresh corrects the wallet if it ran out
            Haptic.success()
            withAnimation(FloweMotion.spring) { step = 3 }
        case .waitlisted:
            // The group class was full; the booking was still created on an overflow (waitlist) seat.
            booked = true
            waitlisted = true
            Haptic.success()
            withAnimation(FloweMotion.spring) { step = 3 }
        case .slotTaken:
            bookingAlertMessage = String(localized: "This slot was just booked. Pick another time.")
            showBookingAlert = true
            time = ""                    // the just-taken time is no longer a valid selection
            await loadOccupancy()        // refresh so it flips to Full
        case .selfDuplicate:
            bookingAlertMessage = String(localized: "You already have this slot booked.")
            showBookingAlert = true
        }
    }

    /// A compact capacity · price subtitle for a picker cell, RTL-safe separate `Text` runs joined by a
    /// bullet — present only when a field is stated, nil when the type is name-only (the cell then shows
    /// just the name). Capacity is displayed group size, never a live availability count.
    private func typeSubtitle(_ t: ResolvedLessonType) -> Text? {
        var runs: [Text] = []
        if t.capacity == 1 {
            runs.append(Text("1-on-1"))
        } else if t.capacity >= 2 {
            runs.append(Text("Up to ") + Text("^[\(t.capacity) spot](inflect: true)"))
        }
        if let price = t.price {
            runs.append(price == 0 ? Text("Free") : Text(settings.money(price)))
        }
        guard let first = runs.first else { return nil }
        return runs.dropFirst().reduce(first) { $0 + Text(verbatim: " · ") + $1 }
    }

    // MARK: - Step 3

    private var stepConfirm: some View {
        VStack(spacing: 0) {
            Image(systemName: waitlisted ? "hourglass" : "checkmark")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(FlowGradients.gradDark, in: Circle())
                // Celebrate the confirmation: the badge springs in rather than snapping. Static under
                // Reduce Motion (shown at full size, no scale).
                .scaleEffect(badgePop ? 1 : 0.5)
                .opacity(badgePop ? 1 : 0)
                .onAppear {
                    if reduceMotion { badgePop = true }
                    else { withAnimation(FloweMotion.pop.delay(0.08)) { badgePop = true } }
                }
                .padding(.top, 16)
                .padding(.bottom, 16)

            Text(waitlisted ? "You're on the waitlist" : "Request sent!")
                .font(FloweFont.serif(22))
                .foregroundStyle(Color.floweInk)
                .padding(.bottom, 4)

            if usedCredit {
                Label("Paid with 1 class credit", systemImage: "ticket.fill")
                    .font(FloweFont.sans(13, .medium))
                    .foregroundStyle(Color.flowePinkDeep)
                    .padding(.bottom, 8)
            }

            (Text(instructor.name) + Text(" · ") + Text(localizedTag: type))
                .font(FloweFont.sans(14))
                .foregroundStyle(Color.floweInk)
                .padding(.bottom, 4)

            Text("\(dayLabel.isEmpty ? day : dayLabel) at \(time.localizedTimeSlot)")
                .font(FloweFont.mono(12))
                .foregroundStyle(Color.floweMuted)
                .padding(.bottom, 12)

            Text(waitlisted
                 ? "You'll move up automatically as spots open up. We'll update your booking in Bookings."
                 : "\(instructor.firstName) will confirm your session shortly. You'll see it update in Bookings.")
                .font(FloweFont.sans(13))
                .foregroundStyle(Color.floweMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.bottom, 20)

            // Flowe takes no payment for sessions in this release — the student settles up with
            // the instructor directly, so no service fee or total is shown.
            VStack(spacing: 0) {
                // The SELECTED type's price — fixes the latent bug where the receipt showed the
                // general rate for any chosen type.
                receiptRow("Session fee", selectedPriceText ?? "—", bold: true)
                    .padding(.top, 4)
                Text("Paid directly to your instructor")
                    .font(FloweFont.mono(10))
                    .foregroundStyle(Color.floweMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)

                // Repeated here rather than left on the intro step: this is the screen the student
                // leaves with, and it is the last chance to say how the money changes hands.
                if !methods.isEmpty {
                    HStack(spacing: 6) {
                        Text("Pay by")
                            .font(FloweFont.mono(10))
                            .foregroundStyle(Color.floweMuted)
                        ForEach(methods, id: \.self) { method in
                            Text(PaymentMethod.label(method))
                                .font(FloweFont.mono(10))
                                .foregroundStyle(Color.flowePinkDeep)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.flowePink.opacity(0.12), in: Capsule())
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 8)
                    .accessibilityIdentifier("booking.confirmPayment")
                }
            }
            .padding(16)
            .floweCard()
            .padding(.bottom, 20)

            GradientButton(title: "Done") { onClose(true) }
        }
        .frame(maxWidth: .infinity)
    }

    private func receiptRow(_ label: String, _ value: String, bold: Bool) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(bold ? Color.floweInk : Color.floweMuted)
            Spacer()
            Text(value)
                .foregroundStyle(Color.floweInk)
        }
        .font(FloweFont.sans(13, bold ? .medium : .regular))
    }

    // MARK: - Helpers

    private func backButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.floweInk)
        }
        .accessibilityLabel("Back")
    }
}
