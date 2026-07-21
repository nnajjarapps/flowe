import SwiftUI

// MARK: - Section header (uppercase mono meta label)

struct SectionHeader: View {
    let text: LocalizedStringKey
    var color: Color = .floweMuted

    var body: some View {
        Text(text)
            .font(FloweFont.mono(11))
            .foregroundStyle(color)
    }
}

// MARK: - Star rating (star glyph + number)

struct StarRatingView: View {
    let rating: Double
    var size: CGFloat = 10
    var tint: Color = .flowePink

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "star.fill")
                .font(.system(size: size))
                .foregroundStyle(tint)
            Text(String(format: "%.1f", rating))
                .font(FloweFont.mono(size + 1))
                .foregroundStyle(Color.flowePinkDeep)
        }
    }
}

// MARK: - Specialty / discipline pill

struct SpecialtyTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(FloweFont.mono(10))
            .foregroundStyle(Color.flowePinkDeep)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.flowePink.opacity(0.10))
            .clipShape(Capsule())
    }
}

// MARK: - Status badge (booking state)

struct StatusBadge: View {
    let status: BookingStatus

    var body: some View {
        Text(status.label)
            .font(FloweFont.mono(10))
            .foregroundStyle(status.badgeForeground)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(status.badgeBackground)
            .clipShape(Capsule())
    }
}

// MARK: - Stat tile (value over label)

struct StatTile: View {
    let value: String
    let label: LocalizedStringKey
    var accent: Color = .flowePinkDeep

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(FloweFont.serif(20, .medium))
                .foregroundStyle(accent)
            Text(label)
                .font(FloweFont.mono(10))
                .foregroundStyle(Color.floweMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(accent.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(accent.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Full-width pink gradient CTA

struct GradientButton: View {
    let title: LocalizedStringKey
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(FloweFont.sans(15, .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(FlowGradients.gradDark)
                .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
    }
}

// MARK: - Card surface (pale pink bg + hairline border)

extension View {
    func floweCard(cornerRadius: CGFloat = 16) -> some View {
        self
            .background(Color.floweCardBg)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.floweBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
