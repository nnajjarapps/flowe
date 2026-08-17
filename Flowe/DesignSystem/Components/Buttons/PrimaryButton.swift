import SwiftUI

struct PrimaryButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: { Haptic.tap(); action() }) {
            Text(title)
                .flowFont(.titleMedium)
                .foregroundStyle(Color.flowWhite)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(FlowGradients.gradDark)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        // Shared, reduce-motion-aware press feedback (0.96 scale + dim, FloweMotion.pop).
        .flowePressable()
    }
}
