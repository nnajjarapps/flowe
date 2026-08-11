import SwiftUI

/// "Who's in this class" — the community class-mates for a group booking (Flowe Community, slice 3).
/// Same opt-in reciprocity as the event roster: opted-in students see familiar faces AND appear to them;
/// everyone else gets the invite. A student doesn't cache others' bookings, so the roster is fetched
/// on-demand from the public slot. See [[Flowe-Community]].
struct ClassmatesSheet: View {
    @Environment(MockDataStore.self) private var data
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    let booking: Booking

    @State private var classmates: [(id: String, name: String)] = []
    @State private var loading = true
    @State private var selectedFriend: PeerRef?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if data.isCommunityVisible {
                        roster
                    } else {
                        invite
                    }
                }
                .padding(20)
            }
            .background(Color.flowWhite)
            .navigationTitle("Class-mates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Color.flowePinkDeep).fontWeight(.semibold)
                }
            }
            .task { await load() }
            .sheet(item: $selectedFriend) { PracticeFriendSheet(peer: $0) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localizedTag: booking.type)
                .font(FloweFont.serif(20, .medium))
                .foregroundStyle(Color.floweInk)
            Text("\(booking.localizedDate(locale)) · \(booking.localizedTime(locale))")
                .font(FloweFont.sans(13))
                .foregroundStyle(Color.floweMuted)
        }
    }

    @ViewBuilder
    private var roster: some View {
        if loading {
            HStack(spacing: 8) {
                ProgressView()
                Text("Finding your class-mates…")
                    .font(FloweFont.sans(13)).foregroundStyle(Color.floweMuted)
            }
        } else if classmates.isEmpty {
            Text("No one else in this class has joined the community yet. You'll see familiar faces here as they opt in.")
                .font(FloweFont.sans(14))
                .foregroundStyle(Color.floweMuted)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("^[\(classmates.count) class-mate](inflect: true) in this class")
                    .font(FloweFont.mono(10))
                    .foregroundStyle(Color.floweMuted)
                ForEach(classmates, id: \.id) { m in
                    Button { selectedFriend = PeerRef(id: m.id, name: m.name) } label: {
                        HStack(spacing: 12) {
                            if let photo = data.peerPhoto(forOwnerID: m.id) {
                                AvatarView(id: "", photo: photo, size: 44)
                            } else {
                                InitialAvatar(name: m.name, size: 44)
                            }
                            Text(m.name.isEmpty ? String(localized: "Someone") : m.name)
                                .font(FloweFont.sans(15, .medium))
                                .foregroundStyle(Color.floweInk)
                            Spacer(minLength: 0)
                            Image(systemName: data.isFollowing(m.id) ? "checkmark.circle.fill" : "person.badge.plus")
                                .font(.system(size: 15))
                                .foregroundStyle(data.isFollowing(m.id) ? Color.floweSuccess : Color.flowePinkDeep)
                        }
                        .padding(12)
                        .floweCard(cornerRadius: 14)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var invite: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("See familiar faces in your classes — and let your class-mates see you. Join the Flowe community.")
                .font(FloweFont.sans(14))
                .foregroundStyle(Color.floweInk)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                data.setCommunityVisible(true)
                Task { await load() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill").font(.system(size: 12))
                    Text("Join the community")
                }
                .font(FloweFont.sans(14, .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 11)
                .background(FlowGradients.gradDark, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("classmates.join")
        }
    }

    private func load() async {
        guard data.isCommunityVisible else { loading = false; return }
        loading = true
        await data.syncFollows()   // so each row shows the right follow state
        classmates = await data.fetchClassmates(for: booking)
        loading = false
    }
}
