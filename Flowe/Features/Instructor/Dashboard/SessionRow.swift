import SwiftUI

/// A single row in "Today's Schedule" — session time + duration on the left,
/// the session type, and a subtle status badge. Driven by a real `Booking`.
struct SessionRow: View {
    let booking: Booking

    var body: some View {
        HStack(spacing: FlowSpacing.md) {
            // Time column
            VStack(alignment: .leading, spacing: 1) {
                Text(booking.time)
                    .font(FloweFont.mono(13))
                    .foregroundStyle(Color.flowePinkDeep)
                Text(booking.duration.uppercased())
                    .font(FloweFont.mono(9))
                    .foregroundStyle(Color.floweMuted)
            }
            .frame(width: 64, alignment: .leading)

            // Hairline divider
            Rectangle()
                .fill(Color.floweBorder)
                .frame(width: 1, height: 40)

            // Session type + date
            VStack(alignment: .leading, spacing: 3) {
                Text(booking.type.isEmpty ? "Session" : "\(booking.type) Session")
                    .font(FloweFont.serif(16, .medium))
                    .foregroundStyle(Color.floweInk)
                    .lineLimit(1)
                Text(booking.date.uppercased())
                    .font(FloweFont.mono(10))
                    .foregroundStyle(Color.floweMuted)
            }

            Spacer(minLength: FlowSpacing.sm)

            StatusBadge(status: booking.status)
        }
        .padding(FlowSpacing.md)
        .floweCard()
    }
}

#Preview {
    let data = MockDataStore.preview
    return VStack(spacing: 12) {
        ForEach(data.bookings.prefix(2)) { booking in
            SessionRow(booking: booking)
        }
    }
    .padding()
    .background(Color.flowWhite)
    .environment(data)
    .environment(AppSettings())
}
