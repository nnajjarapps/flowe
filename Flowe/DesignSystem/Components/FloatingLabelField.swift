import SwiftUI

struct FloatingLabelField: View {
    let title: String
    @Binding var text: String
    var isSecure: Bool = false

    @FocusState private var isFocused: Bool
    @State private var isRevealed = false

    private var isFloating: Bool { isFocused || !text.isEmpty }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(title)
                .flowFont(isFloating ? .label : .bodyLarge)
                .foregroundStyle(isFloating ? Color.flowePinkDeep : Color.floweMuted)
                .offset(y: isFloating ? -22 : 0)
                .animation(.spring(duration: 0.2), value: isFloating)

            Group {
                if isSecure && !isRevealed {
                    SecureField("", text: $text)
                } else {
                    TextField("", text: $text)
                }
            }
            .flowFont(.bodyLarge)
            .foregroundStyle(Color.floweInk)
            .focused($isFocused)
            .padding(.top, 8)

            if isSecure {
                HStack {
                    Spacer()
                    Button {
                        isRevealed.toggle()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .foregroundStyle(Color.floweMuted)
                    }
                }
            }
        }
        .padding(.horizontal, FlowSpacing.lg)
        .padding(.top, FlowSpacing.xl)
        .padding(.bottom, FlowSpacing.md)
        .background(Color.flowWhite)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isFocused ? Color.flowePinkDeep : Color.floweBorder, lineWidth: 1)
        )
    }
}

#Preview {
    @Previewable @State var email = ""
    @Previewable @State var password = ""
    VStack(spacing: 16) {
        FloatingLabelField(title: "Email Address", text: $email)
        FloatingLabelField(title: "Password", text: $password, isSecure: true)
    }
    .padding()
    .background(Color.floweCardBg)
}
