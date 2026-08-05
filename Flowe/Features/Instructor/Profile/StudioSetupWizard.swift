import SwiftUI

/// "Set up your studio" — a guided, resumable checklist that walks a brand-new instructor from an
/// empty dashboard to a bookable, publishable listing. It is a THIN coordinator: it owns no editing
/// logic of its own, it just composes the four existing editors (profile / lesson type / availability
/// / paywall), each presented as a `.sheet` over this full-screen cover. Every editor already owns its
/// NavigationStack + Cancel/Save→dismiss, so dismissing one simply returns here.
///
/// Step completion is 100% DERIVED from real model state via `StudioSetupState` — never a stored flag —
/// reusing the SAME signals the dashboard already reads (`Instructor.profileMissingPieces`,
/// `ownedLessonTypes`, `daysWithHours`, `SubscriptionService.isVisible`). Nothing here is written to
/// SwiftData or CloudKit, so progress can never drift and needs no schema. The only local persistence
/// is a per-owner UserDefaults bool that suppresses AUTO-relaunch after a manual dismiss; the wizard
/// stays fully resumable from the dashboard regardless of that flag.
///
/// The paywall gate is untouched: step 4 presents `PaywallView`, and going visible flows exactly as
/// today (purchase → tier → `FlowApp.onChange` → `applyVisibility`). The wizard never fabricates
/// visibility or calls `applyVisibility`.
struct StudioSetupWizard: View {
    @Environment(MockDataStore.self) private var data
    @Environment(SubscriptionService.self) private var subscription
    @Environment(\.dismiss) private var dismiss

    /// Which editor is currently presented over the cover (nil = the checklist itself).
    private enum Step: Identifiable {
        case profile, lessonType, hours, visible
        var id: Int { hashValue }
    }
    @State private var activeStep: Step?
    /// The step currently on screen (0…3). A guided one-at-a-time flow, not a flat checklist.
    @State private var index = 0
    /// Land on the first UNFINISHED step the first time the wizard appears (resume where they left off).
    @State private var didLandOnFirstOpen = false

    /// Re-read on every render, so done/pending is always current after an editor saves and dismisses.
    private var state: StudioSetupState { StudioSetupState(data: data, subscription: subscription) }

    // MARK: - Step metadata (drives the paged flow)

    private struct StepInfo: Identifiable {
        let step: Step
        let index: Int
        let icon: String
        let title: LocalizedStringKey
        let blurb: LocalizedStringKey
        let cta: LocalizedStringKey
        let done: Bool
        var id: Int { index }
    }

    private var steps: [StepInfo] {
        [
            StepInfo(step: .profile, index: 0, icon: "person.crop.circle",
                     title: "Your profile",
                     blurb: "Add your photo, studio location, a short bio, your certification and specialties — this is what students see first.",
                     cta: "Set up your profile", done: state.step1Done),
            StepInfo(step: .lessonType, index: 1, icon: "list.bullet.rectangle",
                     title: "Add a lesson type",
                     blurb: "Create at least one lesson with a price. It's exactly what students book — and it sets your starting rate.",
                     cta: "Add a lesson type", done: state.step2Done),
            StepInfo(step: .hours, index: 2, icon: "clock",
                     title: "Set your hours",
                     blurb: "Choose the days and times students can book you. You can fine-tune or add one-off dates any time.",
                     cta: "Set your hours", done: state.step3Done),
            StepInfo(step: .visible, index: 3, icon: "sparkles",
                     title: "Go visible",
                     blurb: "Start your subscription to appear in Discover and take bookings. This is the only paid step.",
                     cta: "Go visible", done: state.step4Done),
        ]
    }

    private var firstUnfinishedIndex: Int { steps.first { !$0.done }?.index ?? steps.count - 1 }

    var body: some View {
        NavigationStack {
            VStack(spacing: FlowSpacing.xl) {
                progressHeader
                Spacer(minLength: 0)
                stepCard(steps[index])
                    .id(index)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)))
                Spacer(minLength: 0)
                navRow
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.flowWhite.ignoresSafeArea())
            .navigationTitle("Set up your studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Do this later") { dismissWizard() }
                        .tint(Color.floweMuted)
                        .accessibilityIdentifier("studioWizard.dismiss")
                }
            }
        }
        // Each editor is presented over the flow; on save+dismiss we glide to the next unfinished step.
        .sheet(item: $activeStep, onDismiss: autoAdvanceIfStepDone) { step in
            switch step {
            case .profile:    EditProfileView()
            case .lessonType: ComposeLessonTypeSheet(editing: nil)
            case .hours:      AvailabilityView()
            case .visible:    PaywallView()
            }
        }
        // Full-screen cover → constrain to the centered column on iPad, like the rest of the app.
        .floweAdaptiveColumn()
        .onAppear {
            guard !didLandOnFirstOpen else { return }
            didLandOnFirstOpen = true
            index = firstUnfinishedIndex
        }
    }

    /// After an editor saves, if the step we were on is now complete, slide forward to the next one that
    /// still needs doing — the momentum that makes this feel like a guided flow, not a to-do list.
    private func autoAdvanceIfStepDone() {
        guard steps[index].done, let next = steps.first(where: { !$0.done })?.index, next != index else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { index = next }
    }

    // MARK: - Progress header

    private var progressHeader: some View {
        VStack(spacing: FlowSpacing.md) {
            HStack {
                Text("Step \(index + 1) of \(steps.count)")
                    .font(FloweFont.mono(11))
                    .foregroundStyle(Color.flowePinkDeep)
                Spacer()
                Text("\(state.doneCount)/\(steps.count) done")
                    .font(FloweFont.mono(11))
                    .foregroundStyle(Color.floweMuted)
            }
            HStack(spacing: 6) {
                ForEach(steps) { s in
                    Capsule()
                        .fill(s.done ? Color.flowePinkDeep
                              : (s.index == index ? Color.flowePink : Color.flowePink.opacity(0.18)))
                        .frame(height: 6)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityIdentifier("studioWizard.progress")
    }

    // MARK: - Step card (one focused step)

    private func stepCard(_ s: StepInfo) -> some View {
        VStack(spacing: FlowSpacing.lg) {
            ZStack {
                Circle()
                    .fill(s.done ? Color.floweSuccess.opacity(0.15) : Color.flowePink.opacity(0.14))
                    .frame(width: 88, height: 88)
                Image(systemName: s.done ? "checkmark" : s.icon)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(s.done ? Color.floweSuccess : Color.flowePinkDeep)
            }

            VStack(spacing: 8) {
                Text(s.title)
                    .font(FloweFont.serif(24))
                    .foregroundStyle(Color.floweInk)
                    .multilineTextAlignment(.center)
                Text(s.blurb)
                    .font(FloweFont.sans(14))
                    .foregroundStyle(Color.floweMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if s.done {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Done")
                }
                .font(FloweFont.sans(14, .medium))
                .foregroundStyle(Color.floweSuccess)

                Button { activeStep = s.step } label: {
                    Text("Review or edit")
                        .font(FloweFont.sans(13, .medium))
                        .foregroundStyle(Color.flowePinkDeep)
                }
                .buttonStyle(.plain)
            } else {
                Button { activeStep = s.step } label: {
                    Text(s.cta)
                        .font(FloweFont.sans(16, .medium))
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(FlowGradients.gradDark)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("studioWizard.step.\(s.index + 1)")
            }
        }
        .padding(FlowSpacing.xl)
        .frame(maxWidth: .infinity)
        .floweCard()
    }

    // MARK: - Bottom navigation

    private var navRow: some View {
        VStack(spacing: 10) {
            if !state.incompleteCoreSteps {
                Text("You're bookable! Go visible whenever you're ready to be discovered.")
                    .font(FloweFont.sans(12))
                    .foregroundStyle(Color.floweSuccess)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { index -= 1 }
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(FloweFont.sans(14, .medium))
                        .foregroundStyle(Color.floweMuted)
                }
                .buttonStyle(.plain)
                .opacity(index > 0 ? 1 : 0)
                .disabled(index == 0)

                Spacer()

                if index < steps.count - 1 {
                    Button {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { index += 1 }
                    } label: {
                        Label("Next", systemImage: "chevron.right")
                            .labelStyle(.titleAndIcon)
                            .font(FloweFont.sans(14, .medium))
                            .foregroundStyle(Color.flowePinkDeep)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button { dismissWizard() } label: {
                        Text(state.incompleteCoreSteps ? "Do this later" : "Finish")
                            .font(FloweFont.sans(14, .medium))
                            .foregroundStyle(Color.flowePinkDeep)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("studioWizard.finish")
                }
            }
        }
    }

    /// Close the cover AND remember the manual dismiss, so it won't auto-relaunch. Resume stays
    /// available from the dashboard's "Set up your studio" tile.
    private func dismissWizard() {
        StudioWizard.setDismissed(data.currentInstructor?.ownerID)
        dismiss()
    }
}

// MARK: - Derived completion state

/// The four per-step booleans, each DERIVED from real model state — no stored progress. Reuses the
/// existing completion signals so the wizard can never disagree with the dashboard/profile.
struct StudioSetupState {
    let step1Done: Bool   // profile basics complete (Instructor.profileMissingPieces empty)
    let step2Done: Bool   // at least one lesson type authored
    let step3Done: Bool   // at least one weekday carries bookable hours
    let step4Done: Bool   // subscription entitlement present (Discover-visible)

    static let totalSteps = 4

    @MainActor
    init(data: MockDataStore, subscription: SubscriptionService) {
        let me = data.currentInstructor
        // Profile-editor fields only — NOT `pricing` (that's the lesson-type step). Using the full
        // `profileMissingPieces` here (which includes derived pricing) is the bug that left this step
        // stuck on "Set up" even after the profile form was fully filled.
        step1Done = me?.profileBasicsComplete ?? false
        step2Done = me.map { !data.ownedLessonTypes(for: $0).isEmpty } ?? false
        // OR-in the legacy `available` fallback: a listing written by a pre-`hours` build carries set
        // weekdays with no per-day hour tokens (daysWithHours empty), yet is genuinely bookable via
        // `hours(on:)`'s legacy full-slate fallback. Without this, such an already-set-up instructor
        // would derive step3 incomplete and get auto-launched into the wizard.
        step3Done = me.map { !$0.daysWithHours.isEmpty || !$0.available.isEmpty } ?? false
        step4Done = subscription.isVisible
    }

    var doneCount: Int { [step1Done, step2Done, step3Done, step4Done].filter { $0 }.count }

    /// Whether any of the three FREE core steps is still pending. Step 4 (Go visible) is excluded: it
    /// is paywall-gated and a free instructor may legitimately never subscribe, so the wizard must not
    /// nag them about it forever. Drives auto-launch for a brand-new instructor.
    var incompleteCoreSteps: Bool { !(step1Done && step2Done && step3Done) }
}

// MARK: - Auto-relaunch suppression (device-local, never CloudKit)

/// A single per-owner UserDefaults bool that stops the wizard AUTO-launching again after the
/// instructor has dismissed it once. Completion itself stays derived, so a dismissed-but-later-
/// completed instructor still sees correct done/pending state when they reopen the wizard.
enum StudioWizard {
    private static func key(_ ownerID: String) -> String { "flowe.studioWizardDismissed.\(ownerID)" }

    static func isDismissed(_ ownerID: String?) -> Bool {
        guard let ownerID, !ownerID.isEmpty else { return false }
        return UserDefaults.standard.bool(forKey: key(ownerID))
    }

    static func setDismissed(_ ownerID: String?) {
        guard let ownerID, !ownerID.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: key(ownerID))
    }
}
