import SwiftUI

/// The people this user has blocked, and the way back. App Store Review Guideline 1.2 asks for the
/// ability to block; a block the user can't undo or even see would be a trap rather than a tool.
struct BlockedUsersView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MockDataStore.self) private var data

    var body: some View {
        NavigationStack {
            Group {
                if data.blocked.isEmpty {
                    EmptyStateView(
                        icon: "hand.raised",
                        title: "No blocked users",
                        message: "People you block won't be able to reach you here, and you won't see their messages or profile."
                    )
                } else {
                    List {
                        Section {
                            ForEach(data.blocked) { entry in
                                HStack {
                                    Text(entry.displayName)
                                        .font(FloweFont.sans(14))
                                        .foregroundStyle(Color.floweInk)
                                    Spacer()
                                    Button("Unblock") { data.unblock(entry.blockedID) }
                                        .font(FloweFont.sans(13, .medium))
                                        .buttonStyle(.borderless)
                                        .tint(Color.flowePinkDeep)
                                }
                            }
                        } footer: {
                            Text("Unblocking makes their messages and profile visible to you again.")
                        }
                    }
                }
            }
            .background(Color.flowWhite)
            .navigationTitle("Blocked Users")
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
}

#Preview {
    BlockedUsersView()
        .environment(MockDataStore.preview)
}
