import SwiftUI

/// A single chat bubble. Incoming messages sit on the left in a soft grey/pink
/// card; outgoing messages sit on the right in the deep-pink gradient with
/// white text. A small mono timestamp trails beneath.
struct MessageBubble: View {
    let isOutgoing: Bool
    let text: String
    let time: String

    var body: some View {
        HStack {
            if isOutgoing { Spacer(minLength: 48) }

            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                Text(text)
                    .font(FloweFont.sans(14))
                    .foregroundStyle(isOutgoing ? .white : Color.floweInk)
                    .lineSpacing(3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleBackground)
                    .clipShape(bubbleShape)
                    .overlay(
                        bubbleShape
                            .stroke(isOutgoing ? Color.clear : Color.floweBorder, lineWidth: 1)
                    )

                Text(time)
                    .font(FloweFont.mono(9))
                    .foregroundStyle(Color.floweMuted)
                    .padding(.horizontal, 4)
            }

            if !isOutgoing { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if isOutgoing {
            FlowGradients.gradDark
        } else {
            Color.floweCardBg
        }
    }

    private var bubbleShape: some Shape {
        UnevenRoundedRectangle(
            topLeadingRadius: 18,
            bottomLeadingRadius: isOutgoing ? 18 : 4,
            bottomTrailingRadius: isOutgoing ? 4 : 18,
            topTrailingRadius: 18
        )
    }
}

#Preview {
    VStack(spacing: 12) {
        MessageBubble(isOutgoing: false, text: "Hi! Looking forward to our reformer session tomorrow. 🌸", time: "9:24 AM")
        MessageBubble(isOutgoing: true, text: "Me too! Should I bring my grip socks?", time: "9:26 AM")
        MessageBubble(isOutgoing: false, text: "Yes please — and some water. See you at 10.", time: "9:27 AM")
    }
    .padding(20)
    .background(Color.flowWhite)
}
