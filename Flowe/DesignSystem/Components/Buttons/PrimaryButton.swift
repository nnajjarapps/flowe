import SwiftUI

struct PrimaryButton: View {
    let title: String
    let action: () -> Void

    @GestureState private var isPressed = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .flowFont(.titleMedium)
                .foregroundStyle(Color.flowWhite)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.flowEspressoBrown)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .scaleEffect(isPressed ? 0.96 : 1)
                .animation(.spring(duration: 0.15), value: isPressed)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .updating($isPressed) { _, state, _ in state = true }
        )
    }
}

#Preview {
    PrimaryButton(title: "Get Started") {}
        .padding()
}
