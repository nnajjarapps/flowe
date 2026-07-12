import SwiftUI

struct OnboardingFlowView: View {
    @State private var showRoleSelection = false

    var body: some View {
        NavigationStack {
            if showRoleSelection {
                RoleSelectionView()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                SplashView {
                    withAnimation(.spring(duration: 0.4, bounce: 0.1)) {
                        showRoleSelection = true
                    }
                }
                .transition(.opacity)
            }
        }
    }
}

#Preview {
    OnboardingFlowView()
        .environment(AppSession())
}
