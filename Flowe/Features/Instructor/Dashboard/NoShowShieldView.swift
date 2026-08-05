import SwiftUI

/// No-Show Shield — the instructor's cancellation-protection surface. Three jobs, all instructor-private
/// (a student never sees any of it): the running tally of fees owed (collected off-app), a "did they
/// show?" queue for sessions that just happened, and a nudge list of risky upcoming bookings.
struct NoShowShieldView: View {
    @Environment(MockDataStore.self) private var data
    @Environment(AppSettings.self) private var settings
    @Environment(\.locale) private var locale

    private var awaiting: [Booking] { data.sessionsAwaitingAttendance }
    private var owed: [Booking] { data.owedFees }
    private var risky: [Booking] {
        data.incomingBookings
            .filter { data.isRisky($0) }
            .sorted { ($0.sessionStart() ?? .distantFuture) < ($1.sessionStart() ?? .distantFuture) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                owedHeader

                if !awaiting.isEmpty {
                    section("DID THEY SHOW?") { ForEach(awaiting) { attendanceRow($0) } }
                }
                if !owed.isEmpty {
                    section("FEES OWED") { ForEach(owed) { owedRow($0) } }
                }
                if !risky.isEmpty {
                    section("WORTH A NUDGE") { ForEach(risky) { riskRow($0) } }
                }
                if awaiting.isEmpty && owed.isEmpty && risky.isEmpty { emptyState }
            }
            .padding(20)
        }
        .background(Color.flowWhite)
        .navigationTitle("No-Show Shield")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Owed header

    private var owedHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OWED TO YOU")
                .font(FloweFont.mono(11))
                .foregroundStyle(Color.floweMuted)
            Text(settings.money(data.totalOwed))
                .font(FloweFont.serif(34, .medium))
                .foregroundStyle(data.totalOwed > 0 ? Color.flowePinkDeep : Color.floweInk)
            Text("Late-cancel and no-show fees you collect directly — Flowe only keeps the tally.")
                .font(FloweFont.sans(12))
                .foregroundStyle(Color.floweMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .floweCard(cornerRadius: 16)
    }

    // MARK: - Rows

    private func attendanceRow(_ booking: Booking) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            bookingLine(booking)
            HStack(spacing: 10) {
                Button { data.markAttendance(booking, attended: true) } label: {
                    Label("Attended", systemImage: "checkmark")
                        .font(FloweFont.sans(13, .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(Color.flowePinkDeep)
                        .background(Color.flowePink.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                }
                Button { data.markAttendance(booking, attended: false) } label: {
                    Label("No-show", systemImage: "xmark")
                        .font(FloweFont.sans(13, .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(FlowGradients.gradDark, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .floweCard(cornerRadius: 14)
    }

    private func owedRow(_ booking: Booking) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                bookingLine(booking, reason: booking.attendance == .noShow ? "No-show" : "Late cancel")
                Spacer(minLength: 8)
                Text(settings.money(booking.feeAmount))
                    .font(FloweFont.serif(17, .medium))
                    .foregroundStyle(Color.flowePinkDeep)
            }
            HStack(spacing: 10) {
                Button { data.resolveFee(booking, to: .collected) } label: {
                    Text("Collected")
                        .font(FloweFont.sans(13, .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(FlowGradients.gradDark, in: RoundedRectangle(cornerRadius: 12))
                }
                Button { data.resolveFee(booking, to: .waived) } label: {
                    Text("Waive")
                        .font(FloweFont.sans(13, .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(Color.floweMuted)
                        .background(Color.floweCardBg, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .floweCard(cornerRadius: 14)
    }

    private func riskRow(_ booking: Booking) -> some View {
        let strikes = booking.studentID.map { data.noShowStrikes(forStudentID: $0) } ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            bookingLine(booking, reason: strikes == 1 ? "1 prior no-show" : "\(strikes) prior no-shows")
            Button {
                guard let sid = booking.studentID else { return }
                // Resolve the live name so the DM greets the student by their current name, not a stale
                // "Member" snapshot.
                let name = data.displayIdentity(ownerID: sid, fallbackName: booking.studentName).name
                data.sendMessage(
                    to: Counterpart(id: sid, name: name),
                    text: "Hi \(name.split(separator: " ").first.map(String.init) ?? "there") — just confirming our \(booking.type) on \(booking.date) at \(booking.time). See you then! 🌸"
                )
            } label: {
                Label("Send confirmation", systemImage: "paperplane")
                    .font(FloweFont.sans(13, .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(Color.flowePinkDeep)
                    .background(Color.flowePink.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .floweCard(cornerRadius: 14)
    }

    // MARK: - Pieces

    private func bookingLine(_ booking: Booking, reason: String? = nil) -> some View {
        // Resolve the name from the live StudentProfile (like the avatar already does), not the frozen
        // booking snapshot — same fix as the Students list. See [[StudentsList]] / displayIdentity.
        let name = data.displayIdentity(ownerID: booking.studentID, fallbackName: booking.studentName).name
        return HStack(spacing: 12) {
            AvatarView(id: "", photo: data.studentPhoto(forOwnerID: booking.studentID ?? ""), size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(name.isEmpty ? "Client" : name)
                    .font(FloweFont.serif(15))
                    .foregroundStyle(Color.floweInk)
                (Text(booking.localizedDate(locale)) + Text(" · ") + Text(booking.localizedTime(locale)) + Text(" · ") + Text(localizedTag: booking.type))
                    .font(FloweFont.sans(12))
                    .foregroundStyle(Color.floweMuted)
                    .lineLimit(1)
                if let reason {
                    Text(reason)
                        .font(FloweFont.mono(10))
                        .foregroundStyle(Color.flowePinkDeep)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(text: title)
            content()
        }
    }

    @ViewBuilder private var emptyState: some View {
        if data.hasActiveCancellationPolicy {
            // Protection IS on — nothing owed yet.
            EmptyStateView(
                icon: "checkmark.shield",
                title: "You're covered",
                message: "No-shows and late cancels will show up here so you can collect the fee directly. Flowe only tracks what's owed — it never charges anyone."
            )
            .padding(.top, 40)
        } else {
            // Not set up — say so plainly and show how to turn it on.
            VStack(spacing: 16) {
                EmptyStateView(
                    icon: "shield.lefthalf.filled",
                    title: "Not set up yet",
                    message: "Add a cancellation policy to a lesson type and Flowe protects your income: cancel-within-window and no-shows are tracked here for you to collect directly. Students see the policy before they book."
                )
                Text("Set it on each lesson type in Edit Profile → your lesson types.")
                    .font(FloweFont.sans(12))
                    .foregroundStyle(Color.floweMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(.top, 40)
        }
    }
}
