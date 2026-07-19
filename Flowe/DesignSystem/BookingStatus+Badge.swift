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

    var badgeForeground: Color {
        switch self {
        case .confirmed: return .floweSuccess
        case .pending:   return .flowePinkDeep
        case .completed: return .floweMuted
        case .cancelled: return .floweCancel
        }
    }
}
