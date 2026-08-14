import Observation

/// Cross-screen navigation state for the instructor experience — lets quick actions on the
/// Dashboard jump to another tab (and pre-select a Profile sub-tab).
@Observable
final class InstructorRouter {
    enum ProfileTab: String, CaseIterable, Identifiable {
        case overview  = "Overview"
        case analytics = "Analytics"
        case reviews   = "Reviews"
        case earnings  = "Earnings"
        var id: String { rawValue }
    }

    /// 0 Dashboard · 1 Calendar · 2 Messages · 3 Profile · 4 Community  (Students folded into the Dashboard)
    var selectedTab = 0
    var profileTab: ProfileTab = .overview

    /// A student thread the Messages tab should deep-link to on its next render. Consumed and cleared
    /// by `MessageListView` (same one-shot pattern as `PushService.pendingTopic`).
    var pendingCounterpart: Counterpart?

    func openMessages() { selectedTab = 2 }

    /// Open the Messages tab AND deep-link to a specific student's thread. The target is stashed
    /// for MessageListView to consume, then cleared after routing (same pattern as push.pendingTopic).
    func openConversation(with counterpart: Counterpart) {
        pendingCounterpart = counterpart
        selectedTab = 2
    }

    func openEarnings() {
        profileTab = .earnings
        selectedTab = 3
    }
}
