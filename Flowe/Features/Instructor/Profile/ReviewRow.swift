import SwiftUI

/// A single student review on the instructor profile: avatar, name, star
/// rating, relative time, and the review body. Sourced from a `FeedPost`
/// whose `type == .review`.
struct ReviewRow: View {
    let post: FeedPost

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AvatarView(id: post.userImg, size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(post.user)
                        .font(FloweFont.serif(15, .medium))
                        .foregroundStyle(Color.floweInk)
                    Text(post.time.uppercased())
                        .font(FloweFont.mono(9))
                        .foregroundStyle(Color.floweMuted)
                }

                Spacer(minLength: 0)

                if let rating = post.rating {
                    StarRatingView(rating: Double(rating), size: 11)
                }
            }

            Text(post.text)
                .font(FloweFont.sans(13))
                .foregroundStyle(Color.floweInk.opacity(0.85))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floweCard(cornerRadius: 16)
    }
}

#Preview {
    ReviewRow(
        post: FeedPost(
            legacyId: 1, type: .review,
            user: "Mia Tanaka", userImg: "1531746020798-e6953c6e8e04",
            instructor: "Elena", instImg: nil, time: "2 days ago",
            rating: 5,
            text: "Elena's cueing is unreal — I finally understand what engaging my core actually feels like. Left the session taller.",
            likes: 12, comments: 2, saved: false, liked: false
        )
    )
    .padding()
    .background(Color.flowWhite)
}
