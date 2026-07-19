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
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 140, height: 140)
                    .clipShape(Circle())

                VStack(spacing: FlowSpacing.sm) {
                    Text("flowe")
                        .font(FloweFont.serif(36, .light))
                        .foregroundStyle(Color.floweInk)

                    Text("PILATES · COMMUNITY · YOU")
                        .flowFont(.label)
                        .foregroundStyle(Color.floweMuted)
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
