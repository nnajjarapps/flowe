import SwiftUI

/// A single student review on the instructor profile: name, star rating, relative time, and body.
/// Backed by a real `Review` anchored to a completed booking — see `ReviewService`.
struct ReviewRow: View {
    let review: Review

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                // Students have no public listing photo, so the initial stands in.
                InitialAvatar(name: review.displayName, size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(review.displayName)
                        .font(FloweFont.serif(15, .medium))
                        .foregroundStyle(Color.floweInk)
                    Text(review.relativeTime)
                        .font(FloweFont.mono(9))
                        .foregroundStyle(Color.floweMuted)
                }

                Spacer(minLength: 0)

                StarRatingView(rating: Double(review.rating), size: 11)
            }

            if !review.text.isEmpty {
                Text(review.text)
                    .font(FloweFont.sans(13))
                    .foregroundStyle(Color.floweInk.opacity(0.85))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floweCard(cornerRadius: 16)
    }
}

/// Circular monogram — for students, who have no listing photo to show.
struct InitialAvatar: View {
    let name: String
    var size: CGFloat = 40

    private var initial: String {
        String(name.trimmingCharacters(in: .whitespaces).first.map(String.init)?.uppercased() ?? "?")
    }

    var body: some View {
        Circle()
            .fill(Color.flowePink.opacity(0.15))
            .frame(width: size, height: size)
            .overlay(
                Text(initial)
                    .font(FloweFont.serif(size * 0.4, .medium))
                    .foregroundStyle(Color.flowePinkDeep)
            )
    }
}

#Preview {
    ReviewRow(
        review: Review(
            bookingID: "b1", instructorID: "i1", studentID: "s1",
            studentName: "Mia Tanaka", rating: 5,
            text: "Elena's cueing is unreal — I finally understand what engaging my core actually feels like.",
            createdAt: Date().addingTimeInterval(-2 * 86_400)
        )
    )
    .padding()
    .background(Color.flowWhite)
}
