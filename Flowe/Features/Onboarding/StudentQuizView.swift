import SwiftUI

/// Full-screen, multi-step onboarding quiz for students. Accumulates a draft `StudentPreferences`
/// and hands it back through `onComplete`; it owns NO persistence itself, so the same view serves
/// both as the first-run gate (from `AppRouter`, where `onComplete` calls
/// `session.saveStudentPreferences`) and as a retake sheet (from Discover, where `onComplete` saves
/// and dismisses). `onSkip` is optional — first-run passes a handler that stores an empty completed
/// record; the retake sheet passes one that simply dismisses.
struct StudentQuizView: View {
    private let onComplete: (StudentPreferences) -> Void
    private let onSkip: (() -> Void)?

    /// Current step index, 0...`Self.lastStep`. Drives the animated transitions (OnboardingFlowView
    /// idiom: spring + move/opacity).
    @State private var step: Int = 0
    /// The answers so far. Seeded from `existing` when re-taking so prior picks are pre-filled.
    @State private var draft: StudentPreferences

    // Single-select steps track a local selection so the "no preference"-style options (which all map
    // to `nil` on the draft) can render a distinct checked state from "not chosen yet".
    @State private var experiencePick: ExperienceLevel?
    @State private var formatIndex: Int?
    @State private var budgetIndex: Int?
    @State private var distanceIndex: Int?

    // MARK: Single-select option tables (label -> draft value). Static so init can seed indices.

    private static let formatOptions: [(label: String, value: SessionFormat?)] = [
        ("Private (1-on-1)", .privateOneOnOne),
        ("Small group", .smallGroup),
        ("No preference", nil)
    ]

    private static let budgetOptions: [(label: String, value: Int?)] = [
        ("Under ₪150", 150),
        ("₪150–250", 250),
        ("₪250–400", 400),
        ("No limit", nil)
    ]

    private static let distanceOptions: [(label: String, value: Double?)] = [
        ("Within 5 km", 5000),
        ("Within 15 km", 15000),
        ("Within 30 km", 30000),
        ("Any distance", nil)
    ]

    private static let lastStep = 5
    private static let stepCount = 6

    init(existing: StudentPreferences? = nil,
         onComplete: @escaping (StudentPreferences) -> Void,
         onSkip: (() -> Void)? = nil) {
        self.onComplete = onComplete
        self.onSkip = onSkip
        _draft = State(initialValue: existing ?? StudentPreferences())
        _experiencePick = State(initialValue: existing?.experience)

        // Seed the single-select indices from a prior answer. When the student had onboarded but left a
        // dimension at its "no preference" default (nil), preselect that option so a retake shows it.
        _formatIndex = State(initialValue: Self.seededIndex(
            from: existing, value: existing?.format, options: Self.formatOptions.map(\.value)))
        _budgetIndex = State(initialValue: Self.seededIndex(
            from: existing, value: existing?.maxBudget, options: Self.budgetOptions.map(\.value)))
        _distanceIndex = State(initialValue: Self.seededIndex(
            from: existing, value: existing?.maxDistanceMetres, options: Self.distanceOptions.map(\.value)))
    }

    /// Finds the option index whose value matches `value`; falls back to the `nil` option only when the
    /// student has actually onboarded before (so brand-new drafts start with nothing selected).
    private static func seededIndex<T: Equatable>(from existing: StudentPreferences?,
                                                  value: T?,
                                                  options: [T?]) -> Int? {
        if let value, let match = options.firstIndex(where: { $0 == value }) { return match }
        if existing?.hasOnboarded == true, let noPref = options.firstIndex(where: { $0 == nil }) {
            return noPref
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            // Animated step content — the `.id(step)` + transition reproduces the OnboardingFlowView feel.
            ScrollView(showsIndicators: false) {
                stepContent
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(step)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            // Bottom CTA
            GradientButton(title: isLastStep ? "See my matches" : "Next", enabled: isStepValid) {
                advance()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .floweBackground()
    }

    // MARK: - Top bar (back + progress + skip)

    private var topBar: some View {
        HStack {
            if step > 0 {
                IconButton(systemName: "chevron.left") { back() }
            } else {
                // Keep the progress label centered whether or not the back button is present.
                Color.clear.frame(width: 44, height: 44)
            }

            Spacer()

            Text("Step \(step + 1) of \(Self.stepCount)")
                .font(FloweFont.mono(11))
                .foregroundStyle(Color.floweMuted)

            Spacer()

            if let onSkip {
                Button("Skip") { onSkip() }
                    .font(FloweFont.sans(14, .medium))
                    .foregroundStyle(Color.flowePinkDeep)
                    .frame(minWidth: 44, alignment: .trailing)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0: goalsStep
        case 1: disciplinesStep
        case 2: experienceStep
        case 3: formatStep
        case 4: budgetStep
        default: distanceStep
        }
    }

    // STEP 0 — Goals (multi-select, optional). Informational only.
    private var goalsStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            QuizHeader(title: "What brings you to Flowe?", subtitle: "Pick any that fit.")
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(StudentGoal.allCases) { goal in
                    CategoryChip(title: goal.label, isSelected: draft.goals.contains(goal)) {
                        toggle(goal)
                    }
                }
            }
        }
    }

    // STEP 1 — Focus disciplines (multi-select, REQUIRED >= 1). Primary match dimension.
    private var disciplinesStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            QuizHeader(title: "Which styles interest you?",
                       subtitle: "This is what we match you on. Choose at least one.")
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(FocusDiscipline.allCases) { discipline in
                    CategoryChip(title: discipline.label,
                                 isSelected: draft.disciplines.contains(discipline.rawValue)) {
                        toggle(discipline)
                    }
                }
            }
        }
    }

    // STEP 2 — Experience level (single-select). Informational only.
    private var experienceStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            QuizHeader(title: "How much Pilates have you done?", subtitle: nil)
            VStack(spacing: 12) {
                ForEach(ExperienceLevel.allCases) { level in
                    QuizOptionCard(title: level.label, isSelected: experiencePick == level) {
                        experiencePick = level
                        draft.experience = level
                    }
                }
            }
        }
    }

    // STEP 3 — Session format (single-select). `nil` == no preference.
    private var formatStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            QuizHeader(title: "Private or group?", subtitle: nil)
            VStack(spacing: 12) {
                ForEach(Array(Self.formatOptions.enumerated()), id: \.offset) { index, option in
                    QuizOptionCard(title: option.label, isSelected: formatIndex == index) {
                        formatIndex = index
                        draft.format = option.value
                    }
                }
            }
        }
    }

    // STEP 4 — Budget (single-select). Upper per-session bound in ILS; `nil` == no limit.
    private var budgetStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            QuizHeader(title: "What's your per-session budget?", subtitle: nil)
            VStack(spacing: 12) {
                ForEach(Array(Self.budgetOptions.enumerated()), id: \.offset) { index, option in
                    QuizOptionCard(title: option.label, isSelected: budgetIndex == index) {
                        budgetIndex = index
                        draft.maxBudget = option.value
                    }
                }
            }
        }
    }

    // STEP 5 — Max distance (single-select, optional). Only applies once location is shared.
    private var distanceStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            QuizHeader(title: "How far will you travel?",
                       subtitle: "Only used once you share your location.")
            VStack(spacing: 12) {
                ForEach(Array(Self.distanceOptions.enumerated()), id: \.offset) { index, option in
                    QuizOptionCard(title: option.label, isSelected: distanceIndex == index) {
                        distanceIndex = index
                        draft.maxDistanceMetres = option.value
                    }
                }
            }

            // A light recap of what actually drives matching, so the last screen feels like a summary.
            if !draft.disciplines.isEmpty {
                HStack(spacing: 12) {
                    StatTile(value: "\(draft.disciplines.count)", label: "STYLES")
                    StatTile(value: budgetSummary, label: "BUDGET")
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Derived state

    private var isLastStep: Bool { step == Self.lastStep }

    /// Per-step validity gate for the CTA. Only the required disciplines step blocks advancement.
    private var isStepValid: Bool {
        switch step {
        case 1: return !draft.disciplines.isEmpty
        case 2: return experiencePick != nil
        default: return true
        }
    }

    private var budgetSummary: String {
        guard let index = budgetIndex, let value = Self.budgetOptions[index].value else { return "Any" }
        return "≤₪\(value)"
    }

    // MARK: - Mutations

    private func toggle(_ goal: StudentGoal) {
        if let idx = draft.goals.firstIndex(of: goal) {
            draft.goals.remove(at: idx)
        } else {
            draft.goals.append(goal)
        }
    }

    private func toggle(_ discipline: FocusDiscipline) {
        if let idx = draft.disciplines.firstIndex(of: discipline.rawValue) {
            draft.disciplines.remove(at: idx)
        } else {
            draft.disciplines.append(discipline.rawValue)
        }
    }

    // MARK: - Navigation

    private func advance() {
        if isLastStep {
            finish()
        } else {
            withAnimation(.spring(duration: 0.4, bounce: 0.1)) { step += 1 }
        }
    }

    private func back() {
        guard step > 0 else { return }
        withAnimation(.spring(duration: 0.4, bounce: 0.1)) { step -= 1 }
    }

    private func finish() {
        draft.completedAt = Date()
        onComplete(draft)
    }
}

// MARK: - Step header (left-aligned serif title + muted sans subtitle)

private struct QuizHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(FloweFont.serif(26))
                .foregroundStyle(Color.floweInk)
            if let subtitle {
                Text(subtitle)
                    .font(FloweFont.sans(14))
                    .foregroundStyle(Color.floweMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Single-select answer card (RoleSelectionView idiom: rounded-20 pink tint, selected -> deep
// pink 2pt stroke + checkmark).

private struct QuizOptionCard: View {
    let title: String
    var subtitle: String? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(FloweFont.sans(15, .medium))
                        .foregroundStyle(Color.floweInk)
                    if let subtitle {
                        Text(subtitle)
                            .font(FloweFont.sans(12))
                            .foregroundStyle(Color.floweMuted)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.flowePinkDeep : Color.floweMuted.opacity(0.4))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.flowePinkSoft.opacity(isSelected ? 0.85 : 0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.flowePinkDeep, lineWidth: isSelected ? 2 : 0)
            )
        }
        .buttonStyle(.plain)
    }
}
