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

    /// A compact natural-language digest of the student's quiz answers — the input to the on-device
    /// "why this instructor" rationale (Flowe Intelligence). Empty when nothing was answered.
    private var prefsSummary: String {
        preferences.map { FloweAI.preferenceSummary($0) } ?? ""
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
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, result in
                                RecommendedCard(result: result, prefsSummary: prefsSummary) {
                                    onSelect(result.instructor, distance(result.instructor))
                                }
                                .floweAppear(index)
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
    /// The student's quiz digest — non-empty enables the ✨ "why this instructor" rationale.
    var prefsSummary: String = ""
    let onTap: () -> Void

    /// On-device rationale for why this instructor fits the student. Nil until generated / if unavailable.
    @State private var rationale: String?

    private var instructor: Instructor { result.instructor }

    // The label is split into named sub-views on purpose. As one monolithic Button-label
    // expression this body is a huge nested `ModifiedContent` type that the DEBUG (`-Onone`)
    // SwiftUI toolchain miscompiles — it corrupts the value's copy/destroy and crashes with
    // EXC_BAD_ACCESS in `initializeWithCopy for StrokeShapeView` / `swift_retain` the moment the
    // card renders. Breaking it into separately type-checked `some View` pieces keeps the top-level
    // type small and stops the miscompile.
    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                photo
                details
            }
            .frame(width: 200, alignment: .leading)
            .floweCard()
        }
        .flowePressable()
        .task { await loadRationale() }
    }

    /// Generate the "why this instructor" line on-device, once, when there's a preference digest and the
    /// model is available. Silent no-op otherwise — the card just shows without the line.
    private func loadRationale() async {
        guard rationale == nil, !prefsSummary.isEmpty else { return }
        if #available(iOS 26, *), FloweAI.isAvailable {
            rationale = try? await FloweIntelligence.shared.whyThisInstructor(
                studentSummary: prefsSummary,
                instructor: instructor.name,
                specialties: instructor.specialties)
        }
    }

    /// Instructor photo with the gradient wash and the match% pill.
    private var photo: some View {
        RemoteImage(id: instructor.img, photo: instructor.photo, width: 400, height: 260)
            .frame(height: 120)
            .frame(maxWidth: .infinity)
            .background(Color.flowePinkPale)
            .overlay(FlowGradients.grad.opacity(0.35))
            .overlay(alignment: .topTrailing) { matchBadge }
            .clipped()
    }

    private var matchBadge: some View {
        Text("\(result.matchPercent)% match")
            .font(FloweFont.mono(11))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(FlowGradients.gradDark))
            .padding(8)
    }

    /// Name / rating / specialties / starting price.
    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(instructor.name)
                .font(FloweFont.serif(15))
                .foregroundStyle(Color.floweInk)
                .lineLimit(1)

            ratingOrNew

            HStack(spacing: 4) {
                ForEach(instructor.specialties.prefix(2), id: \.self) { s in
                    SpecialtyTag(text: s)
                }
            }

            // ✨ On-device "why this instructor for you" line (Flowe Intelligence). Appears when the
            // rationale is ready; absent otherwise, so the card never waits on it. See [[FloweIntelligence]].
            if let rationale, !rationale.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(Color.flowePinkDeep)
                    Text(rationale)
                        .font(FloweFont.sans(11))
                        .foregroundStyle(Color.flowePinkDeep)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // "from" = starting price (cheapest lesson type); hidden when 0 (no priced type).
            if instructor.price > 0 {
                Text("from \(settings.money(instructor.price))")
                    .font(FloweFont.serif(13, .medium))
                    .foregroundStyle(Color.floweInk)
            }
        }
        .padding(12)
    }

    @ViewBuilder private var ratingOrNew: some View {
        if instructor.reviews > 0 {
            StarRatingView(rating: instructor.rating)
        } else {
            Text("New")
                .font(FloweFont.mono(10))
                .foregroundStyle(Color.floweMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.flowePink.opacity(0.10), in: Capsule())
        }
    }
}
