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
            OnboardingFlowView()
                .floweAdaptiveColumn()
                .transition(.asymmetric(
                    insertion: .opacity,
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
        case .student:
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
        case .instructor:
            InstructorTabView()
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity
                ))
        }
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
