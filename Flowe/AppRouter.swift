import SwiftUI

struct AppRouter: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        switch session.authState {
        case .unauthenticated:
            OnboardingFlowView()
                .transition(.asymmetric(
                    insertion: .opacity,
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
        case .student:
            StudentTabView()
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
