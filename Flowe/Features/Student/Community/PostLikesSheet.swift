import SwiftUI

/// The Instagram-style "Liked by" list: everyone who liked a post, open to any viewer. Reached by
/// tapping the like count on a feed row. Names + avatars are resolved live (an author who edits their
/// profile shows their current one), and the list refreshes on open so a like that landed since the
/// last feed sweep still appears.
struct PostLikesSheet: View {
    @Environment(MockDataStore.self) private var data
    @Environment(\.dismiss) private var dismiss

    let post: FeedPost

    @State private var loading = true

    private var likers: [MockDataStore.PostLiker] { data.likers(for: post) }

    var body: some View {
        NavigationStack {
            Group {
                if likers.isEmpty && loading {
                    loadingState
                } else if likers.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(likers.enumerated()), id: \.element.id) { index, liker in
                                row(liker)
                                    .floweAppear(index)
                                if liker.id != likers.last?.id {
                                    Divider().overlay(Color.floweBorder).padding(.leading, 68)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .background(Color.flowWhite)
            .navigationTitle("Likes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Color.flowePinkDeep)
                }
            }
        }
        // Pull the freshest likers (and warm their profiles) when the sheet opens. The cached list
        // shows instantly underneath; this fills in anyone who liked since the last feed sync.
        .task {
            await data.refreshLikers(for: post)
            loading = false
        }
    }

    private func row(_ liker: MockDataStore.PostLiker) -> some View {
        HStack(spacing: 14) {
            AvatarView(id: liker.img, photo: liker.photo, size: 44)
            Text(liker.name.isEmpty ? String(localized: "Someone") : liker.name)
                .font(FloweFont.serif(15))
                .foregroundStyle(Color.floweInk)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView().tint(Color.flowePinkDeep)
            Text("Loading likes…")
                .font(FloweFont.sans(13))
                .foregroundStyle(Color.floweMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: "heart",
            title: "No likes yet",
            message: "Be the first to like this post."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
