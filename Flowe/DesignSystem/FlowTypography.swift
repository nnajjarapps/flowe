import SwiftUI

enum FlowFont {
    case displayLarge   // 32 bold
    case displayMedium  // 26 semibold
    case titleLarge     // 20 semibold
    case titleMedium    // 17 semibold
    case bodyLarge      // 16 regular
    case bodyMedium     // 14 regular
    case caption        // 12 regular
    case label          // 11 medium

    var font: Font {
        switch self {
        case .displayLarge:  return .system(size: 32, weight: .bold)
        case .displayMedium: return .system(size: 26, weight: .semibold)
        case .titleLarge:    return .system(size: 20, weight: .semibold)
        case .titleMedium:   return .system(size: 17, weight: .semibold)
        case .bodyLarge:     return .system(size: 16, weight: .regular)
        case .bodyMedium:    return .system(size: 14, weight: .regular)
        case .caption:       return .system(size: 12, weight: .regular)
        case .label:         return .system(size: 11, weight: .medium)
        }
    }
}

extension View {
    func flowFont(_ style: FlowFont) -> some View {
        self.font(style.font)
    }
}
