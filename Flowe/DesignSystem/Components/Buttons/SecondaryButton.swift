import SwiftUI

struct SecondaryButton: View {
    let title: String
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
    }
}

#Preview {
    SecondaryButton(title: "Log In") {}
        .padding()
}
