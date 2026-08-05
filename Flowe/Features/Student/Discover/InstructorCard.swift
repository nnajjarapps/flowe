import SwiftUI

/// Horizontal Discover list row: left image + right detail column, tappable.
struct InstructorCard: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Instagram-style peek: a stationary long-press floats a richer preview card above the row
    /// (photo + name + rate + specialties); lifting the finger dismisses it. A normal tap still
    /// opens the profile via `action` — the peek is purely additive and non-hit-testing.
    @State private var previewing = false
    let instructor: Instructor
    /// Metres from this device to the instructor's exact studio point, measured on device by
    /// `LocationService`. Nil whenever either side has no location — which is the common case, and
    /// simply means the row shows the studio address and nothing else.
    var distanceMetres: Double? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                // Left image with gradient overlay
                RemoteImage(id: instructor.img, photo: instructor.photo, width: 160, height: 160)
                    .frame(width: 88)
                    .frame(maxHeight: .infinity)
                    .background(Color.flowePinkPale)
                    .overlay(FlowGradients.grad.opacity(0.35))
                    .clipped()

                // Right detail column
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        Text(instructor.name)
                            .font(FloweFont.serif(15))
                            .foregroundStyle(Color.floweInk)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        // No fabricated 0.0 for a review-less instructor — a neutral "New" pill
                        // instead, matching StudentInstructorProfileView / FeaturedHeroCard.
                        if instructor.reviews > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.flowePink)
                                Text(String(format: "%.1f", instructor.rating))
                                    .font(FloweFont.mono(11))
                                    .foregroundStyle(Color.flowePinkDeep)
                            }
                        } else {
                            Text("New")
                                .font(FloweFont.mono(10))
                                .foregroundStyle(Color.floweMuted)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.flowePink.opacity(0.10), in: Capsule())
                        }
                    }
                    .padding(.bottom, 2)

                    HStack(spacing: 4) {
                        Image(systemName: "mappin")
                            .font(.system(size: 10))
                        // The instructor's exact studio address — never localized. Empty shows nothing
                        // (no fallback to `city`), leaving just the pin and/or the distance chip.
                        if !instructor.address.isEmpty {
                            Text(instructor.address)
                                .font(FloweFont.sans(11))
                                .lineLimit(1)
                        }
                        if let distanceMetres {
                            if !instructor.address.isEmpty {
                                Text(verbatim: "·").font(FloweFont.sans(11))
                            }
                            Text(FloweDistance.label(metres: distanceMetres))
                                .font(FloweFont.mono(11))
                                .foregroundStyle(Color.flowePinkDeep)
                                .layoutPriority(1)
                        }
                    }
                    .foregroundStyle(Color.floweMuted)
                    .padding(.bottom, 8)

                    HStack(spacing: 4) {
                        ForEach(instructor.specialties.prefix(2), id: \.self) { s in
                            SpecialtyTag(text: s)
                        }
                    }
                    .padding(.bottom, 8)

                    HStack {
                        // Localize each canonical session type; join with " · " via Text concatenation
                        // (a joined String would render verbatim English). Free-form names pass through.
                        instructor.sessionTypes.prefix(2).enumerated().reduce(Text("")) { acc, e in
                            acc + (e.offset == 0 ? Text("") : Text(" · ")) + Text(localizedTag: e.element)
                        }
                            .font(FloweFont.mono(11))
                            .foregroundStyle(Color.floweMuted)
                        Spacer()
                        // "from" = starting price (the cheapest lesson type). Hidden when the derived
                        // price is 0 (no priced type) rather than showing a misleading "from ₪0".
                        if instructor.price > 0 {
                            Text("from \(settings.money(instructor.price))")
                                .font(FloweFont.serif(13, .medium))
                                .foregroundStyle(Color.floweInk)
                        }
                    }
                }
                .padding(12)
            }
            .fixedSize(horizontal: false, vertical: true)
            .floweCard()
        }
        // Standard press feedback (0.96 scale + dim, reduce-motion aware). Coexists with the
        // long-press peek gesture below — a quick press just dips the card, then opens the profile.
        .flowePressable()
        // Floats above the row (not clipped by the card) while held. zIndex keeps it over the row's
        // own layers; allowsHitTesting(false) lets the release/tap fall through to the button.
        .overlay(alignment: .center) {
            if previewing {
                previewCard
                    .allowsHitTesting(false)
                    .zIndex(10)
                    .transition(reduceMotion
                                ? .opacity
                                : .scale(scale: 0.9).combined(with: .opacity))
            }
        }
        // High-priority so a completed long-press consumes the touch (release just dismisses, it
        // never also opens the profile). A quick tap fails the 0.35s press and falls through to the
        // button; any finger movement (a scroll) fails it too, so the feed still scrolls normally.
        .highPriorityGesture(peekGesture)
    }

    /// Long-press then hold: the `.sequenced` drag phase (min distance 0) begins only after the
    /// press succeeds, giving a reliable "finger lifted" signal via its `.onEnded`.
    private var peekGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                if case .second(true, _) = value { reveal() }
            }
            .onEnded { _ in dismissPreview() }
    }

    private func reveal() {
        guard !previewing else { return }
        Haptic.impact()
        withAnimation(reduceMotion ? .easeOut(duration: 0.12)
                                   : .spring(response: 0.3, dampingFraction: 0.7)) {
            previewing = true
        }
    }

    private func dismissPreview() {
        guard previewing else { return }
        withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.2)) { previewing = false }
    }

    /// The floating peek — a larger, self-contained card. Read-only; taps pass through to the row.
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            RemoteImage(id: instructor.img, photo: instructor.photo, width: 320, height: 200)
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .background(Color.flowePinkPale)
                .overlay(FlowGradients.grad.opacity(0.30))
                .clipped()

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(instructor.name)
                        .font(FloweFont.serif(18))
                        .foregroundStyle(Color.floweInk)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if instructor.price > 0 {
                        Text("from \(settings.money(instructor.price))")
                            .font(FloweFont.serif(14, .medium))
                            .foregroundStyle(Color.flowePinkDeep)
                    }
                }
                if !instructor.specialties.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(instructor.specialties.prefix(3), id: \.self) { SpecialtyTag(text: $0) }
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 280)
        .background(Color.floweCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.floweBorder, lineWidth: 1))
        .shadow(color: Color.floweInk.opacity(0.22), radius: 24, y: 12)
    }
}
