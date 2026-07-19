import SwiftUI

/// 200pt tall Discover hero card with fixed pilates image, pink scrim, and a blurred price pill.
struct FeaturedHeroCard: View {
    @Environment(AppSettings.self) private var settings
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(id: "1518611012118-696072aa579a", width: 700, height: 400)
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .clipped()

                // Bottom pink scrim
                LinearGradient(
                    colors: [
                        Color.flowePinkDeep.opacity(0.75),
                        Color.flowePink.opacity(0.2),
                        Color.clear
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )

                // Bottom-left copy
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11))
                        Text("4.9 · 112 reviews")
                            .font(FloweFont.mono(11))
                    }
                    .foregroundStyle(.white)

                    Text("Sofia Marchetti")
                        .font(FloweFont.serif(18))
                        .foregroundStyle(.white)

                    HStack(spacing: 4) {
                        Image(systemName: "mappin")
                            .font(.system(size: 11))
                        Text("New York · Mat · Reformer · Tower")
                            .font(FloweFont.sans(12))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                }
                .padding(16)

                // Top-right blurred price pill
                Text("\(settings.money(95))/session")
                    .font(FloweFont.sans(12, .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    FeaturedHeroCard {}
        .padding()
        .background(Color.flowWhite)
        .environment(AppSettings())
}
