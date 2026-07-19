import SwiftUI

extension View {
    func floweBackground() -> some View {
        self.background(Color.floweCardBg.ignoresSafeArea())
    }

    func cardStyle(cornerRadius: CGFloat = 16) -> some View {
        self
            .background(Color.flowWhite)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: Color.flowePink.opacity(0.15), radius: 8, x: 0, y: 4)
    }
}
