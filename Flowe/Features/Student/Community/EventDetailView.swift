import SwiftUI
import UIKit

/// One event, full-screen. The "sexy" surface: a full-bleed hero with the title set large in Fraunces
/// over a darkened photo, an organizer card overlapping its lower edge, a stat trio, the details, and
/// a pinned action rail that joins, leaves, or explains why neither is possible.
///
/// It must NEVER call `syncEvents()`: that prunes cached events, including the very one this sheet
/// holds, and reading a deleted SwiftData model traps at runtime. `.task` calls the narrow,
/// non-pruning `syncAttendance(for:)` instead.
struct EventDetailView: View {
    @Environment(MockDataStore.self) private var data
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    let event: CommunityEvent

    /// Whether this presentation may MANAGE the event (edit / cancel / delete). Only the instructor
    /// Dashboard passes `true`; the student Community browse context leaves it `false`.
    ///
    /// Management is deliberately gated on the presenting CONTEXT, not on identity alone. `isMine`
    /// compares `organizerID == currentUserID`, but a dev/seeded build has no real Apple sign-in, so
    /// every role falls back to the same `local-user` id — which made a student "own" an instructor's
    /// event and see Edit/Delete. A student browsing events must never manage one, whatever the ids
    /// happen to be, so the student side simply never grants management.
    var manageable: Bool = false

    @State private var showReport = false
    @State private var showEdit = false
    @State private var showOrganizer = false
    @State private var confirmLeave = false
    @State private var confirmCancel = false
    @State private var confirmDelete = false
    @State private var showHeroZoom = false
    @State private var showDiscussion = false

    private var isMine: Bool { data.isMine(event) }

    /// The real gate for every owner-only control: the organizer, AND a context that allows managing.
    private var canManage: Bool { manageable && isMine }

    private var organizerListing: Instructor? { data.organizerListing(for: event) }

    /// Whether the organizer has a listing a student can actually open — the card is only tappable
    /// then. A lapsed or student organizer has none, and the row shows no chevron.
    private var organizerIsVisible: Bool {
        guard let id = event.organizerID else { return false }
        return data.visibleInstructors.contains { $0.ownerID == id }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    hero
                    organizerCard
                        .padding(.top, -24)   // overlap the hero's lower edge
                    statTrio
                        .padding(.top, 20)
                    sections
                        .padding(.top, 24)
                    if canManage {
                        requestsSection
                            .padding(.top, 24)
                    }
                    whoIsGoing
                        .padding(.top, 20)
                    if data.canDiscuss(event) {
                        discussionButton
                            .padding(.top, 16)
                    }
                }
                .padding(.bottom, 24)
            }
            .ignoresSafeArea(edges: .top)
            .background(Color.flowWhite)
            .navigationBarHidden(true)
            .safeAreaInset(edge: .bottom) { actionRail }
        }
        .task {
            await data.syncAttendance(for: event)
            // Warm attendee profiles so the opt-in "Who's going" roster can resolve names, photos, and
            // each person's community-visibility. Targeted fetch by the accepted guests' ownerIDs.
            await data.warmRosterPeers(Set(data.acceptedGuests(for: event).map(\.studentID)))
            // Pull the discussion so the button's message count is fresh (only when the user can see it).
            if data.canDiscuss(event) { await data.syncEventComments(for: event) }
        }
        .sheet(isPresented: $showDiscussion) {
            DiscussionSheet(
                title: "Discussion",
                emptyHint: String(localized: "Say hi to the others going to \(event.title)."),
                comments: { data.eventComments(for: event) },
                onSend: { data.addEventComment(to: event, text: $0) },
                onSync: { await data.syncEventComments(for: event) }
            )
        }
        .sheet(isPresented: $showReport) {
            ReportSheet(
                reportedID: event.organizerID ?? "",
                reportedName: event.organizerName,
                content: .communityEvent,
                contentID: event.remoteID ?? "",
                snapshot: "\(event.title)\n\n\(event.about)"
            )
        }
        .sheet(isPresented: $showEdit) {
            ComposeEventSheet(editing: event)
        }
        // The organizer's full instructor profile, not the booking sheet directly. No distance fix in
        // the community tab, so the profile omits the teaching-area distance.
        .fullScreenCover(isPresented: $showOrganizer) {
            if let listing = organizerListing {
                StudentInstructorProfileView(instructor: listing) { showOrganizer = false }
            }
        }
        .confirmationDialog("Leave this event?", isPresented: $confirmLeave,
                            titleVisibility: .visible) {
            Button("Leave", role: .destructive) { data.leave(event) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your spot goes back to the pool and someone else can take it. You can rejoin if it's still open.")
        }
        .confirmationDialog("Cancel this event?", isPresented: $confirmCancel,
                            titleVisibility: .visible) {
            Button("Cancel event", role: .destructive) { data.cancelEvent(event) }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("It disappears for everyone who hasn't joined, and the people who joined will see it marked cancelled. This can't be undone.")
        }
        .confirmationDialog("Delete this event?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { data.deleteEvent(event); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It disappears for everyone. This can't be undone.")
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
            // Tap the highlight photo to open it full-screen. The overlaid close/moderation
            // buttons handle their own taps and take priority, so only the photo area opens the
            // viewer — and only when there's a real highlight to show.
            .contentShape(Rectangle())
            .onTapGesture { if event.highlight != nil { showHeroZoom = true } }
            .fullScreenImageZoom(data: event.highlight, isPresented: $showHeroZoom)
    }

    @ViewBuilder
    private var heroPhoto: some View {
        if let bytes = event.highlight, let image = UIImage(data: bytes) {
            Color.clear.overlay { Image(uiImage: image).resizable().scaledToFill() }
        } else if event.hasHighlight {
            FlowGradients.grad.opacity(0.25)
                .overlay { ProgressView().tint(Color.flowePinkDeep) }
        } else {
            FlowGradients.grad
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 110))
                        .foregroundStyle(.white.opacity(0.18))
                        .padding(24)
                }
        }
    }

    private var heroCaption: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(event.startsAt.flowLongDate) · \(event.startsAt.flowTimeString)")
                .font(FloweFont.mono(11))
                .foregroundStyle(.white.opacity(0.85))
                .textCase(.uppercase)
            // The striking move: the title set large in Fraunces, white, over the darkened photo.
            Text(event.title)
                .font(FloweFont.serif(30, .medium))
                .foregroundStyle(.white)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .shadow(color: Color.floweInk.opacity(0.35), radius: 8, y: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var heroButtons: some View {
        HStack(spacing: 10) {
            circleButton("xmark") { dismiss() }
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
            if canManage {
                Button("Edit event", systemImage: "pencil") { showEdit = true }
                if !event.cancelled {
                    Button("Cancel event", systemImage: "xmark.circle", role: .destructive) {
                        confirmCancel = true
                    }
                }
                // Delete only with nobody registered — pulling an event out from under people who
                // joined is what Cancel (which they still see, marked) is for.
                if event.attendees == 0 || event.attendees == nil {
                    Button("Delete event", systemImage: "trash", role: .destructive) {
                        confirmDelete = true
                    }
                }
            } else {
                Button("Report event", systemImage: "flag") { showReport = true }
                Button("Block \(event.organizerName)", systemImage: "hand.raised", role: .destructive) {
                    data.block(id: event.organizerID ?? "", name: event.organizerName)
                    dismiss()
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.floweInk)
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("More options")
        .accessibilityIdentifier("event.moderation")
    }

    // MARK: - Organizer requests (accept / decline join requests)

    @ViewBuilder
    private var requestsSection: some View {
        let requests = data.pendingRequests(for: event)
        let full = event.spotsLeft == 0
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SectionHeader(text: "REQUESTS")
                if !requests.isEmpty {
                    Text("\(requests.count)")
                        .font(FloweFont.mono(10)).foregroundStyle(.white)
                        .frame(minWidth: 18).padding(.vertical, 2).padding(.horizontal, 4)
                        .background(Capsule().fill(FlowGradients.gradDark))
                }
                Spacer()
            }
            if requests.isEmpty {
                Text("New requests to join appear here for you to accept or decline.")
                    .font(FloweFont.sans(13)).foregroundStyle(Color.floweMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if full {
                    Text("This event is full — decline a request or leave a spot open before accepting more.")
                        .font(FloweFont.sans(12)).foregroundStyle(Color.floweCancel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(requests, id: \.studentID) { requestRow($0, acceptDisabled: full) }
            }
        }
        .padding(.horizontal, 20)
    }

    private func requestRow(_ req: RemoteRegistration, acceptDisabled: Bool) -> some View {
        // Live-resolve the requester: req.studentName is the frozen join-time snapshot, which reads
        // "Member" for a student who requested before setting a name.
        let name = data.displayIdentity(ownerID: req.studentID, fallbackName: req.studentName).name
        return HStack(spacing: 12) {
            if let photo = data.peerPhoto(forOwnerID: req.studentID) {
                AvatarView(id: "", photo: photo, size: 40)
            } else {
                InitialAvatar(name: name, size: 40)
            }
            Text(name.isEmpty ? String(localized: "A student") : name)
                .font(FloweFont.sans(14, .medium)).foregroundStyle(Color.floweInk).lineLimit(1)
            Spacer(minLength: 8)
            Button {
                Haptic.tap(); data.respondToEventRequest(req, accepted: false)
            } label: {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.floweCancel).frame(width: 36, height: 36)
                    .background(Color.floweCancel.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Decline \(name)")
            Button {
                Haptic.success(); data.respondToEventRequest(req, accepted: true)
            } label: {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 36, height: 36)
                    .background(acceptDisabled ? AnyShapeStyle(Color.floweMuted.opacity(0.4))
                                               : AnyShapeStyle(FlowGradients.gradDark), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(acceptDisabled)
            .accessibilityLabel("Accept \(name)")
        }
        .padding(12)
        .floweCard(cornerRadius: 14)
    }

    // MARK: - Organizer card

    private var organizerCard: some View {
        Group {
            if organizerIsVisible {
                Button { showOrganizer = true } label: { organizerRow(chevron: true) }
                    .buttonStyle(.plain)
            } else {
                organizerRow(chevron: false)
            }
        }
        .padding(.horizontal, 20)
    }

    private func organizerRow(chevron: Bool) -> some View {
        HStack(spacing: 12) {
            AvatarView(
                id: organizerListing?.img ?? "",
                photo: data.organizerPhoto(for: event),
                size: 44,
                ring: true
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("HOSTED BY")
                    .font(FloweFont.mono(9))
                    .foregroundStyle(Color.floweMuted)
                Text({ let n = data.displayIdentity(ownerID: event.organizerID, fallbackName: event.organizerName).name
                       return n.isEmpty ? String(localized: "Someone") : n }())
                    .font(FloweFont.sans(15, .medium))
                    .foregroundStyle(Color.floweInk)
                // Only a real rating — never a fabricated 0.0 before the first review.
                if let id = event.organizerID, let summary = data.rating(for: id) {
                    StarRatingView(rating: summary.average)
                }
            }
            Spacer()
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.floweMuted)
            }
        }
        .padding(16)
        .floweCard(cornerRadius: 18)
    }

    // MARK: - Stat trio

    private var statTrio: some View {
        HStack(spacing: 12) {
            StatTile(value: priceValue, label: "PER PERSON",
                     accent: event.price == nil ? .floweMuted : .flowePinkDeep)
            spotsTile
            StatTile(value: goingValue, label: "GOING",
                     accent: event.attendees == nil ? .floweMuted : .flowePink)
        }
        .padding(.horizontal, 20)
    }

    private var spotsTile: some View {
        // spotsLeft is nil both when nothing has been counted and when no capacity was stated —
        // either way it's unknown and must render an em dash, never a 0.
        if let spots = event.spotsLeft {
            return StatTile(value: "\(spots)", label: "SPOTS LEFT",
                            accent: spots == 0 ? .floweMuted : .flowePinkDeep)
        } else {
            return StatTile(value: "—", label: "SPOTS", accent: .floweMuted)
        }
    }

    private var priceValue: String {
        guard let price = event.price else { return "—" }
        return price == 0 ? String(localized: "Free") : settings.money(price)
    }

    private var goingValue: String {
        guard let attendees = event.attendees else { return "—" }
        return "\(attendees)"
    }

    // MARK: - Detail sections

    private var sections: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(text: "WHEN")
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.flowePinkDeep)
                    Text(event.startsAt.flowLongDate)
                        .font(FloweFont.sans(14))
                        .foregroundStyle(Color.floweInk)
                    Text("\(event.durationMinutes) min")
                        .font(FloweFont.mono(10))
                        .foregroundStyle(Color.floweMuted)
                }
            }

            if !event.location.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(text: "WHERE")
                    Text(event.location)
                        .font(FloweFont.sans(14))
                        .foregroundStyle(Color.floweInk)
                }
            }

            if !event.about.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(text: "ABOUT")
                    Text(event.about)
                        .font(FloweFont.sans(15))
                        .foregroundStyle(Color.floweInk)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    // MARK: - Who's going

    @ViewBuilder
    private var whoIsGoing: some View {
        if let attendees = event.attendees {
            if canManage {
                // The organizer's view. A full attendee roster (names + join times) would need a
                // store accessor the data layer doesn't expose — only the count is persisted — so
                // this surfaces the count and, crucially, the overflow, which is the one thing the
                // organizer alone can see and the only person who can act on it.
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(text: "ATTENDEES")
                    Text("^[\(attendees) person](inflect: true) registered")
                        .font(FloweFont.sans(13))
                        .foregroundStyle(Color.floweInk)
                    if event.capacity > 0, attendees > event.capacity {
                        Text("^[\(attendees - event.capacity) spot](inflect: true) over capacity — the latest to join are released as their devices reconcile.")
                            .font(FloweFont.mono(9))
                            .foregroundStyle(Color.floweCancel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
            } else if attendees > 0 {
                communityRoster(total: attendees)
            }
        }
    }

    /// The student-facing "Who's going" — an opt-in roster (Flowe Community). Only students who joined
    /// the community appear, and only such students see the roster (privacy-first reciprocity). Everyone
    /// else sees the count + an invite to opt in. See [[Flowe-Community]].
    @ViewBuilder
    private func communityRoster(total: Int) -> some View {
        let guests = data.communityAttendees(for: event)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(text: "WHO'S GOING")
                Spacer()
                Text("\(total) going")
                    .font(FloweFont.mono(10))
                    .foregroundStyle(Color.floweMuted)
            }

            if data.isCommunityVisible {
                if guests.isEmpty {
                    Text("You're going — no one else has shared their name yet. They'll appear here as they join the community.")
                        .font(FloweFont.sans(13))
                        .foregroundStyle(Color.floweMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(guests, id: \.studentID) { attendeeChip($0) }
                        }
                    }
                }
                Button("You're visible to the community · Hide me") { data.setCommunityVisible(false) }
                    .font(FloweFont.sans(12))
                    .tint(Color.floweMuted)
            } else {
                Text("^[\(total) person](inflect: true) going. Join the Flowe community to see who else is coming — and let them see you.")
                    .font(FloweFont.sans(13))
                    .foregroundStyle(Color.floweInk)
                    .fixedSize(horizontal: false, vertical: true)
                Button { data.setCommunityVisible(true) } label: {
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
                .accessibilityIdentifier("event.joinCommunity")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }

    private func attendeeChip(_ reg: RemoteRegistration) -> some View {
        let isMe = reg.studentID == data.currentUserID
        // Live-resolve before taking the first name — reg.studentName is the frozen join-time snapshot.
        let full = data.displayIdentity(ownerID: reg.studentID, fallbackName: reg.studentName).name
        let name = full.split(separator: " ").first.map(String.init) ?? full
        return VStack(spacing: 6) {
            if let photo = data.peerPhoto(forOwnerID: reg.studentID) {
                AvatarView(id: "", photo: photo, size: 52, ring: isMe)
            } else {
                InitialAvatar(name: full, size: 52)
            }
            Text(isMe ? String(localized: "You") : (name.isEmpty ? String(localized: "Someone") : name))
                .font(FloweFont.sans(11, .medium))
                .foregroundStyle(Color.floweInk)
                .lineLimit(1)
                .frame(maxWidth: 60)
        }
    }

    // MARK: - Discussion (Flowe Community)

    /// Entry into the event discussion — shown only when the student can take part (opted into the
    /// community + going/hosting). See [[Flowe-Community]].
    private var discussionButton: some View {
        let n = data.eventComments(for: event).count
        return Button { showDiscussion = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.flowePinkDeep)
                    .frame(width: 40, height: 40)
                    .background(Color.flowePink.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Discussion")
                        .font(FloweFont.sans(15, .medium))
                        .foregroundStyle(Color.floweInk)
                    Text(n == 0 ? String(localized: "Say hi to the people going")
                               : String(localized: "\(n) messages"))
                        .font(FloweFont.sans(12))
                        .foregroundStyle(Color.floweMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.floweMuted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .floweCard(cornerRadius: 16)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .accessibilityIdentifier("event.discussion")
    }

    // MARK: - Action rail

    private var actionRail: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.floweBorder).frame(height: 1)
            railContent
                .padding(20)
        }
        .background(Color.flowWhite)
    }

    @ViewBuilder
    private var railContent: some View {
        if event.pendingUpload {
            // Only the organizer sees an event before it has reached the server; there is nothing to
            // join yet.
            Text("NOT SENT YET")
                .font(FloweFont.mono(10))
                .foregroundStyle(Color.floweMuted)
                .frame(maxWidth: .infinity)
        } else if event.pendingJoin {
            GradientButton(title: "Sending…", enabled: false) {}
        } else if canManage {
            organizerRail
        } else {
            studentRail
        }
    }

    @ViewBuilder
    private var organizerRail: some View {
        VStack(spacing: 12) {
            SecondaryButton(title: "Edit event") { showEdit = true }
            if !event.cancelled, event.endsAt >= Date() {
                Button { confirmCancel = true } label: {
                    Text("Cancel this event")
                        .font(FloweFont.sans(14, .medium))
                        .foregroundStyle(Color.floweCancel)
                }
            }
        }
    }

    @ViewBuilder
    private var studentRail: some View {
        // A finished or called-off class can't be acted on, whatever my request state.
        if case .ended = event.status { statusBar }
        else if case .cancelled = event.status { statusBar }
        else {
            // Events are request → organizer accepts (like lesson bookings). My standing decides the rail.
            switch data.requestState(for: event) {
            case .accepted:
                VStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.flowePinkDeep)
                        Text("You're in.").font(FloweFont.sans(13)).foregroundStyle(Color.floweInk)
                    }
                    SecondaryButton(title: "Leave this event") { confirmLeave = true }
                        .accessibilityIdentifier("event.leave")
                }
            case .requested:
                VStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.badge.checkmark").foregroundStyle(Color.flowePinkDeep)
                        Text("Requested — waiting for \(event.organizerName) to accept.")
                            .font(FloweFont.sans(13)).foregroundStyle(Color.floweInk)
                            .multilineTextAlignment(.center)
                    }
                    SecondaryButton(title: "Withdraw request") { confirmLeave = true }
                        .accessibilityIdentifier("event.leave")
                }
            case .declined:
                VStack(spacing: 10) {
                    Text("Not accepted this time.")
                        .font(FloweFont.sans(13)).foregroundStyle(Color.floweMuted)
                    SecondaryButton(title: "Dismiss") { data.leave(event) }
                }
            case .notRequested:
                if case .full = event.status {
                    statusBar
                } else {
                    VStack(spacing: 8) {
                        GradientButton(title: "Request to join") { data.join(event) }
                            .accessibilityIdentifier("event.join")
                        Text(event.price == 0
                             ? "Free event. The organizer accepts your request."
                             : "Free to request. If accepted, you'll pay your instructor directly.")
                            .font(FloweFont.mono(9))
                            .foregroundStyle(Color.floweMuted)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
    }

    /// The unavailable state is a labelled plate, deliberately NOT a disabled button: a greyed-out
    /// button reads as "temporarily broken", a plate reads as "this is how it is".
    @ViewBuilder
    private var statusBar: some View {
        VStack(spacing: 8) {
            if case .full = event.status {
                Text("All ^[\(event.capacity) spot](inflect: true) are taken.")
                    .font(FloweFont.mono(9))
                    .foregroundStyle(Color.floweMuted)
            }
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.floweMuted.opacity(0.12))
                .frame(height: 56)
                .overlay {
                    Text(statusBarLabel)
                        .font(FloweFont.sans(15, .medium))
                        .foregroundStyle(Color.floweMuted)
                }
                .accessibilityIdentifier("event.status")
        }
    }

    private var statusBarLabel: LocalizedStringKey {
        switch event.status {
        case .full:      return "Fully booked"
        case .ended:     return "This event has ended"
        case .cancelled: return "This event was cancelled"
        default:         return ""
        }
    }
}
