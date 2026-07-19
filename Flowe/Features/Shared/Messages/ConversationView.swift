import SwiftUI

/// A single chat message inside a conversation thread.
struct ChatMessage: Identifiable {
    let id: Int
    let isOutgoing: Bool
    let text: String
    let time: String
}

/// A chat thread with one instructor: a scrolling stack of `MessageBubble`s and
/// a bottom composer bar (rounded field + gradient send button).
struct ConversationView: View {
    let instructor: Instructor

    @State private var draft = ""
    @State private var messages: [ChatMessage] = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if messages.isEmpty {
                            emptyHint
                        } else {
                            dateStamp

                            ForEach(messages) { msg in
                                MessageBubble(isOutgoing: msg.isOutgoing, text: msg.text, time: msg.time)
                                    .id(msg.id)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                }
                .onChange(of: messages.count) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(messages.last?.id, anchor: .bottom)
                    }
                }
            }

            composer
        }
        .background(Color.flowWhite)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 10) {
                    AvatarView(id: instructor.img, size: 30)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(instructor.firstName)
                            .font(FloweFont.serif(15))
                            .foregroundStyle(Color.floweInk)
                        Text("Active now")
                            .font(FloweFont.mono(9))
                            .foregroundStyle(Color.floweSuccess)
                    }
                }
            }
        }
    }

    // MARK: - Pieces

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 30))
                .foregroundStyle(Color.flowePinkSoft)
            Text("Say hello to \(instructor.firstName)")
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

    private var dateStamp: some View {
        Text("TODAY")
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
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let nextId = (messages.map(\.id).max() ?? 0) + 1
        messages.append(ChatMessage(id: nextId, isOutgoing: true, text: text, time: "Now"))
        draft = ""
    }
}

#Preview {
    let store = MockDataStore.preview
    return NavigationStack {
        ConversationView(instructor: store.instructors.first!)
    }
    .environment(store)
    .environment(AppSession())
}
