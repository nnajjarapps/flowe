import SwiftUI

enum QuickActionKind {
    case availability, messages, earnings, editProfile, createEvent

    /// Stable, non-localized token for the tile's accessibilityIdentifier (`dashboard.action.<id>`),
    /// so a UI test can tap a tile without matching translated text.
    var id: String {
        switch self {
        case .availability: return "availability"
        case .messages:     return "messages"
        case .earnings:     return "earnings"
        case .editProfile:  return "editProfile"
        case .createEvent:  return "createEvent"
        }
    }
}

/// A single quick-action model (SF Symbol + label + tint).
struct QuickAction: Identifiable {
    let id = UUID()
    let kind: QuickActionKind
    let systemIcon: String
    let title: String
    let subtitle: String

    static let all: [QuickAction] = [
        QuickAction(kind: .availability, systemIcon: "calendar.badge.plus", title: "Add availability", subtitle: "Open new slots"),
        QuickAction(kind: .messages, systemIcon: "bubble.left.and.bubble.right.fill", title: "Message students", subtitle: "Chat with students"),
        QuickAction(kind: .earnings, systemIcon: "chart.line.uptrend.xyaxis", title: "View earnings", subtitle: "This month"),
        QuickAction(kind: .editProfile, systemIcon: "person.crop.circle.badge.checkmark", title: "Edit profile", subtitle: "Bio & rates"),
        QuickAction(kind: .createEvent, systemIcon: "sparkles", title: "Host an event", subtitle: "Class or workshop")
    ]
}

/// 2-column grid of tappable action tiles.
struct QuickActionsGrid: View {
    var onTap: (QuickAction) -> Void = { _ in }

    private let columns = [
        GridItem(.flexible(), spacing: FlowSpacing.md),
        GridItem(.flexible(), spacing: FlowSpacing.md)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: FlowSpacing.md) {
            ForEach(QuickAction.all) { action in
                Button {
                    onTap(action)
                } label: {
                    QuickActionTile(action: action)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("dashboard.action.\(action.kind.id)")
            }
        }
    }
}

private struct QuickActionTile: View {
    let action: QuickAction

    var body: some View {
        VStack(alignment: .leading, spacing: FlowSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.flowePink.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: action.systemIcon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Color.flowePinkDeep)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(action.title))
                    .font(FloweFont.sans(14, .medium))
                    .foregroundStyle(Color.floweInk)
                    .lineLimit(1)
                Text(LocalizedStringKey(action.subtitle))
                    .font(FloweFont.mono(9))
                    .foregroundStyle(Color.floweMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(FlowSpacing.lg)
        .floweCard()
    }
}

#Preview {
    QuickActionsGrid()
        .padding()
        .background(Color.flowWhite)
}
