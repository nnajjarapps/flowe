import SwiftUI

// MARK: - Week-strip day pill

/// A selectable weekday pill. Selected uses the deep-pink gradient; a small dot
/// marks days that have sessions.
struct WeekDayPill: View {
    let day: WeekDay
    let isSelected: Bool
    let hasSessions: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(day.weekday.uppercased())
                    .font(FloweFont.mono(10))
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : Color.floweMuted)

                Text(day.number)
                    .font(FloweFont.serif(18, .medium))
                    .foregroundStyle(isSelected ? .white : Color.floweInk)

                Circle()
                    .fill(dotColor)
                    .frame(width: 5, height: 5)
            }
            .frame(width: 46)
            .padding(.vertical, 12)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(FlowGradients.gradDark)
                } else {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.floweCardBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(Color.floweBorder, lineWidth: 1)
                        )
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var dotColor: Color {
        if isSelected { return hasSessions ? .white.opacity(0.9) : .clear }
        return hasSessions ? .flowePink : .clear
    }
}

// MARK: - Session card (selected day)

/// A booked slot on the selected day: time column, student avatar + name,
/// session type, and a status badge.
struct CalendarSessionCard: View {
    let session: Booking

    var body: some View {
        HStack(spacing: FlowSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.time)
                    .font(FloweFont.mono(12))
                    .foregroundStyle(Color.flowePinkDeep)
                Text(session.duration)
                    .font(FloweFont.mono(9))
                    .foregroundStyle(Color.floweMuted)
            }
            .frame(width: 62, alignment: .leading)

            Rectangle()
                .fill(Color.floweBorder)
                .frame(width: 1, height: 40)

            AvatarView(id: "", size: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.studentName.isEmpty ? "Student" : session.studentName)
                    .font(FloweFont.serif(16, .medium))
                    .foregroundStyle(Color.floweInk)
                    .lineLimit(1)
                Text(session.type.uppercased())
                    .font(FloweFont.mono(10))
                    .foregroundStyle(Color.floweMuted)
            }

            Spacer(minLength: FlowSpacing.sm)

            StatusBadge(status: session.status)
        }
        .padding(FlowSpacing.md)
        .floweCard()
    }
}

// MARK: - Empty state (rest day)

struct CalendarEmptyState: View {
    var body: some View {
        VStack(spacing: FlowSpacing.sm) {
            Image(systemName: "leaf")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.flowePinkSoft)
            Text("No sessions")
                .font(FloweFont.serif(17, .regular, italic: true))
                .foregroundStyle(Color.floweInk)
            Text("A quiet day to rest and restore.")
                .font(FloweFont.sans(12))
                .foregroundStyle(Color.floweMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, FlowSpacing.xxl)
        .floweCard()
    }
}

// MARK: - Booking request card (Accept / Decline)

/// A pending request with student, when, and two actions. Accepting or declining publishes the
/// instructor's decision to the shared database, which is how the student learns the outcome.
/// On decision the card collapses to a resolved confirmation line.
struct BookingRequestCard: View {
    @Environment(MockDataStore.self) private var data

    let request: Booking

    var body: some View {
        VStack(alignment: .leading, spacing: FlowSpacing.md) {
            HStack(spacing: FlowSpacing.md) {
                AvatarView(id: "", size: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(request.studentName.isEmpty ? "A student" : request.studentName)
                        .font(FloweFont.serif(16, .medium))
                        .foregroundStyle(Color.floweInk)
                        .lineLimit(1)
                    Text("\(request.type.uppercased()) · \(request.duration.uppercased())")
                        .font(FloweFont.mono(10))
                        .foregroundStyle(Color.floweMuted)
                }

                Spacer(minLength: FlowSpacing.sm)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(request.date)
                        .font(FloweFont.mono(11))
                        .foregroundStyle(Color.flowePinkDeep)
                    Text(request.time)
                        .font(FloweFont.mono(10))
                        .foregroundStyle(Color.floweMuted)
                }
            }

            switch request.status {
            case .pending:
                HStack(spacing: FlowSpacing.sm) {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            data.respond(to: request, confirmed: false)
                        }
                    } label: {
                        Text("Decline")
                            .font(FloweFont.sans(13, .medium))
                            .foregroundStyle(Color.flowePinkDeep)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.flowePink.opacity(0.4), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("request.decline")

                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            data.respond(to: request, confirmed: true)
                        }
                    } label: {
                        Text("Accept")
                            .font(FloweFont.sans(13, .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(FlowGradients.gradDark)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("request.accept")
                }
            case .cancelled:
                resolvedRow(icon: "xmark.circle.fill", text: "Declined", tint: .floweCancel)
            default:
                resolvedRow(icon: "checkmark.circle.fill", text: "Accepted", tint: .floweSuccess)
            }
        }
        .padding(FlowSpacing.lg)
        .floweCard()
    }

    private func resolvedRow(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(tint)
            Text(text)
                .font(FloweFont.sans(13, .medium))
                .foregroundStyle(tint)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
