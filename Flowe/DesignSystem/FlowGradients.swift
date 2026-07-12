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
}
