import SwiftUI

/// A single chat bubble. Incoming messages sit on the left in a soft grey/pink
/// card; outgoing messages sit on the right in the deep-pink gradient with
/// white text. A small mono timestamp trails beneath.
struct MessageBubble: View {
    let isOutgoing: Bool
    let text: String
    let time: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        // A newly-sent/received bubble eases in from its own side and fades;
        // it leaves on a plain fade. Under Reduce Motion the slide is dropped
        // (opacity only) so nothing travels across the screen.
        .transition(bubbleTransition)
    }

    /// Asymmetric insertion: outgoing enters from the trailing edge, incoming
    /// from the leading edge — mirroring where the bubble lives.
    private var bubbleTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: isOutgoing ? .trailing : .leading).combined(with: .opacity),
            removal: .opacity
        )
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
