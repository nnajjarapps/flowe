import SwiftUI

/// A chat thread with one counterpart: a scrolling stack of `MessageBubble`s and a bottom composer.
/// Messages persist to the shared store, so both sides see the thread (see `MessagingService`).
struct ConversationView: View {
    let counterpart: Counterpart

    @Environment(MockDataStore.self) private var data
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var showReport = false
    @State private var confirmBlock = false
    @State private var confirmDeleteConversation = false
    @State private var showStudentProfile = false
    @State private var showRecommend = false
    /// On-device smart-reply suggestions (Flowe Intelligence) for the latest incoming message.
    @State private var suggestions: [String] = []

    private var messages: [Message] { data.thread(with: counterpart.id) }

    /// The partner's presence line for the header: "Active now" (active < 5 min) or "Last seen …". nil
    /// when the backend didn't permit us to see it (they hid it / reciprocity / never active).
    /// A "deleted for everyone" tombstone, aligned like a real bubble: "You deleted this message" for
    /// the sender, "This message was deleted" for the recipient.
    @ViewBuilder private func deletedRow(mine: Bool) -> some View {
        HStack(spacing: 0) {
            if mine { Spacer(minLength: 48) }
            HStack(spacing: 6) {
                Image(systemName: "slash.circle").font(.system(size: 12))
                Text(mine ? "You deleted this message" : "This message was deleted")
                    .font(FloweFont.sans(14)).italic()
            }
            .foregroundStyle(Color.floweMuted)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.floweCardBg, in: RoundedRectangle(cornerRadius: 16))
            if !mine { Spacer(minLength: 48) }
        }
    }

    private var presenceLine: (text: String, online: Bool)? {
        guard let seen = data.lastSeen(ownerID: counterpart.id) else { return nil }
        if Date().timeIntervalSince(seen) < 300 { return (String(localized: "Active now"), true) }
        return (String(localized: "Last seen \(Self.presenceRelative.localizedString(for: seen, relativeTo: Date()))"), false)
    }

    private static let presenceRelative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if messages.isEmpty {
                            emptyHint
                        } else {
                            ForEach(groupedByDay, id: \.day) { group in
                                dateStamp(group.day)
                                ForEach(group.messages) { message in
                                    if message.deleted {
                                        deletedRow(mine: message.senderID == data.currentUserID)
                                            .id(message.persistentModelID)
                                            .contextMenu {
                                                Button(role: .destructive) { data.deleteForMe(message) } label: {
                                                    Label("Delete for me", systemImage: "trash")
                                                }
                                            }
                                    } else {
                                        MessageBubble(
                                            isOutgoing: message.senderID == data.currentUserID,
                                            text: message.displayText,
                                            time: message.pendingUpload
                                                ? "Sending…"
                                                : Self.timeLabel(message.sentAt)
                                        )
                                        .id(message.persistentModelID)
                                        .contextMenu {
                                            // "Delete for everyone" only for my own message, within 24h (WhatsApp rule).
                                            if message.canDeleteForEveryone(currentUserID: data.currentUserID) {
                                                Button(role: .destructive) { data.deleteForEveryone(message) } label: {
                                                    Label("Delete for everyone", systemImage: "trash")
                                                }
                                            }
                                            Button(role: .destructive) { data.deleteForMe(message) } label: {
                                                Label("Delete for me", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                            }
                            // Seen / Delivered under our own last message — only while it IS the latest,
                            // so a counterpart's reply (which already implies they saw it) drops the tag.
                            if let last = messages.last, last.senderID == data.currentUserID {
                                deliveryStatus(for: last)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                    // Drives each MessageBubble's insertion transition as the
                    // thread grows, so a sent/received bubble slides+fades in.
                    .animation(FloweMotion.spring, value: messages.count)
                }
                .onChange(of: messages.count) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(messages.last?.persistentModelID, anchor: .bottom)
                    }
                }
            }

            suggestionRow
            composer
        }
        .background(Color.flowWhite)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await data.syncThread(with: counterpart.id)
            data.markThreadRead(with: counterpart.id)
        }
        // Regenerate smart replies whenever the latest message changes (a new incoming message arrives,
        // or our own send clears them). On-device + free, so recomputing per message is fine.
        .task(id: messages.last?.persistentModelID) { await refreshSuggestions() }
        // Manual pull-to-refresh: pulls the counterpart's new replies and their Seen receipt
        // instantly (there's no live socket — Seen/Delivered otherwise updates only on open/foreground).
        .refreshable {
            await data.syncThread(with: counterpart.id)
            data.markThreadRead(with: counterpart.id)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    // Only an instructor opens a student's profile; a student's counterpart is the
                    // instructor, whose profile is reached from Discover instead.
                    if session.authState == .instructor { showStudentProfile = true }
                } label: {
                    HStack(spacing: 10) {
                        AvatarView(id: counterpart.avatarID, photo: counterpart.photo, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(counterpart.firstName)
                                .font(FloweFont.serif(15))
                                .foregroundStyle(Color.floweInk)
                            if let presence = presenceLine {
                                Text(presence.text)
                                    .font(FloweFont.sans(11))
                                    .foregroundStyle(presence.online ? Color.green : Color.floweMuted)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(session.authState != .instructor)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Peer recommendation (Flowe Pro Phase 5): an instructor endorsing a fellow instructor
                    // they've worked with. Gated on the signed-in user being an instructor AND the
                    // counterpart being a cached instructor — instructors meet via opportunities/coverage/
                    // DMs, so the thread is the natural place to write one. See [[FlowePro]].
                    if session.authState == .instructor, data.instructor(ownerID: counterpart.id) != nil {
                        Button("Recommend \(counterpart.firstName)", systemImage: "hand.thumbsup") {
                            showRecommend = true
                        }
                    }
                    Button("Report \(counterpart.firstName)", systemImage: "flag") {
                        showReport = true
                    }
                    Button("Block \(counterpart.firstName)", systemImage: "hand.raised", role: .destructive) {
                        confirmBlock = true
                    }
                    Button("Delete conversation", systemImage: "trash", role: .destructive) {
                        confirmDeleteConversation = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Color.floweInk)
                }
                .accessibilityLabel("More options")
                .accessibilityIdentifier("conversation.moderation")
            }
        }
        .sheet(isPresented: $showRecommend) {
            RecommendationComposeSheet(toID: counterpart.id, toName: counterpart.name)
        }
        .sheet(isPresented: $showReport) {
            ReportSheet(
                reportedID: counterpart.id,
                reportedName: counterpart.name,
                content: .message,
                contentID: messages.last?.remoteID ?? "",
                // Report the tail of the thread — a single message rarely carries the context.
                snapshot: messages.suffix(10).map(\.displayText).joined(separator: "\n")
            )
        }
        .sheet(isPresented: $showStudentProfile) {
            StudentProfileView(
                studentID: counterpart.id,
                studentName: counterpart.name,
                onMessage: { showStudentProfile = false },   // Message returns to this thread
                onClose: { showStudentProfile = false }
            )
        }
        .confirmationDialog("Block \(counterpart.firstName)?",
                            isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                data.block(id: counterpart.id, name: counterpart.name)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won't see their messages or their profile. You can undo this in Settings.")
        }
        .confirmationDialog("Delete conversation?",
                            isPresented: $confirmDeleteConversation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                data.deleteConversation(with: counterpart.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes your conversation with \(counterpart.firstName) from your inbox.")
        }
    }

    // MARK: - Grouping

    /// Messages bucketed by day so each run gets one date stamp.
    /// "Seen" (once the counterpart's read marker reaches this message) or "Delivered" (it's on the
    /// server but unread). Nothing while it's still sending — the bubble already reads "Sending…".
    @ViewBuilder
    private func deliveryStatus(for message: Message) -> some View {
        let readAt = data.lastReadAt(conversationID: message.conversationID, by: counterpart.id)
        if let readAt, readAt >= message.sentAt {
            statusLine("Seen", color: Color.flowePinkDeep)
        } else if !message.pendingUpload {
            statusLine("Delivered", color: Color.floweMuted)
        }
    }

    private func statusLine(_ text: String, color: Color) -> some View {
        Text(text)
            .font(FloweFont.mono(10))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 2)
    }

    private var groupedByDay: [(day: String, messages: [Message])] {
        let grouped = Dictionary(grouping: messages) { Self.dayLabel($0.sentAt) }
        return grouped
            .map { (day: $0.key, messages: $0.value.sorted { $0.sentAt < $1.sentAt }) }
            .sorted { ($0.messages.first?.sentAt ?? .distantPast) < ($1.messages.first?.sentAt ?? .distantPast) }
    }

    static func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "TODAY" }
        if calendar.isDateInYesterday(date) { return "YESTERDAY" }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date).uppercased()
    }

    static func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Pieces

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 30))
                .foregroundStyle(Color.flowePinkSoft)
            Text("Say hello to \(counterpart.firstName)")
                .font(FloweFont.serif(15))
                .foregroundStyle(Color.floweInk)
            Text("Send a message to start the conversation.")
                .font(FloweFont.sans(13))
                .foregroundStyle(Color.floweMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func dateStamp(_ label: String) -> some View {
        Text(label)
            .font(FloweFont.mono(9))
            .foregroundStyle(Color.floweMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.floweCardBg, in: Capsule())
            .padding(.vertical, 4)
    }

    // MARK: - Smart replies (Flowe Intelligence)

    /// A horizontal rail of on-device reply suggestions above the composer. Shown only when the model is
    /// available, there are suggestions, and the user hasn't started typing. Tapping one loads it into
    /// the composer to review/edit — never auto-sends. See [[FloweIntelligence]].
    @ViewBuilder
    private var suggestionRow: some View {
        if #available(iOS 26, *), FloweAI.isAvailable, !suggestions.isEmpty, draft.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    AIPrivacyBadge()
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            Haptic.tap()
                            draft = suggestion
                            suggestions = []
                        } label: {
                            Text(suggestion)
                                .font(FloweFont.sans(13))
                                .foregroundStyle(Color.flowePinkDeep)
                                .lineLimit(1)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Color.flowePink.opacity(0.10), in: Capsule())
                                .overlay(Capsule().stroke(Color.flowePink.opacity(0.2), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color.flowWhite)
        }
    }

    /// Regenerate suggestions for the latest incoming message. Clears them when we spoke last (nothing
    /// to reply to) or the model is unavailable.
    private func refreshSuggestions() async {
        if #available(iOS 26, *), FloweAI.isAvailable {
            guard let last = messages.last, last.senderID != data.currentUserID else {
                suggestions = []
                return
            }
            let recent = messages.suffix(8).map { (mine: $0.senderID == data.currentUserID, text: $0.displayText) }
            suggestions = (try? await FloweIntelligence.shared.suggestReplies(recent: recent)) ?? []
        } else {
            suggestions = []
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("", text: $draft, prompt: Text("Message…").foregroundColor(Color.floweMuted), axis: .vertical)
                    .font(FloweFont.sans(14))
                    .foregroundStyle(Color.floweInk)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("conversation.field")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.floweCardBg)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.floweBorder, lineWidth: 1))

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(canSend ? AnyShapeStyle(FlowGradients.gradDark) : AnyShapeStyle(Color.flowePinkSoft))
                    .clipShape(Circle())
            }
            .flowePressable()
            .disabled(!canSend)
            .accessibilityLabel("Send message")
            .accessibilityIdentifier("conversation.send")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.flowWhite)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.floweBorder).frame(height: 1)
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        Haptic.tap()
        data.sendMessage(to: counterpart, text: draft)
        draft = ""
    }
}
