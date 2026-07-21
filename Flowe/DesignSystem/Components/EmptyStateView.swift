import SwiftUI

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

#Preview {
    EmptyStateView(
        icon: "sparkles",
        title: "No instructors yet",
        message: "Instructors near you will appear here once they join Flowe.",
        actionTitle: "Refresh",
        action: {}
    )
}
