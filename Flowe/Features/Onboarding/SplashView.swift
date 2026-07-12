import SwiftUI

struct SplashView: View {
    @Environment(AppSession.self) private var session
    @State private var logoScale: CGFloat = 0.7
    @State private var logoOpacity: Double = 0
    var onFinished: () -> Void

    var body: some View {
        ZStack {
            FlowGradients.gradient2
                .ignoresSafeArea()

            VStack(spacing: FlowSpacing.xl) {
                // Logo mark
                ZStack {
                    Circle()
                        .fill(Color.flowWhite.opacity(0.2))
                        .frame(width: 120, height: 120)

                    Text("F")
                        .font(.system(size: 60, weight: .bold, design: .serif))
                        .foregroundStyle(Color.flowEspressoBrown)
                }

                VStack(spacing: FlowSpacing.sm) {
                    Text("flowe")
                        .font(.system(size: 36, weight: .light, design: .serif))
                        .foregroundStyle(Color.flowEspressoBrown)

                    Text("PILATES · COMMUNITY · YOU")
                        .flowFont(.label)
                        .foregroundStyle(Color.flowTaupeGray)
                        .tracking(2)
                }
            }
            .scaleEffect(logoScale)
            .opacity(logoOpacity)
        }
        .onAppear {
            withAnimation(.spring(duration: 0.6, bounce: 0.3)) {
                logoScale = 1.0
                logoOpacity = 1.0
            }
            Task {
                try? await Task.sleep(for: .seconds(2))
                onFinished()
            }
        }
    }
}

#Preview {
    SplashView(onFinished: {})
        .environment(AppSession())
}
