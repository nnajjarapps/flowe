import SwiftUI

/// Horizontal scrolling category selector (Discover screen).
struct FilterChipsBar: View {
    let items: [String]
    @Binding var selection: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    CategoryChip(title: item, isSelected: selection == item) {
                        withAnimation(.easeInOut(duration: 0.15)) { selection = item }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

struct CategoryChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(FloweFont.sans(12, .medium))
                .foregroundStyle(isSelected ? .white : Color.floweInk)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background {
                    if isSelected {
                        FlowGradients.gradDark
                    } else {
                        Color.floweCardBg
                    }
                }
                .overlay(
                    Capsule().stroke(isSelected ? Color.clear : Color.floweBorder, lineWidth: 1)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
