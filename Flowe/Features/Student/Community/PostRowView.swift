import SwiftUI

/// A single Community feed post: header, optional instructor image band,
/// body text, optional tip banner, and the like / comment / save actions row.
struct PostRowView: View {
    @Environment(MockDataStore.self) private var data

    let post: FeedPost

    private var subtitle: String {
        let action: String
        switch post.type {
        case .review:  action = "reviewed \(post.instructor ?? "")"
        case .checkin: action = "checked in with \(post.instructor ?? "")"
        case .tip:     action = "shared a tip"
        }
        return "\(action) · \(post.time)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                AvatarView(id: post.userImg, size: 36)

                VStack(alignment: .leading, spacing: 1) {
                    Text(post.user)
                        .font(FloweFont.sans(13, .medium))
                        .foregroundStyle(Color.floweInk)
                    Text(subtitle)
                        .font(FloweFont.mono(11))
                        .foregroundStyle(Color.floweMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.floweMuted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            // Instructor image band
            if let instImg = post.instImg {
                ZStack(alignment: .topTrailing) {
                    RemoteImage(id: instImg, width: 600, height: 280)
                        .frame(height: 140)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .overlay(FlowGradients.grad.opacity(0.5))

                    if let rating = post.rating {
                        HStack(spacing: 2) {
                            ForEach(0..<rating, id: \.self) { _ in
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            // Body text
            Text(post.text)
                .font(FloweFont.sans(13))
                .foregroundStyle(Color.floweInk)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            // Tip banner
            if post.type == .tip {
                HStack(spacing: 8) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.flowePinkDeep)
                    Text("Instructor Tip")
                        .font(FloweFont.sans(11, .medium))
                        .foregroundStyle(Color.flowePinkDeep)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.flowePink.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.flowePink.opacity(0.19), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            // Actions row
            HStack(spacing: 16) {
                Button {
                    data.toggleLike(post)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: post.liked ? "heart.fill" : "heart")
                            .font(.system(size: 17))
                            .foregroundStyle(post.liked ? Color.flowePink : Color.floweMuted)
                        Text("\(post.likes)")
                            .font(FloweFont.sans(12))
                            .foregroundStyle(post.liked ? Color.flowePink : Color.floweMuted)
                    }
                }

                Button {
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 17))
                            .foregroundStyle(Color.floweMuted)
                        Text("\(post.comments)")
                            .font(FloweFont.sans(12))
                            .foregroundStyle(Color.floweMuted)
                    }
                }

                Spacer()

                Button {
                    data.toggleSave(post)
                } label: {
                    Image(systemName: post.saved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 17))
                        .foregroundStyle(post.saved ? Color.flowePinkDeep : Color.floweMuted)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
    }
}

#Preview {
    let store = MockDataStore.preview
    return ScrollView {
        VStack(spacing: 0) {
            ForEach(store.posts) { post in
                PostRowView(post: post)
                Divider()
            }
        }
    }
    .background(Color.flowWhite)
    .environment(store)
}
