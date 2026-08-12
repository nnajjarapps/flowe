import SwiftUI

struct SecondaryButton: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .flowFont(.titleMedium)
                .foregroundStyle(Color.flowePinkDeep)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.flowePinkDeep, lineWidth: 1.5)
                )
        }
        // Match PrimaryButton's press feedback — the two CTAs sit together on the first-run screens.
        .flowePressable()
    }
}
