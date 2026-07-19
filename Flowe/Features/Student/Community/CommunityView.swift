import SwiftUI

/// Community tab: a header, a horizontal Stories strip of the top instructors,
/// and the scrolling feed of posts.
struct CommunityView: View {
    @Environment(MockDataStore.self) private var data

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Stories strip — only when there are instructors to show
                if !data.publishedInstructors.isEmpty {
                    storiesStrip
                    Divider().overlay(Color.floweBorder)
                }

                // Feed
                if data.posts.isEmpty {
                    EmptyStateView(
                        icon: "bubble.left.and.bubble.right",
                        title: "Nothing here yet",
                        message: "Reviews, tips and check-ins from the community will show up here."
                    )
                    .padding(.top, 80)
                } else {
                    ForEach(data.posts) { post in
                        PostRowView(post: post)
                        Divider().overlay(Color.floweBorder)
                    }
                }
            }
        }
        .background(Color.flowWhite)
        .safeAreaInset(edge: .top, spacing: 0) {
            header
        }
        .task { await data.syncCatalog() }
    }

    private var header: some View {
        HStack {
            Text("Community")
                .font(FloweFont.serif(20))
                .foregroundStyle(Color.floweInk)

            Spacer()

            Button {
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(FlowGradients.gradDark)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(Color.flowWhite)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.floweBorder)
                .frame(height: 1)
        }
    }

    private var storiesStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(data.publishedInstructors.prefix(5)) { ins in
                    VStack(spacing: 4) {
                        AvatarView(id: ins.img, size: 52, ring: true)
                        Text(ins.firstName)
                            .font(FloweFont.sans(9))
                            .foregroundStyle(Color.floweInk)
                            .lineLimit(1)
                            .frame(width: 48)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }
}

#Preview {
    CommunityView()
        .environment(MockDataStore.preview)
        .environment(AppSettings())
        .environment(AppSession())
}
