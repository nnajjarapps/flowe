import SwiftUI

/// A single row in "Today's Schedule" — session time + duration on the left,
/// the session type, and a subtle status badge. Driven by a real `Booking`.
struct SessionRow: View {
    let booking: Booking
    /// When set, this row represents a GROUPED group/duet class rather than a single booking: the
    /// number of students booked into the shared slot, plus the class capacity. The row then shows the
    /// type + an "N/M" gauge instead of one student's name + status. nil ⇒ today's single-booking row.
    var rosterCount: Int? = nil
    var capacity: Int? = nil
    @Environment(\.locale) private var locale
    @Environment(MockDataStore.self) private var data

    private var isGroup: Bool { rosterCount != nil && capacity != nil }

    /// A single (non-group) booking whose client carries a safety flag — surfaces the glanceable glyph.
    private var showFlag: Bool {
        !isGroup && data.clientNote(forStudentID: booking.studentID ?? "")?.hasFlags == true
    }

    /// The booker's CURRENT name, resolved live from their profile — not the snapshot
    /// `Booking.studentName` (re-stamped from the remote each sync). Falls back to the snapshot.
    private var resolvedStudentName: String {
        data.displayIdentity(ownerID: booking.studentID, fallbackName: booking.studentName).name
    }

    /// Row title: a grouped class shows its type; otherwise the student's name, else type + "Session".
    private var titleText: Text {
        if isGroup {
            if booking.type.isEmpty { return Text("Session") }
            return Text(localizedTag: booking.type) + Text(" ") + Text("Session")
        }
        if !resolvedStudentName.isEmpty { return Text(resolvedStudentName) }
        if booking.type.isEmpty { return Text("Session") }
        return Text(localizedTag: booking.type) + Text(" ") + Text("Session")
    }

    /// Subtitle: localized date alone, or localized date · localized session type. Visual caps come
    /// from `.textCase(.uppercase)` (a no-op for he/ar), never from `.uppercased()` before lookup.
    private var subtitleText: Text {
        let dateText = Text(booking.localizedDate(locale))
        if isGroup || resolvedStudentName.isEmpty { return dateText }
        return dateText + Text(" · ") + Text(localizedTag: booking.type)
    }

    var body: some View {
        HStack(spacing: FlowSpacing.md) {
            // Time column
            VStack(alignment: .leading, spacing: 1) {
                Text(booking.localizedTime(locale))
                    .font(FloweFont.mono(13))
                    .foregroundStyle(Color.flowePinkDeep)
                Text("\(booking.durationMinutes) min")
                    .textCase(.uppercase)
                    .font(FloweFont.mono(9))
                    .foregroundStyle(Color.floweMuted)
            }
            .frame(width: 64, alignment: .leading)

            // Hairline divider
            Rectangle()
                .fill(Color.floweBorder)
                .frame(width: 1, height: 40)

            // Who booked (instructor side) or session type, plus the date
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    titleText
                        .font(FloweFont.serif(16, .medium))
                        .foregroundStyle(Color.floweInk)
                        .lineLimit(1)
                    if showFlag { ClientNoteFlag(size: 10) }
                }
                subtitleText
                    .textCase(.uppercase)
                    .font(FloweFont.mono(10))
                    .foregroundStyle(Color.floweMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: FlowSpacing.sm)

            // A grouped class shows a fullness gauge (numbers are language-neutral) instead of a single
            // status badge — the roster spans several statuses, so no one badge fits.
            if let rosterCount, let capacity {
                Text(verbatim: "\(min(rosterCount, capacity))/\(capacity)")
                    .font(FloweFont.mono(11))
                    .foregroundStyle(Color.flowePinkDeep)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.flowePink.opacity(0.12))
                    .clipShape(Capsule())
            } else {
                StatusBadge(status: booking.status)
            }
        }
        .padding(FlowSpacing.md)
        .floweCard()
        .floweAppear()
    }
}
