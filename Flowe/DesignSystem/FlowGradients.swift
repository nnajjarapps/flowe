import SwiftUI

enum FlowGradients {
    // #F2EAE3 → #F9D7DD  (event cards)
    static let gradient1 = LinearGradient(
        colors: [Color(hex: 0xF2EAE3), Color(hex: 0xF9D7DD)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // #FAF6F2 → #EBC0C8  (splash background)
    static let gradient2 = LinearGradient(
        colors: [Color(hex: 0xFAF6F2), Color(hex: 0xEBC0C8)],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: - Figma pink gradients (135°)

    // #E8789A → #F4A8C0 → #FFC2D4  (cards, avatars, overlays)
    static let grad = LinearGradient(
        colors: [Color(hex: 0xE8789A), Color(hex: 0xF4A8C0), Color(hex: 0xFFC2D4)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // #D45880 → #E8789A → #F4A8C0  (primary CTAs, active chips, story rings)
    static let gradDark = LinearGradient(
        colors: [Color(hex: 0xD45880), Color(hex: 0xE8789A), Color(hex: 0xF4A8C0)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
