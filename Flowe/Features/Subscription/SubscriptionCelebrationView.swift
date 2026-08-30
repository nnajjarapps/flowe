import SwiftUI

// ============================================================================
// The moment a subscription actually starts.
//
// Before this, a confirmed purchase just dismissed the paywall — the instructor
// paid ₪34.90 or ₪99.90 and the app said nothing. This is the receipt.
//
// The two tiers celebrate DIFFERENTLY because they sell different things, and
// the shape of each burst carries that:
//   • Visible BLOOMS  — petals open in a full 360° circle and drift down. You
//     have arrived in the feed; arriving spreads outward in every direction.
//   • Boost  ERUPTS   — shards launch upward in a cone on a beam of light, hang,
//     then fall with gravity. You have gone to the top; elevation goes UP.
//
// Gold for Boost is the logomark's own F colour escalated, so the senior tier
// reads senior without introducing a hue the brand does not own.
// ============================================================================

// MARK: - Per-tier art direction

private struct CelebrationStyle {
    let glyph: String
    let medallion: [Color]
    let accent: Color
    let particleColors: [Color]
    /// Full circle for the bloom; a narrow upward cone for the eruption.
    let angleRange: ClosedRange<Double>
    let isShard: Bool
    /// How far a particle falls after its outward travel. The eruption drops
    /// noticeably harder — that difference is most of what separates the two.
    let gravity: CGFloat
    let travel: ClosedRange<CGFloat>
    let count: Int
    let showsBeam: Bool

    static func of(_ tier: SubscriptionTier) -> CelebrationStyle {
        switch tier {
        case .visible:
            return .init(
                glyph: "✦",
                medallion: [.flowePink, .flowePinkDeep],
                accent: .flowePinkDeep,
                particleColors: [.flowePink, .flowePinkDeep, .flowDustyRose, .flowBlushPink],
                angleRange: 0...(2 * .pi),          // full bloom
                isShard: false,
                gravity: 26,
                travel: 88...152,
                count: 30,
                showsBeam: false
            )
        case .boost:
            return .init(
                glyph: "★",
                medallion: [Color(hex: 0xD9A441), .flowEspressoBrown],
                accent: Color(hex: 0xD9A441),
                particleColors: [Color(hex: 0xD9A441), .flowEspressoBrown,
                                 Color(hex: 0xF0DCA8), Color(hex: 0xD9A441)],
                // −160°…−20°: an upward cone, never sideways or down.
                angleRange: (-160 * .pi / 180)...(-20 * .pi / 180),
                isShard: true,
                gravity: 130,
                travel: 120...225,
                count: 34,
                showsBeam: true
            )
        }
    }
}

// MARK: - Particles

private struct Particle {
    let angle: Double
    let distance: CGFloat
    let size: CGSize
    let delay: Double
    let spin: Double
    let color: Color
}

/// Seeded so the burst is IDENTICAL every time rather than re-randomising each
/// frame — a field that reshuffles while it flies reads as noise, not confetti.
private struct Seeded: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

private func makeParticles(_ style: CelebrationStyle) -> [Particle] {
    var rng = Seeded(7)
    let span = style.angleRange.upperBound - style.angleRange.lowerBound
    return (0..<style.count).map { i in
        let base = style.angleRange.lowerBound + span * (Double(i) / Double(style.count))
        return Particle(
            angle: base + Double.random(in: -0.09...0.09, using: &rng),
            distance: CGFloat.random(in: style.travel, using: &rng),
            size: style.isShard
                ? CGSize(width: .random(in: 3...5, using: &rng), height: .random(in: 12...24, using: &rng))
                : .init(width: .random(in: 7...13, using: &rng), height: .random(in: 7...13, using: &rng)),
            delay: Double.random(in: 0...(style.isShard ? 0.16 : 0.22), using: &rng),
            spin: Double.random(in: -1.2...1.2, using: &rng),
            color: style.particleColors[i % style.particleColors.count]
        )
    }
}

// MARK: - The view

struct SubscriptionCelebrationView: View {
    let tier: SubscriptionTier
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    /// Flips once every particle has died and the copy has settled. `TimelineView(.animation)` redraws
    /// at 60fps FOREVER otherwise — and this screen has a dismiss button, so it can sit there for
    /// minutes burning frames on a canvas with nothing left to draw.
    @State private var settled = false

    private var style: CelebrationStyle { .of(tier) }
    private var particles: [Particle] { makeParticles(style) }

    /// One clock for the whole sequence. Elements read their own slice of it, so the beats stay in
    /// lockstep without a chain of nested `withAnimation` calls.
    private static let duration: Double = 2.6

    var body: some View {
        ZStack {
            background

            if !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: settled)) { timeline in
                    let t = timeline.date.timeIntervalSince(start)
                    Canvas { ctx, size in draw(ctx: &ctx, size: size, elapsed: t) }
                        .allowsHitTesting(false)
                }
            }

            content
        }
        .onAppear {
            start = Date()
            // The heavier confirmation, matching what the app already uses for a completed booking.
            if !reduceMotion { Haptic.success() }
        }
        .task {
            // duration + the longest stagger + the last entrance, then stop redrawing.
            try? await Task.sleep(for: .seconds(Self.duration + 1.0))
            settled = true
        }
    }

    // MARK: Background

    private var background: some View {
        // A warm wash that leans toward the tier's accent, over the app's cream.
        RadialGradient(
            colors: [style.accent.opacity(0.16), Color.flowWarmCream],
            center: .init(x: 0.5, y: 0.42), startRadius: 8, endRadius: 460
        )
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            if style.showsBeam && !reduceMotion {
                // Boost only: a shaft of light the bloom deliberately does not get.
                LinearGradient(colors: [style.accent.opacity(0.28), .clear],
                               startPoint: .bottom, endPoint: .top)
                    .frame(width: 180, height: 300)
                    .blur(radius: 22)
                    .offset(y: 60)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Canvas

    private func draw(ctx: inout GraphicsContext, size: CGSize, elapsed: Double) {
        let center = CGPoint(x: size.width / 2, y: size.height * 0.42)
        for p in particles {
            // 0…1 over the particle's own life, offset by its stagger.
            let raw = (elapsed - p.delay) / Self.duration
            guard raw > 0, raw < 1 else { continue }

            // Ease out hard on the way out, then let gravity take it.
            let out = 1 - pow(1 - min(raw / 0.45, 1), 3)
            let fall = max(0, (raw - 0.45) / 0.55)
            let dx = cos(p.angle) * p.distance * out
            let dy = sin(p.angle) * p.distance * out + style.gravity * fall * fall

            let fade: Double = raw < 0.15 ? raw / 0.15 : (raw > 0.6 ? max(0, 1 - (raw - 0.6) / 0.4) : 1)
            let scale = raw < 0.15 ? 0.4 + 0.6 * (raw / 0.15) : 1 - 0.4 * fall

            ctx.drawLayer { layer in
                layer.translateBy(x: center.x + dx, y: center.y + dy)
                layer.rotate(by: .radians(p.spin * raw * 4))
                layer.scaleBy(x: scale, y: scale)
                layer.opacity = fade
                let r = CGRect(x: -p.size.width / 2, y: -p.size.height / 2,
                               width: p.size.width, height: p.size.height)
                let path = style.isShard
                    ? Path(roundedRect: r, cornerRadius: 2)
                    : Path(ellipseIn: r)
                layer.fill(path, with: .color(p.color))
            }
        }
    }

    // MARK: Content

    private var content: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                // Halo: one ring pushed out from behind the medallion.
                if !reduceMotion {
                    TimelineView(.animation(paused: settled)) { timeline in
                        let t = timeline.date.timeIntervalSince(start)
                        let p = min(max((t - 0.28) / 1.0, 0), 1)
                        Circle()
                            .stroke(style.accent, lineWidth: 2)
                            .frame(width: 96, height: 96)
                            .scaleEffect(1 + 1.5 * p)
                            .opacity(p < 0.15 ? p / 0.15 * 0.75 : 0.75 * (1 - p))
                    }
                }

                Circle()
                    .fill(LinearGradient(colors: style.medallion,
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 96, height: 96)
                    .overlay(Text(style.glyph)
                        .font(FloweFont.serif(38))
                        .foregroundStyle(tier == .boost ? Color.floweInk : Color.flowWhite))
                    .shadow(color: style.accent.opacity(0.38), radius: 22, y: 12)
                    .modifier(PopIn(delay: 0.18, enabled: !reduceMotion, start: start))
            }

            Text(tier == .visible ? "You're in the feed." : "You're featured.")
                .flowFont(.displayMedium)
                .foregroundStyle(Color.floweInk)
                .multilineTextAlignment(.center)
                .padding(.top, FlowSpacing.xl)
                .modifier(RiseIn(delay: 0.62, enabled: !reduceMotion, start: start))

            Text(tier == .visible
                 ? "Students searching near you can find and book you from today."
                 : "You now appear above every other instructor in your area.")
                .flowFont(.bodyMedium)
                .foregroundStyle(Color.floweMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
                .padding(.top, FlowSpacing.sm)
                .modifier(RiseIn(delay: 0.72, enabled: !reduceMotion, start: start))

            Spacer()

            Button(action: { Haptic.tap(); onDismiss() }) {
                Text(tier == .visible ? "See my profile" : "See my placement")
                    .flowFont(.titleMedium)
                    .foregroundStyle(tier == .boost ? Color.floweInk : Color.flowWhite)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(LinearGradient(colors: style.medallion,
                                               startPoint: .leading, endPoint: .trailing))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .flowePressable()
            .padding(.horizontal, FlowSpacing.xl)
            .padding(.bottom, FlowSpacing.xxl)
            .modifier(RiseIn(delay: 0.82, enabled: !reduceMotion, start: start))
            .accessibilityIdentifier("celebration.dismiss")
        }
    }
}

// MARK: - Entrance modifiers
//
// Both read the SAME `start` date as the canvas, so the medallion, the burst and the copy are
// driven by one clock instead of drifting apart.

private struct PopIn: ViewModifier {
    let delay: Double, enabled: Bool, start: Date
    @State private var done = false
    func body(content: Content) -> some View {
        guard enabled, !done else { return AnyView(content) }
        return AnyView(TimelineView(.animation) { timeline in
            let p = min(max((timeline.date.timeIntervalSince(start) - delay) / 0.42, 0), 1)
            // Overshoot then settle — the spring the spec calls for, expressed on one clock.
            let s = p < 1 ? 0.4 + 1.0 * p - 0.24 * sin(p * .pi) * (1 - p) : 1
            content.scaleEffect(max(s, 0.4)).opacity(min(p * 2, 1))
        }
        .task { try? await Task.sleep(for: .seconds(delay + 0.5)); done = true })
    }
}

private struct RiseIn: ViewModifier {
    let delay: Double, enabled: Bool, start: Date
    @State private var done = false
    func body(content: Content) -> some View {
        guard enabled, !done else { return AnyView(content) }
        return AnyView(TimelineView(.animation) { timeline in
            let p = min(max((timeline.date.timeIntervalSince(start) - delay) / 0.5, 0), 1)
            let eased = 1 - pow(1 - p, 3)
            content.offset(y: 12 * (1 - eased)).opacity(eased)
        }
        .task { try? await Task.sleep(for: .seconds(delay + 0.6)); done = true })
    }
}

#Preview("Visible") { SubscriptionCelebrationView(tier: .visible) {} }
#Preview("Boost") { SubscriptionCelebrationView(tier: .boost) {} }
