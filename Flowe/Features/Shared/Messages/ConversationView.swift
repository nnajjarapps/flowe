import SwiftUI

/// A chat thread with one counterpart: a scrolling stack of `MessageBubble`s and a bottom composer.
/// Messages persist to the shared store, so both sides see the thread (see `MessagingService`).
struct ConversationView: View {
    let counterpart: Counterpart

    @Environment(MockDataStore.self) private var data

    @State private var draft = ""

    private var messages: [Message] { data.thread(with: counterpart.id) }

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
                                    MessageBubble(
                                        isOutgoing: message.senderID == data.currentUserID,
                                        text: message.text,
                                        time: message.pendingUpload
                                            ? "Sending…"
                                            : Self.timeLabel(message.sentAt)
                                    )
                                    .id(message.persistentModelID)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                }
                .onChange(of: messages.count) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(messages.last?.persistentModelID, anchor: .bottom)
                    }
                }
            }

            composer
        }
        .background(Color.flowWhite)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await data.syncThread(with: counterpart.id)
            data.markThreadRead(with: counterpart.id)
        }
        .refreshable { await data.syncThread(with: counterpart.id) }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 10) {
                    AvatarView(id: counterpart.avatarID, size: 30)
                    Text(counterpart.firstName)
                        .font(FloweFont.serif(15))
                        .foregroundStyle(Color.floweInk)
                }
            }
        }
    }

    // MARK: - Grouping

    /// Messages bucketed by day so each run gets one date stamp.
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
            .buttonStyle(.plain)
            .disabled(!canSend)
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
        data.sendMessage(to: counterpart, text: draft)
        draft = ""
    }
}

#Preview {
    NavigationStack {
        ConversationView(counterpart: Counterpart(id: "preview", name: "Alex Rivera"))
    }
    .environment(MockDataStore.preview)
    .environment(AppSession())
}
