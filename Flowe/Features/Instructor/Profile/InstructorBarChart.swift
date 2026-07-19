import SwiftUI

/// A simple, reusable vertical bar chart for the instructor profile
/// (sessions-per-month, earnings-per-month, …). Bar height ∝ value; the
/// tallest bar fills `maxHeight`. Mono month label sits below each bar.
///
/// Mirrors the styling of `WeeklyBarChart` so the instructor screens read as
/// part of the same design system.
struct InstructorBarChart: View {
    struct Bar: Identifiable {
        let id = UUID()
        let label: String       // e.g. "JAN"
        let value: Int          // sessions, dollars, …
    }

    let bars: [Bar]
    /// Optional per-bar value formatter shown above the tallest / all bars.
    var showValues: Bool = false
    var valueFormat: (Int) -> String = { "\($0)" }

    private let maxHeight: CGFloat = 96
    private let stubHeight: CGFloat = 3

    private var maxValue: CGFloat {
        CGFloat(max(bars.map(\.value).max() ?? 1, 1))
    }

    private func height(for value: Int) -> CGFloat {
        value > 0 ? max((CGFloat(value) / maxValue) * maxHeight, 6) : stubHeight
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(bars) { bar in
                VStack(spacing: 6) {
                    Spacer(minLength: 0)

                    if showValues {
                        Text(valueFormat(bar.value))
                            .font(FloweFont.mono(9))
                            .foregroundStyle(Color.floweMuted)
                    }

                    RoundedRectangle(cornerRadius: 5)
                        .fill(bar.value > 0
                              ? AnyShapeStyle(FlowGradients.gradDark)
                              : AnyShapeStyle(Color.floweBorder))
                        .frame(height: height(for: bar.value))

                    Text(bar.label)
                        .font(FloweFont.mono(9))
                        .foregroundStyle(Color.floweMuted)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: maxHeight + 40, alignment: .bottom)
    }
}

#Preview {
    InstructorBarChart(
        bars: [
            .init(label: "MAR", value: 32),
            .init(label: "APR", value: 41),
            .init(label: "MAY", value: 28),
            .init(label: "JUN", value: 47),
            .init(label: "JUL", value: 39)
        ],
        showValues: true
    )
    .padding()
    .background(Color.flowWhite)
}
