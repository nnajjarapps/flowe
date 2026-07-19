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

    /// 0 Dashboard · 1 Calendar · 2 Messages · 3 Profile
    var selectedTab = 0
    var profileTab: ProfileTab = .overview

    func openMessages() { selectedTab = 2 }

    func openEarnings() {
        profileTab = .earnings
        selectedTab = 3
    }
}
