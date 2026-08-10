import SwiftUI

/// A lightweight reference to a fellow student — drives `.sheet(item:)` from any surface where you meet
/// someone via shared context (a class-mate, a circle member, an event-goer).
struct PeerRef: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Follow / unfollow a practice-friend (Flowe Community slice 6). You only ever reach this for people you
/// met through a shared context, so following is never cold outreach. See [[Flowe-Community]].
struct PracticeFriendSheet: View {
    @Environment(MockDataStore.self) private var data
    @Environment(\.dismiss) private var dismiss

    let peer: PeerRef

    private var name: String { peer.name.isEmpty ? String(localized: "Someone") : peer.name }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if let photo = data.studentPhoto(forOwnerID: peer.id) {
                    AvatarView(id: "", photo: photo, size: 88)
                } else {
                    InitialAvatar(name: name, size: 88)
                }
                Text(name)
                    .font(FloweFont.serif(21, .medium))
                    .foregroundStyle(Color.floweInk)
                Text("Practice friend")
                    .font(FloweFont.mono(10))
                    .foregroundStyle(Color.floweMuted)
                followButton
                    .padding(.top, 8)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
            .background(Color.flowWhite)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.tint(Color.flowePinkDeep).fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.height(300)])
    }

    private var followButton: some View {
        let following = data.isFollowing(peer.id)
        return Button {
            Haptic.tap()
            if following { data.unfollow(peer.id) } else { data.follow(peer.id, name: peer.name) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: following ? "checkmark" : "person.badge.plus")
                    .font(.system(size: 13, weight: .semibold))
                Text(following ? "Following" : "Follow practice-friend")
            }
            .font(FloweFont.sans(15, .medium))
            .foregroundStyle(following ? Color.flowePinkDeep : .white)
            .padding(.horizontal, 26).padding(.vertical, 12)
            .background {
                if following { Capsule().stroke(Color.flowePinkDeep, lineWidth: 1) }
                else { Capsule().fill(FlowGradients.gradDark) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("friend.follow")
    }
}
