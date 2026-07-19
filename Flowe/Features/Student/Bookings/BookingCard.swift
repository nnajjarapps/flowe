import SwiftUI

/// A single booking row: darkened image header band with avatar, name, meta and
/// status badge, over a body row with date / time and a trailing action button.
struct BookingCard: View {
    @Environment(MockDataStore.self) private var data

    let booking: Booking

    @State private var bookAgainInstructor: Instructor?

    private var instructor: Instructor? { data.instructor(id: booking.instructorId) }

    var body: some View {
        VStack(spacing: 0) {
            header
            bodyRow
        }
        .floweCard()
        .sheet(item: $bookAgainInstructor) { ins in
            BookingSheet(instructor: ins) { bookAgainInstructor = nil }
        }
    }

    // MARK: Header band

    private var header: some View {
        ZStack {
            Color.flowePinkPale

            FlowGradients.grad
                .opacity(0.5)

            if let instructor {
                RemoteImage(id: instructor.img, width: 600, height: 136)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .blendMode(.multiply)
                    .opacity(0.6)
            }

            HStack(spacing: 12) {
                if let instructor {
                    AvatarView(id: instructor.img, size: 40)
                        .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 2))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(instructor?.name ?? "")
                        .font(FloweFont.serif(14, .medium))
                        .foregroundStyle(.white)
                    Text("\(booking.type) · \(booking.duration)")
                        .font(FloweFont.mono(11))
                        .foregroundStyle(.white.opacity(0.8))
                }

                Spacer(minLength: 8)

                StatusBadge(status: booking.status)
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 68)
    }

    // MARK: Body row

    private var bodyRow: some View {
        HStack {
            HStack(spacing: 12) {
                metaLabel(icon: "calendar", text: booking.date)
                metaLabel(icon: "clock", text: booking.time)
            }

            Spacer(minLength: 8)

            if booking.status == .completed {
                Button {
                    bookAgainInstructor = instructor
                } label: {
                    Text("Book again")
                        .font(FloweFont.sans(11))
                        .foregroundStyle(Color.flowePinkDeep)
                }
            } else {
                Button {
                } label: {
                    Text("Cancel")
                        .font(FloweFont.sans(11))
                        .foregroundStyle(Color.floweMuted)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func metaLabel(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Color.floweMuted)
            Text(text)
                .font(FloweFont.sans(12))
                .foregroundStyle(Color.floweInk)
        }
    }
}

#Preview {
    let data = MockDataStore.preview
    return VStack(spacing: 12) {
        if let upcoming = data.upcomingBookings.first {
            BookingCard(booking: upcoming)
        }
        if let past = data.pastBookings.first {
            BookingCard(booking: past)
        }
    }
    .padding()
    .background(Color.flowWhite)
    .environment(data)
    .environment(AppSession())
}
