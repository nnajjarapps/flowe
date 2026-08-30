import SwiftUI

/// The top-right bell used by BOTH shells (student Discover header, instructor Dashboard header).
/// Shows the live unread count, opens the activity centre, and routes a tapped row to the right tab
/// via the shipped `push.pendingTopic` bus. Self-contained so each header just drops it in.
struct ActivityBellButton: View {
    let isInstructor: Bool

    @Environment(MockDataStore.self) private var data
    @Environment(PushService.self) private var push
    @State private var show = false

    private var unread: Int {
        ActivityLedger.shared.unreadCount(data.activityFeed(isInstructor: isInstructor), isInstructor: isInstructor)
    }

    var body: some View {
        Button { show = true } label: {
            Image(systemName: "bell")
                .font(.system(size: 16))
                .foregroundStyle(Color.floweInk)
                .frame(width: 36, height: 36)
                .background(Color.floweCardBg)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.floweBorder, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        Text(unread > 9 ? "9+" : "\(unread)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, unread > 9 ? 4 : 0)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Color.flowePinkDeep, in: Capsule())
                            .overlay(Capsule().stroke(Color.flowWhite, lineWidth: 1.5))
                            .offset(x: 5, y: -5)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Notifications")
        .sheet(isPresented: $show) {
            NotificationCenterView(isInstructor: isInstructor) { topic in
                show = false
                if let topic { push.pendingTopic = topic }
            }
        }
    }
}

/// The bell inbox — an Instagram-style activity feed. Rows are grouped into Today / This week / This
/// month / Earlier, newest first, each deep-linking (via `onOpen`) to the screen its push points at.
/// Reads the derived feed from [[MockDataStore]] `activityFeed(isInstructor:)`; unread state and the
/// first-seen sort time come from [[ActivityLedger]]. Notification *preferences* live in Settings, not
/// here — this screen is purely the received-activity list.
struct NotificationCenterView: View {
    let isInstructor: Bool
    /// Deep-link handler supplied by the presenting shell — closes the sheet and routes to the tab.
    let onOpen: (PushTopic?) -> Void

    @Environment(MockDataStore.self) private var data
    @Environment(\.dismiss) private var dismiss

    private var items: [ActivityItem] { data.activityFeed(isInstructor: isInstructor) }

    private var grouped: [(ActivityBucket, [ActivityItem])] {
        let ledger = ActivityLedger.shared
        let now = Date()
        let byBucket = Dictionary(grouping: items) { ActivityBucket.of(ledger.date(for: $0), now: now) }
        return ActivityBucket.allCases.compactMap { bucket in
            guard let rows = byBucket[bucket], !rows.isEmpty else { return nil }
            return (bucket, rows)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    EmptyStateView(
                        icon: "bell",
                        title: "You're all caught up",
                        message: "Requests, messages, reviews and other activity will show up here."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    feed
                }
            }
            .background(Color.flowWhite)
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Color.flowePinkDeep)
                }
            }
        }
        // Stamp first-seen times when the list appears; mark the whole feed read only on the way out,
        // so a row the user just received still shows its "new" dot while they're looking at it.
        .onAppear { ActivityLedger.shared.observe(items) }
        .onDisappear { ActivityLedger.shared.markOpened(isInstructor: isInstructor) }
    }

    private var feed: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(grouped, id: \.0.id) { bucket, rows in
                    Text(bucket.title)
                        .font(FloweFont.mono(11))
                        .foregroundStyle(Color.floweMuted)
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .padding(.bottom, 6)
                    ForEach(rows) { item in
                        Button {
                            onOpen(item.kind.topic)
                        } label: {
                            ActivityRow(
                                item: item,
                                date: ActivityLedger.shared.date(for: item),
                                unread: ActivityLedger.shared.isUnread(item, isInstructor: isInstructor)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.bottom, 24)
        }
    }
}

/// One feed row: actor avatar with a small kind badge, a localized sentence, an optional context line,
/// a relative timestamp, and an unread dot.
private struct ActivityRow: View {
    let item: ActivityItem
    let date: Date
    let unread: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(FloweFont.sans(14))
                    .foregroundStyle(Color.floweInk)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail2 = item.detail2, !detail2.isEmpty {
                    Text(detail2)
                        .font(FloweFont.sans(12))
                        .foregroundStyle(Color.floweMuted)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Text(date, format: .relative(presentation: .named))
                    .font(FloweFont.sans(11))
                    .foregroundStyle(Color.floweMuted)
                if unread {
                    Circle().fill(Color.flowePinkDeep).frame(width: 8, height: 8)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(unread ? Color.flowePinkDeep.opacity(0.04) : Color.clear)
        .contentShape(Rectangle())
    }

    private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            AvatarView(id: item.avatarID, photo: item.avatarPhoto, size: 46)
            Image(systemName: item.kind.icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 19, height: 19)
                .background(item.kind.tint, in: Circle())
                .overlay(Circle().stroke(Color.flowWhite, lineWidth: 2))
        }
    }

    /// The localized sentence. Whole-sentence interpolation (not name + fragment) so translators —
    /// including RTL Arabic/Hebrew — control word order.
    private var title: Text {
        let who = item.actorName.isEmpty ? String(localized: "Someone") : item.actorName
        switch item.kind {
        case .bookingRequest:   return Text("\(who) requested a \(item.detail) session")
        case .bookingConfirmed: return Text("\(who) confirmed your \(item.detail) session")
        case .bookingCancelled: return Text("\(who) cancelled a \(item.detail) session")
        case .attendanceNeeded: return Text("Mark attendance for your session with \(who)")
        case .feeOwed:          return Text("\(who) late-cancelled — fee owed")
        case .message:          return Text("\(who) sent you a message")
        case .reviewReceived:   return Text("\(who) left you a \(item.rating ?? 0)-star review")
        case .coverageOffer:    return Text("You've been asked to cover a \(item.detail) session")
        case .coverageClaim:    return Text("\(who) can cover your session")
        case .coverageCovered:  return Text("\(who) will cover your upcoming session")
        case .comment:          return Text("\(who) commented on your post")
        case .like:             return Text("\(who) liked your post")
        case .recommendation:   return Text("\(who) recommended you")
        case .eventJoinRequest: return Text("\(who) asked to join \(item.detail)")
        case .opportunityApplication: return Text("\(who) applied to \(item.detail)")
        case .applicationAdvanced:    return Text("\(who) moved your application forward — \(item.detail)")
        case .applicationHired:       return Text("\(who) hired you — \(item.detail)")
        case .applicationDeclined:    return Text("Update on your application — \(item.detail)")
        }
    }
}
