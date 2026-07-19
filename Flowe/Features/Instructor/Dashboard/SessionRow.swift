import SwiftUI

/// A single row in "Today's Schedule" — start time on the left, student
/// (avatar + name from `data.instructors`), session type, and a subtle status.
struct SessionRow: View {
    @Environment(MockDataStore.self) private var data

    let session: DashboardSession

    private var student: Instructor? { data.instructor(id: session.studentId) }

    var body: some View {
        HStack(spacing: FlowSpacing.md) {
            // Time column
            VStack(alignment: .leading, spacing: 1) {
                Text(session.startTime)
                    .font(FloweFont.mono(13))
                    .foregroundStyle(Color.flowePinkDeep)
                Text(session.duration)
                    .font(FloweFont.mono(9))
                    .foregroundStyle(Color.floweMuted)
            }
            .frame(width: 54, alignment: .leading)

            // Hairline divider
            Rectangle()
                .fill(Color.floweBorder)
                .frame(width: 1, height: 40)

            // Student avatar
            AvatarView(id: student?.img ?? "", size: 42)

            // Student name + session type
            VStack(alignment: .leading, spacing: 3) {
                Text(student?.name ?? "Student")
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

#Preview {
    VStack(spacing: 12) {
        SessionRow(session: DashboardSession.sample[0])
        SessionRow(session: DashboardSession.sample[1])
    }
    .padding()
    .background(Color.flowWhite)
    .environment(MockDataStore.preview)
        .environment(AppSettings())
}
