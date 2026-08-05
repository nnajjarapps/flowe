import SwiftUI

/// Presentation for `BookingStatus` — kept out of the `@Model` layer.
extension BookingStatus {
    var badgeBackground: Color {
        switch self {
        case .confirmed: return Color.floweSuccess.opacity(0.15)
        case .pending:   return Color.flowePink.opacity(0.18)
        case .completed: return Color.floweCardBg
        case .cancelled: return Color.floweCancel.opacity(0.12)
        }
    }

    // Foregrounds darkened where needed to clear WCAG AA >=4.5:1 on each case's own tint.
    // .floweSuccess and .floweMuted are already darkened in FlowColor; pending/cancelled use
    // deeper on-palette literals than their shared tokens (which serve lighter roles elsewhere).
    var badgeForeground: Color {
        switch self {
        case .confirmed: return .floweSuccess
        case .pending:   return Color(hex: 0xA83D63)
        case .completed: return .floweMuted
        case .cancelled: return Color(hex: 0xC0304F)
        }
    }
}
