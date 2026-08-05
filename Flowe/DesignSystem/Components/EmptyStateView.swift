import SwiftUI

/// The state of an async-loaded feed. Lets a screen tell apart "first load in flight", "loaded with
/// nothing", and "the load failed" — three things that otherwise all render as the same empty state.
enum LoadPhase: Equatable {
    case idle       // never fetched yet
    case loading    // a fetch is in flight and there's no cached data to show
    case loaded     // a fetch succeeded (the list may still be genuinely empty)
    case failed     // the fetch failed and there's no cached data to fall back on
}

/// Placeholder for an async list slot. Render this ONLY when the list is actually empty — when there's
/// cached data, show the data, because a background refresh failing must never blank what's on screen.
/// Picks the spinner / error+retry / caller's empty state based on `phase`.
struct FeedPlaceholder<EmptyContent: View>: View {
    let phase: LoadPhase
    let retry: () -> Void
    @ViewBuilder let empty: () -> EmptyContent

    var body: some View {
        switch phase {
        case .failed:
            ErrorStateView(retry: retry)
        case .loading:
            LoadingStateView()
        case .idle, .loaded:
            // `.idle` = no fetch has run (offline/preview, where syncs short-circuit) — show the empty
            // state, not a spinner that would never resolve. A real first load flips to `.loading`
            // the instant its sync starts.
            empty()
        }
    }
}

/// Shown while a feed's first load is in flight and there's nothing cached to show yet.
struct LoadingStateView: View {
    var message: LocalizedStringKey = "Loading…"

    var body: some View {
        VStack(spacing: FlowSpacing.md) {
            ProgressView().tint(Color.flowePink)
            Text(message)
                .font(FloweFont.sans(13))
                .foregroundStyle(Color.floweMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, FlowSpacing.xxl)
    }
}

/// Shown when a feed's load failed with no cached data to fall back on — distinct from "empty", and
/// with a retry so the user isn't stranded staring at what looks like an empty screen.
struct ErrorStateView: View {
    var title: LocalizedStringKey = "Couldn't load"
    var message: LocalizedStringKey = "Something went wrong. Check your connection and try again."
    let retry: () -> Void

    var body: some View {
        VStack(spacing: FlowSpacing.md) {
            ZStack {
                Circle()
                    .fill(Color.flowePink.opacity(0.10))
                    .frame(width: 72, height: 72)
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Color.flowePinkSoft)
            }

            VStack(spacing: 4) {
                Text(title)
                    .font(FloweFont.serif(18))
                    .foregroundStyle(Color.floweInk)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(FloweFont.sans(13))
                    .foregroundStyle(Color.floweMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)

            Button(action: retry) {
                Text("Try Again")
                    .font(FloweFont.sans(14, .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(FlowGradients.gradDark, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, FlowSpacing.xxl)
    }
}

/// Reusable empty-state placeholder — a soft icon, title, message, and optional call-to-action.
/// Used across screens when there's no real data yet (pilot/beta).
struct EmptyStateView: View {
    let icon: String
    // LocalizedStringKey, not String: `Text(someString)` does not localize, and Xcode's string
    // extraction cannot see literals passed into a String parameter.
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var actionTitle: LocalizedStringKey? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: FlowSpacing.md) {
            ZStack {
                Circle()
                    .fill(Color.flowePink.opacity(0.10))
                    .frame(width: 72, height: 72)
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.flowePinkSoft)
            }

            VStack(spacing: 4) {
                Text(title)
                    .font(FloweFont.serif(18))
                    .foregroundStyle(Color.floweInk)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(FloweFont.sans(13))
                    .foregroundStyle(Color.floweMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(FloweFont.sans(14, .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 11)
                        .background(FlowGradients.gradDark, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, FlowSpacing.xxl)
    }
}
