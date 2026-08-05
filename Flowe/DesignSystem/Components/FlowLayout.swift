import SwiftUI

/// Wrapping flow layout — places subviews along the reading direction and wraps to a new line when
/// the row runs out of width. Used for specialty / session-type / day pills.
///
/// A custom `Layout` does not auto-mirror, so this thin `View` wrapper reads
/// `@Environment(\.layoutDirection)` and hands it to the underlying `Layout`, which places pills from
/// the trailing (max X) edge leftward under `.rightToLeft` so rows mirror with the rest of the UI.
struct FlowLayout<Content: View>: View {
    private let spacing: CGFloat
    private let lineSpacing: CGFloat
    private let content: Content
    @Environment(\.layoutDirection) private var layoutDirection

    init(spacing: CGFloat = 6, lineSpacing: CGFloat = 6, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self.content = content()
    }

    var body: some View {
        FlowLayoutCore(spacing: spacing, lineSpacing: lineSpacing, layoutDirection: layoutDirection) {
            content
        }
    }
}

private struct FlowLayoutCore: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    var layoutDirection: LayoutDirection = .leftToRight

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rtl = layoutDirection == .rightToLeft
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            // Mirror horizontally under RTL: place from the trailing (max X) edge leftward.
            let placeX = rtl ? (bounds.minX + bounds.maxX - x - size.width) : x
            sub.place(at: CGPoint(x: placeX, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
