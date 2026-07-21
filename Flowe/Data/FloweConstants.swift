import Foundation

/// Static scheduling + profile constants ported from the Figma mockup.
enum FloweConstants {
    /// Owner id for a session with no Apple credential — previews and UI tests, which never sign in.
    /// Shared so seeded instructor-side data and `AppSession.ownerID` can't drift apart.
    static let localOwnerID = "local-user"

    // The booking day picker and instructor calendar now derive their days from the real current
    // week — see `FloweWeek`. The old fixed "Mon Jul 7 … Sun Jul 13" array is gone.

    /// English weekday abbreviations, in week order. Bookings store and match on these, so they
    /// stay English regardless of display language (see `FloweWeek.matchWeekday`).
    ///
    /// Deliberately not a static on `Instructor`: referencing a static member of a `@Model` type
    /// from a View's stored-property initializer miscompiles, and the diagnostic surfaces in an
    /// unrelated file.
    static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    static let times = ["8:00 AM", "9:00 AM", "10:00 AM", "11:00 AM", "2:00 PM", "3:30 PM", "5:00 PM", "6:00 PM"]

    static let discoverCategories = ["All", "Mat", "Reformer", "Barre", "Tower", "Prenatal", "Rehab"]

}

/// Small profile-screen models (Figma inlines these).
struct Achievement: Identifiable {
    let id = UUID()
    let systemIcon: String
    let label: String
    let sub: String
}

struct WeeklyBar: Identifiable {
    let id = UUID()
    let day: String
    let minutes: Int   // 0 = rest day
}

enum ProfileMock {
    /// Real account menu rows (not mock content) — kept for the ACCOUNT list.
    static let accountRows = ["Notifications", "Payment methods", "Privacy", "Help & Support", "Log out"]
}
