import SwiftUI

struct AppRouter: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        routed
    }

    // The centered iPad column is applied PER-SCREEN, not around the whole app, so the native
    // TabView tab bar (top on iPad) stays full-width and shows every tab instead of squeezing into a
    // scrolling pill. Non-tab routes (onboarding, quiz) get the column here; tab screens get it inside
    // the tab views.
    @ViewBuilder private var routed: some View {
        switch session.authState {
        case .unauthenticated:
            // App Store 5.1.1(v): a guest may browse the non-account features (Discover + instructor
            // profiles) without registering. A guest stays `.unauthenticated` (so every account write is
            // still fenced off) but gets the student tab shell directly — NOT behind the terms gate
            // (`hasAcceptedTerms` is false for the placeholder owner) or the student quiz (a student-only
            // gate). Sign-in from any gated action clears `isGuest` and flips into the real `.student` arm.
            if session.isGuest {
                StudentTabView()
                    .transition(.opacity)
            } else {
                OnboardingFlowView()
                    .floweAdaptiveColumn()
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
        case .student:
            gated {
                Group {
                    if session.needsOnboardingQuiz {
                        StudentQuizView(existing: session.studentPreferences) { prefs in
                            session.saveStudentPreferences(prefs)
                        } onSkip: {
                            session.saveStudentPreferences(StudentPreferences(completedAt: Date()))
                        }
                        .floweAdaptiveColumn()
                    } else {
                        StudentTabView()
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        case .instructor:
            gated {
                InstructorTabView()
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
    }

    /// App Store Guideline 1.2: an authenticated user who hasn't accepted the current Terms + Community
    /// Guidelines (a brand-new account reached via "Log in", or anyone after a `termsVersion` bump) must
    /// agree before using the app. `hasAcceptedTerms` is observable, so accepting dismisses this instantly.
    @ViewBuilder private func gated<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if session.hasAcceptedTerms {
            content()
        } else {
            TermsGateView().floweAdaptiveColumn()
        }
    }
}

/// The post-authentication terms gate (see `AppRouter.gated`). Reuses `TermsAcceptanceView`; Continue is
/// enabled once the box is ticked and records acceptance for the signed-in account.
struct TermsGateView: View {
    @Environment(AppSession.self) private var session
    @State private var agreed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FlowSpacing.xl) {
                VStack(alignment: .leading, spacing: FlowSpacing.xs) {
                    Text("One quick agreement")
                        .flowFont(.displayMedium)
                        .foregroundStyle(Color.floweInk)
                    Text("Please review and accept to keep using Flowe.")
                        .flowFont(.bodyMedium)
                        .foregroundStyle(Color.floweMuted)
                }
                TermsAcceptanceView(isAgreed: $agreed)
                Button {
                    session.recordTermsAcceptance()
                } label: {
                    Text("Continue")
                        .font(FloweFont.sans(16, .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(agreed ? AnyShapeStyle(FlowGradients.gradDark)
                                           : AnyShapeStyle(Color.flowePinkSoft),
                                    in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(!agreed)
                .accessibilityIdentifier("termsGate.continue")
            }
            .padding(.horizontal, FlowSpacing.xl)
            .padding(.vertical, FlowSpacing.xl)
        }
        .floweBackground()
    }
}

// MARK: - iPad adaptive column

extension View {
    /// Renders phone-designed content as a centered, readable COLUMN on iPad (any `.regular`
    /// horizontal size class) with full-bleed margins, instead of stretching it edge-to-edge. A no-op
    /// on iPhone (`.compact`, and the app is portrait-locked so `.regular` here always means iPad).
    /// Apply at the app root (AppRouter) AND to any `fullScreenCover` root (e.g. the studio wizard) —
    /// `.sheet` presentations already come up as centered form-sheets on iPad and don't need it.
    func floweAdaptiveColumn(maxWidth: CGFloat = 640) -> some View {
        modifier(FloweAdaptiveColumn(maxWidth: maxWidth))
    }
}

extension View {
    /// iPad (iOS 18+): a sidebar showing every tab, using the wide canvas; iPhone / iOS 17: the normal
    /// tab bar, unchanged. Gated because `.sidebarAdaptable` is iOS 18-only.
    @ViewBuilder func sidebarAdaptableIfAvailable() -> some View {
        if #available(iOS 18.0, *) {
            self.tabViewStyle(.sidebarAdaptable)
        } else {
            self
        }
    }
}

private struct FloweAdaptiveColumn: ViewModifier {
    @Environment(\.horizontalSizeClass) private var hSize
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        if hSize == .regular {
            content
                .frame(maxWidth: maxWidth, maxHeight: .infinity)
                // Hairline edges so the column reads as a defined surface even when its own background
                // matches the canvas — and a soft shadow to lift it off the field.
                .overlay(alignment: .leading) { edge }
                .overlay(alignment: .trailing) { edge }
                .shadow(color: Color.floweInk.opacity(0.06), radius: 12, x: 0, y: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)   // center horizontally
                .background(Color.floweCardBg.ignoresSafeArea())    // soft on-brand canvas in the margins
        } else {
            content   // iPhone: untouched
        }
    }

    private var edge: some View {
        Rectangle().fill(Color.floweBorder).frame(width: 0.5).ignoresSafeArea()
    }
}
