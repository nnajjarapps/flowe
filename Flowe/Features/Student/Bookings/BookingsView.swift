import SwiftUI

private enum BookingTab: String, CaseIterable {
    case upcoming, past

    var label: String { rawValue.capitalized }
}

/// "My Sessions" — stat row, Upcoming/Past segmented control, and the booking list.
struct BookingsView: View {
    @Environment(MockDataStore.self) private var data

    @State private var tab: BookingTab = .upcoming

    private var list: [Booking] {
        tab == .upcoming ? data.upcomingBookings : data.pastBookings
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                title

                statRow
                    .padding(.top, 16)

                segmented
                    .padding(.top, 20)

                VStack(spacing: 12) {
                    ForEach(list) { booking in
                        BookingCard(booking: booking)
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        .background(Color.flowWhite)
    }

    // MARK: Title

    private var title: some View {
        (
            Text("My ")
                .font(FloweFont.serif(20))
            + Text("Sessions")
                .font(FloweFont.serif(20, .regular, italic: true))
        )
        .foregroundStyle(Color.floweInk)
    }

    // MARK: Stat row

    private var statRow: some View {
        HStack(spacing: 8) {
            StatTile(value: "\(data.upcomingCount)", label: "Upcoming", accent: .flowePinkDeep)
            StatTile(value: "\(data.completedCount)", label: "Completed", accent: .floweSuccess)
            StatTile(value: data.hoursDisplay, label: "Hours", accent: .flowePinkSoft)
        }
    }

    // MARK: Segmented control

    private var segmented: some View {
        HStack(spacing: 0) {
            ForEach(BookingTab.allCases, id: \.self) { t in
                Button {
                    tab = t
                } label: {
                    Text(t.label)
                        .font(FloweFont.sans(12, .medium))
                        .foregroundStyle(tab == t ? Color.floweInk : Color.floweMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(tab == t ? Color.flowWhite : Color.clear)
                                .shadow(
                                    color: tab == t ? Color.flowePink.opacity(0.15) : .clear,
                                    radius: 3, y: 1
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.floweCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    BookingsView()
        .environment(MockDataStore.preview)
        .environment(AppSettings())
        .environment(AppSession())
}
