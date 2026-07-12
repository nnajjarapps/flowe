import SwiftUI

extension View {
    func floweBackground() -> some View {
        self.background(Color.flowWarmCream.ignoresSafeArea())
    }

    func cardStyle(cornerRadius: CGFloat = 16) -> some View {
        self
            .background(Color.flowWhite)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: Color.flowWarmGray.opacity(0.4), radius: 8, x: 0, y: 4)
    }
}
