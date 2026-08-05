import SwiftUI

/// The student-facing events tab inside Community: every upcoming instructor-hosted event, newest
/// registration state reconciled, joinable from the detail sheet.
///
/// Owns its own `ScrollView`/`.task` rather than nesting in the feed's edge-to-edge
/// stack, so the two Community sub-tabs never share scroll state (see `CommunityView`).
struct EventsListView: View {
    @Environment(MockDataStore.self) private var data

    @State private var selected: CommunityEvent?

    private var events: [CommunityEvent] { data.visibleEvents }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if events.isEmpty {
                    // No actionTitle/action: a student has nothing to create here, and the CTA only
                    // renders when both are non-nil. Instructors never see this view.
                    FeedPlaceholder(phase: data.eventsPhase,
                                    retry: { Task { await data.syncEvents(asOrganizer: false) } }) {
                        EmptyStateView(
                            icon: "sparkles",
                            title: "No events yet",
                            message: "When instructors host a class, a workshop or a retreat, it'll show up here."
                        )
                    }
                    .padding(.top, 80)
                } else {
                    ForEach(events) { event in
                        EventCardView(event: event, style: .hero) { selected = event }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .background(Color.flowWhite)
        .task { await data.syncEvents(asOrganizer: false) }
        // Manual pull-to-refresh: pulls newly-hosted events and updated fullness / your request state.
        .refreshable { await data.syncEvents(asOrganizer: false) }
        .sheet(item: $selected) { event in
            EventDetailView(event: event)
        }
        .alert(joinAlertTitle,
               isPresented: joinAlertPresented,
               presenting: data.lastJoinOutcome) { _ in
            Button("OK", role: .cancel) { data.lastJoinOutcome = nil }
        } message: { outcome in
            Text(joinAlertMessage(outcome))
        }
    }

    // MARK: - Join outcome alert
    //
    // Surfaced here (not from the store) via a computed binding — the `ComposePostSheet` rejection
    // idiom. `.missedOut` is a lost race for the last spot; `.notSent` is a failed write.

    private var joinAlertPresented: Binding<Bool> {
        Binding(
            get: { data.lastJoinOutcome != nil },
            set: { if !$0 { data.lastJoinOutcome = nil } }
        )
    }

    private var joinAlertTitle: LocalizedStringKey {
        switch data.lastJoinOutcome {
        case .notSent: return "We couldn't send that"
        default:       return "This event filled up"
        }
    }

    private func joinAlertMessage(_ outcome: MockDataStore.JoinOutcome) -> LocalizedStringKey {
        switch outcome {
        case .missedOut:
            return "Someone took the last spot while your request was on its way. You haven't been registered, and nothing has been charged."
        case .notSent:
            return "You're not registered yet. We'll try again next time the app refreshes."
        }
    }
}
