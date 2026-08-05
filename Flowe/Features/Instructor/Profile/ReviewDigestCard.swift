import SwiftUI

#if canImport(FoundationModels)
import FoundationModels

/// "What students say" — an **on-device** summary of an instructor's reviews (a one-line vibe + a few
/// praised-for themes), shown atop the reviews list as social proof. Pure progressive enhancement:
/// renders nothing until the summary is ready, and only runs when there are enough reviews. The caller
/// gates the whole card on `FloweAI.isAvailable` + `#available(iOS 26, *)`. See [[FloweIntelligence]].
@available(iOS 26, *)
struct ReviewDigestCard: View {
    /// Review bodies to summarize — the caller passes non-empty text only.
    let reviewTexts: [String]

    @State private var digest: ReviewDigest?
    @State private var didRun = false

    var body: some View {
        Group {
            if let digest, !digest.vibe.isEmpty {
                card(digest)
            }
        }
        // Summaries are cheap + free on-device; compute once per view lifetime when there's enough to say.
        .task {
            guard !didRun, reviewTexts.count >= 3 else { return }
            didRun = true
            digest = try? await FloweIntelligence.shared.digestReviews(reviewTexts)
        }
    }

    private func card(_ d: ReviewDigest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("WHAT STUDENTS SAY").font(FloweFont.mono(9)).foregroundStyle(Color.floweMuted)
                Spacer()
                AIPrivacyBadge()
            }
            Text(d.vibe)
                .font(FloweFont.serif(16, .medium))
                .foregroundStyle(Color.floweInk)
                .fixedSize(horizontal: false, vertical: true)
            if !d.praisedFor.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(d.praisedFor, id: \.self) { theme in
                            Text(theme)
                                .font(FloweFont.sans(11, .medium))
                                .foregroundStyle(Color.flowePinkDeep)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.flowePink.opacity(0.12), in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.flowePink.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.flowePink.opacity(0.15), lineWidth: 1))
    }
}
#endif
