import SwiftUI

/// A reusable group discussion thread (Flowe Community). One chat UI, driven by closures, so it serves
/// both an **event** discussion and an instructor **circle** chat — each supplies its own comment source,
/// send action, and sync (all keyed on a parent id in the shared community-comment store). Delete-own /
/// block-author and ContentFilter screening are generic over `PostComment`. See [[Flowe-Community]].
struct DiscussionSheet: View {
    @Environment(MockDataStore.self) private var data
    @Environment(\.dismiss) private var dismiss

    let title: LocalizedStringKey
    /// Copy for the empty state, e.g. "Say hi to the others going to <event>."
    let emptyHint: String
    /// The current comments (re-read on each render as the store updates).
    let comments: () -> [PostComment]
    /// Post a message to this thread (the store gates who may).
    let onSend: (String) -> Void
    /// Pull the thread from the shared store.
    let onSync: () async -> Void

    @State private var draft = ""
    @State private var filterMessage: String?
    @State private var blockTarget: (id: String, name: String)?

    private var items: [PostComment] { comments() }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if items.isEmpty { emptyState } else { ForEach(items) { row($0) } }
                        }
                        .padding(16)
                    }
                    .onChange(of: items.count) {
                        withAnimation { proxy.scrollTo(items.last?.persistentModelID, anchor: .bottom) }
                    }
                }
                composer
            }
            .background(Color.flowWhite)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Color.flowePinkDeep).fontWeight(.semibold)
                }
            }
            .task { await onSync() }
            .refreshable { await onSync() }
            .floweMessage(
                isPresented: .init(get: { filterMessage != nil },
                                   set: { if !$0 { filterMessage = nil } }),
                title: "Check your message",
                detail: filterMessage
            ) { filterMessage = nil }
            .confirmationDialog("Block this person?",
                                isPresented: .init(get: { blockTarget != nil }, set: { if !$0 { blockTarget = nil } }),
                                titleVisibility: .visible, presenting: blockTarget) { t in
                Button("Block", role: .destructive) { data.block(id: t.id, name: t.name); blockTarget = nil }
                Button("Cancel", role: .cancel) { blockTarget = nil }
            } message: { _ in
                Text("You won't see their messages. You can undo this in Settings.")
            }
        }
    }

    private func row(_ c: PostComment) -> some View {
        let mine = data.isMine(c)
        let resolved = data.displayIdentity(ownerID: c.authorID, fallbackName: c.authorName).name
        let name = resolved.isEmpty ? c.authorName : resolved
        return HStack(alignment: .top, spacing: 10) {
            if let photo = data.studentPhoto(forOwnerID: c.authorID) {
                AvatarView(id: "", photo: photo, size: 34)
            } else {
                InitialAvatar(name: name, size: 34)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(mine ? String(localized: "You") : (name.isEmpty ? String(localized: "Someone") : name))
                        .font(FloweFont.sans(13, .medium))
                        .foregroundStyle(Color.floweInk)
                    Text(Self.time(c.createdAt))
                        .font(FloweFont.mono(8))
                        .foregroundStyle(Color.floweMuted)
                }
                Text(c.text)
                    .font(FloweFont.sans(14))
                    .foregroundStyle(Color.floweInk.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .contextMenu {
            if mine {
                Button("Delete", systemImage: "trash", role: .destructive) { data.deleteComment(c) }
            } else {
                Button("Block \(name.isEmpty ? String(localized: "this person") : name)",
                       systemImage: "hand.raised", role: .destructive) {
                    blockTarget = (c.authorID, name)
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Message the group…", text: $draft, axis: .vertical)
                .font(FloweFont.sans(14))
                .lineLimit(1...4)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color.floweCardBg, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.floweBorder, lineWidth: 1))
                .accessibilityIdentifier("discussion.field")
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(canSend ? AnyShapeStyle(FlowGradients.gradDark)
                                        : AnyShapeStyle(Color.flowePinkSoft), in: Circle())
            }
            .disabled(!canSend)
            .accessibilityLabel("Send message")
            .accessibilityIdentifier("discussion.send")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.flowWhite)
        .overlay(alignment: .top) { Rectangle().fill(Color.floweBorder).frame(height: 1) }
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        // Public discussion → screened like any public text (App Store 1.2).
        if let rejection = ContentFilter.reject(draft) { filterMessage = rejection.message; return }
        Haptic.tap()
        onSend(draft)
        draft = ""
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .foregroundStyle(Color.flowePinkSoft)
            Text("Start the conversation")
                .font(FloweFont.serif(15))
                .foregroundStyle(Color.floweInk)
            Text(emptyHint)
                .font(FloweFont.sans(13))
                .foregroundStyle(Color.floweMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    /// Locale- and RTL-aware compact timestamp (day + abbreviated month + time). `Date.FormatStyle` picks
    /// the right digits, month names, and 12-/24-hour clock for EN/AR/HE — no hardcoded pattern to break.
    static func time(_ d: Date) -> String {
        d.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}
