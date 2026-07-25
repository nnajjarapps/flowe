import SwiftUI

/// The app's landing screen — a full-bleed hero fading into the cream canvas, the FLOWE mark, a
/// welcome headline, and the two ways in. Translated from the Figma "welcome" screen, which replaced
/// the old auto-advancing splash: the person taps to continue rather than waiting out a timer.
///
/// Both buttons lead into role selection, where the app's real sign-up and Sign in with Apple paths
/// live — the sign-in flow is role-scoped there, so "I already have an account" routes through it
/// rather than forcing a default role here.
struct WelcomeView: View {
    var onGetStarted: () -> Void
    var onSignIn: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            hero
            copy
        }
        .background(Color.flowWarmCream)
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Hero

    private var hero: some View {
        ZStack(alignment: .top) {
            // Sized by a clear layer, with the photo filling it — `scaledToFill` overflows its frame,
            // and letting it drive the layout pushed the whole screen off-centre. This pins the frame
            // to the available space and clips the overflow, exactly as PostRowView does.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay { RemoteImage(id: "1518611012118-696072aa579a", width: 800, height: 1000) }
                .clipped()

            // Fade the photo into the canvas so the copy below reads as one continuous surface.
            LinearGradient(
                colors: [.clear, .clear, Color.flowWarmCream.opacity(0.9), Color.flowWarmCream],
                startPoint: .top, endPoint: .bottom
            )

            // Spacers guarantee the pill sits dead-centre: `.tracking` adds trailing letter-space
            // that widens the Text's frame on the right, which nudged a plain centered pill off-axis.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                logoPill
                Spacer(minLength: 0)
            }
            .padding(.top, 64)   // clear the status bar / Dynamic Island
        }
        .frame(maxHeight: .infinity)
    }

    private var logoPill: some View {
        Text("FLOWE")
            .font(FloweFont.mono(13))
            .tracking(3)
            .padding(.leading, 3)   // offset the trailing tracking space so the glyphs read centred
            .foregroundStyle(Color.flowePinkDeep)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.6), lineWidth: 1))
    }

    // MARK: - Copy + CTA

    private var copy: some View {
        VStack(spacing: 0) {
            (Text("Welcome to ").font(FloweFont.serif(30))
             + Text("Flowe.").font(FloweFont.serif(30, .regular, italic: true)))
                .foregroundStyle(Color.floweInk)
                .multilineTextAlignment(.center)
                .padding(.bottom, 12)

            Text("Your premium Pilates community. Connect with world-class instructors, build your practice, and grow together.")
                .font(FloweFont.sans(14))
                .foregroundStyle(Color.floweMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 4)
                .padding(.bottom, 28)

            dots
                .padding(.bottom, 28)

            GradientButton(title: "Get started") { onGetStarted() }
                .padding(.bottom, 12)

            SecondaryButton(title: "I already have an account") { onSignIn() }
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 40)
        .background(Color.flowWarmCream)
    }

    /// Three pips, the middle a wider gradient bar — lifted from the mockup's decorative row.
    private var dots: some View {
        HStack(spacing: 8) {
            Capsule().fill(Color.flowePink.opacity(0.5)).frame(width: 8, height: 8)
            Capsule().fill(FlowGradients.gradDark).frame(width: 22, height: 8)
            Capsule().fill(Color.flowSoftBeige).frame(width: 8, height: 8)
        }
    }
}

#Preview {
    WelcomeView(onGetStarted: {}, onSignIn: {})
}
