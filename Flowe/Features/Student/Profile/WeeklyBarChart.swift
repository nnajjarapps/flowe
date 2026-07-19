import SwiftUI

/// A custom 7-bar weekly practice chart.
/// Bar height ∝ minutes (max ~60 → ~44pt). Active days use the deep pink
/// gradient; rest days (0 min) show a short hairline stub. Mono day letter below.
struct WeeklyBarChart: View {
    var bars: [WeeklyBar] = ProfileMock.weeklyBars

    private let maxMinutes: CGFloat = 60
    private let maxHeight: CGFloat = 44
    private let stubHeight: CGFloat = 3

    private func height(for minutes: Int) -> CGFloat {
        minutes > 0 ? (CGFloat(minutes) / maxMinutes) * maxHeight : stubHeight
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(bars) { bar in
                VStack(spacing: 4) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(bar.minutes > 0
                              ? AnyShapeStyle(FlowGradients.gradDark)
                              : AnyShapeStyle(Color.floweBorder))
                        .frame(height: height(for: bar.minutes))
                    Text(bar.day)
                        .font(FloweFont.mono(9))
                        .foregroundStyle(Color.floweMuted)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: maxHeight + 20, alignment: .bottom)
    }
}

#Preview {
    WeeklyBarChart()
        .padding()
        .background(Color.flowWhite)
}
