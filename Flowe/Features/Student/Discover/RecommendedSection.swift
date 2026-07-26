import SwiftUI

/// Discover's personalized "Recommended for you" band. Runs `MatchEngine` over the store's
/// `visibleInstructors`, ranks them against the student's quiz answers, and shows the top matches in
/// a horizontal carousel of compact cards (each with its match %). Owns its own horizontal insets +
/// bottom padding so DiscoverView can drop it in as a one-liner (like FilterChipsBar).
///
/// State machine:
/// - no preferences yet, or the quiz hasn't been completed -> a full-width "take the quiz" prompt.
/// - onboarded, but nothing to rank (no visible instructors) -> renders nothing.
/// - onboarded with matches -> the ranked carousel.
struct RecommendedSection: View {
    let preferences: StudentPreferences?
    /// Metres from this device to the instructor, measured on device by `LocationService`; nil when
    /// either side has no location. Forwarded to the engine (distance dimension) and to `onSelect`.
    let distance: (Instructor) -> Double?
    let onSelect: (Instructor, Double?) -> Void
    let onTakeQuiz: () -> Void

    @Environment(MockDataStore.self) private var data
    @Environment(AppSettings.self) private var settings

    /// The catalog's format signal is a heuristic read off each lesson type's capacity: 1 == a
    /// one-on-one private, >= 2 == a small group, 0 (not stated) contributes nothing. Mirrors the
    /// exact rule MatchEngine's `format` dimension expects.
    private func formats(for instructor: Instructor) -> Set<SessionFormat> {
        var out: Set<SessionFormat> = []
        for type in data.lessonTypes(for: instructor) {
            if type.capacity == 1 {
                out.insert(.privateOneOnOne)
            } else if type.capacity >= 2 {
                out.insert(.smallGroup)
            }
        }
        return out
    }

    /// Top 5 ranked matches. Only computed once the student has actually onboarded.
    private var results: [MatchResult] {
        guard let preferences, preferences.hasOnboarded else { return [] }
        let ranked = MatchEngine.rank(
            data.visibleInstructors,
            against: preferences,
            formats: { formats(for: $0) },
            distance: distance
        )
        return Array(ranked.prefix(5))
    }

    /// True until the quiz is finished (no prefs, or prefs without a completion date).
    private var needsQuiz: Bool {
        preferences?.hasOnboarded != true
    }

    var body: some View {
        // Compute once (MatchEngine.rank runs on access). An onboarded student with nothing to rank
        // (empty visible catalog) renders nothing rather than an orphan header over blank space.
        let matches = results
        if !needsQuiz && matches.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeader(text: "RECOMMENDED FOR YOU")
                    Spacer()
                    // Hide the retake affordance during first-run; the prompt card owns the CTA then.
                    if !needsQuiz {
                        Button("Retake") { onTakeQuiz() }
                            .font(FloweFont.sans(12, .medium))
                            .foregroundStyle(Color.flowePinkDeep)
                    }
                }
                .padding(.horizontal, 20)

                if needsQuiz {
                    promptCard
                        .padding(.horizontal, 20)
                } else {
                    // Bleed the carousel to the screen edges (inset lives on the inner HStack).
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(matches) { result in
                                RecommendedCard(result: result) {
                                    onSelect(result.instructor, distance(result.instructor))
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }

    /// First-run personalize prompt shown under the same section header.
    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Answer a few quick questions and we'll match you with instructors who fit your goals, style, and budget.")
                .font(FloweFont.sans(13))
                .foregroundStyle(Color.floweMuted)
                .fixedSize(horizontal: false, vertical: true)
            GradientButton(title: "Take the style quiz") { onTakeQuiz() }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floweCard()
    }
}

// MARK: - Compact carousel card

/// A ~200pt vertical instructor card for the recommendations carousel: photo with a match% pill,
/// then name / rating / specialties / price. Tapping opens the instructor's profile.
private struct RecommendedCard: View {
    @Environment(AppSettings.self) private var settings
    let result: MatchResult
    let onTap: () -> Void

    private var instructor: Instructor { result.instructor }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                // Image + match% pill
                RemoteImage(id: instructor.img, photo: instructor.photo, width: 400, height: 260)
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
                    .background(Color.flowePinkPale)
                    .overlay(FlowGradients.grad.opacity(0.35))
                    .overlay(alignment: .topTrailing) {
                        Text("\(result.matchPercent)% match")
                            .font(FloweFont.mono(11))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(FlowGradients.gradDark))
                            .padding(8)
                    }
                    .clipped()

                // Detail column
                VStack(alignment: .leading, spacing: 6) {
                    Text(instructor.name)
                        .font(FloweFont.serif(15))
                        .foregroundStyle(Color.floweInk)
                        .lineLimit(1)

                    StarRatingView(rating: instructor.rating)

                    HStack(spacing: 4) {
                        ForEach(instructor.specialties.prefix(2), id: \.self) { s in
                            SpecialtyTag(text: s)
                        }
                    }

                    Text(settings.money(instructor.price))
                        .font(FloweFont.serif(13, .medium))
                        .foregroundStyle(Color.floweInk)
                }
                .padding(12)
            }
            .frame(width: 200, alignment: .leading)
            .floweCard()
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    let data = MockDataStore.preview
    return ScrollView {
        VStack(spacing: 24) {
            RecommendedSection(
                preferences: StudentPreferences(disciplines: ["Reformer"], completedAt: Date()),
                distance: { _ in nil },
                onSelect: { _, _ in },
                onTakeQuiz: {}
            )
            RecommendedSection(
                preferences: nil,
                distance: { _ in nil },
                onSelect: { _, _ in },
                onTakeQuiz: {}
            )
        }
        .padding(.vertical)
    }
    .background(Color.flowWhite)
    .environment(data)
    .environment(AppSettings())
}
