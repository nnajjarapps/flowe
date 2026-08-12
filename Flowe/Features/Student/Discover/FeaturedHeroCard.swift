import SwiftUI

/// 200pt tall Discover hero card featuring a real instructor: their photo, rating, name,
/// location/session types, and price. Pink scrim + blurred price pill.
struct FeaturedHeroCard: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppSession.self) private var session
    let instructor: Instructor
    let action: () -> Void

    /// Exact address, hidden from a guest (5.1.1(v) privacy) — session types still show.
    private var addressText: String { session.isGuest ? "" : instructor.address }

    /// Whether there is anything to show in the location line (studio address and/or session types).
    private var hasLocationLine: Bool {
        !addressText.isEmpty || !instructor.sessionTypes.isEmpty
    }

    /// Studio address (verbatim) followed by localized session types, joined with " · " via Text
    /// concatenation — a joined String would render the session types as verbatim English.
    private var locationText: Text {
        var pieces: [Text] = []
        if !addressText.isEmpty { pieces.append(Text(addressText)) }
        pieces.append(contentsOf: instructor.sessionTypes.map { Text(localizedTag: $0) })
        return pieces.enumerated().reduce(Text("")) { acc, e in
            acc + (e.offset == 0 ? Text("") : Text(" · ")) + e.element
        }
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

                    if hasLocationLine {
                        HStack(spacing: 4) {
                            Image(systemName: "mappin")
                                .font(.system(size: 11))
                            locationText
                                .font(FloweFont.sans(12))
                        }
                        .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(16)

                // Top-right blurred price pill
                if instructor.price > 0 {
                    // "from ₪X/session" = starting price. Nested localization reuses the existing
                    // "from %@" and "%@/session" keys, so no new positional string is needed.
                    Text("\(String(localized: "from \(settings.money(instructor.price))"))/session")
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
        // Standard press feedback; the hero's entrance scale-in is applied by DiscoverView.
        .flowePressable()
    }
}
