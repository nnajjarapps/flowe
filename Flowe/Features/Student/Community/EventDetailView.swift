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

    @State private var showReport = false
    @State private var showEdit = false
    @State private var showOrganizer = false
    @State private var confirmLeave = false
    @State private var confirmCancel = false
    @State private var confirmDelete = false

    private var isMine: Bool { data.isMine(event) }

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
                    whoIsGoing
                        .padding(.top, 20)
                }
                .padding(.bottom, 24)
            }
            .ignoresSafeArea(edges: .top)
            .background(Color.flowWhite)
            .navigationBarHidden(true)
            .safeAreaInset(edge: .bottom) { actionRail }
        }
        .task { await data.syncAttendance(for: event) }
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
        .sheet(isPresented: $showOrganizer) {
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
            if isMine {
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
        .accessibilityIdentifier("event.moderation")
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
                Text(event.organizerName)
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
            if isMine {
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
                Text("^[\(attendees) person](inflect: true) going")
                    .font(FloweFont.sans(13))
                    .foregroundStyle(Color.floweMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
            }
        }
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
        } else if isMine {
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
        switch event.status {
        case .open:
            VStack(spacing: 8) {
                GradientButton(title: "Join this event") { data.join(event) }
                    .accessibilityIdentifier("event.join")
                Text(event.price == 0
                     ? "Free event."
                     : "Free to join. You'll pay your instructor directly.")
                    .font(FloweFont.mono(9))
                    .foregroundStyle(Color.floweMuted)
                    .multilineTextAlignment(.center)
            }
        case .joined:
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.flowePinkDeep)
                    Text("You're going.")
                        .font(FloweFont.sans(13))
                        .foregroundStyle(Color.floweInk)
                }
                SecondaryButton(title: "Leave this event") { confirmLeave = true }
                    .accessibilityIdentifier("event.leave")
            }
        case .full, .ended, .cancelled:
            statusBar
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

#Preview {
    let store = MockDataStore.preview
    store.currentUserID = FloweConstants.localOwnerID
    store.currentUserName = "Taylor Brooks"
    store.addEvent(
        title: "Sunrise Reformer Flow",
        about: "A slow, breath-led reformer class to open the week. All levels — bring grip socks.",
        location: "Studio Flowe, 12 Rue de la Paix",
        startsAt: Date().addingTimeInterval(3 * 24 * 3600),
        durationMinutes: 60,
        capacity: 12,
        price: 30,
        image: nil
    )
    return Group {
        if let event = store.events.first {
            EventDetailView(event: event)
        }
    }
    .environment(store)
    .environment(AppSettings())
    .environment(AppSession())
}
