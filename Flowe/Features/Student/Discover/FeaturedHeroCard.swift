import SwiftUI

/// 200pt tall Discover hero card featuring a real instructor: their photo, rating, name,
/// location/session types, and price. Pink scrim + blurred price pill.
struct FeaturedHeroCard: View {
    @Environment(AppSettings.self) private var settings
    let instructor: Instructor
    let action: () -> Void

    private var locationLine: String {
        var parts: [String] = []
        if !instructor.city.isEmpty { parts.append(instructor.city) }
        parts.append(contentsOf: instructor.sessionTypes)
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(id: instructor.img, photo: instructor.photo, width: 700, height: 400)
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
                    if instructor.reviews > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 11))
                            Text("\(String(format: "%.1f", instructor.rating)) · \(instructor.reviews) reviews")
                                .font(FloweFont.mono(11))
                        }
                        .foregroundStyle(.white)
                    }

                    Text(instructor.name)
                        .font(FloweFont.serif(18))
                        .foregroundStyle(.white)

                    if !locationLine.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "mappin")
                                .font(.system(size: 11))
                            Text(locationLine)
                                .font(FloweFont.sans(12))
                        }
                        .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(16)

                // Top-right blurred price pill
                if instructor.price > 0 {
                    Text("\(settings.money(instructor.price))/session")
                        .font(FloweFont.sans(12, .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    let data = MockDataStore.preview
    return Group {
        if let first = data.instructors.first {
            FeaturedHeroCard(instructor: first) {}
        }
    }
    .padding()
    .background(Color.flowWhite)
    .environment(AppSettings())
}
