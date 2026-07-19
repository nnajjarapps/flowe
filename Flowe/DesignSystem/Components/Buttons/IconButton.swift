import SwiftUI

struct IconButton: View {
    let systemName: String
    let action: () -> Void
    var size: CGFloat = 44
    var foregroundColor: Color = .floweInk
    var backgroundColor: Color = .flowSoftBeige

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(foregroundColor)
                .frame(width: size, height: size)
                .background(backgroundColor)
                .clipShape(Circle())
        }
    }
}

#Preview {
    IconButton(systemName: "heart.fill") {}
        .padding()
}
