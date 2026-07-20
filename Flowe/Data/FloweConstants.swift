import Foundation

/// Static scheduling + profile constants ported from the Figma mockup.
enum FloweConstants {
    /// Booking day picker (label → first 3 chars are matched against `Instructor.available`).
    static let days = ["Mon Jul 7", "Tue Jul 8", "Wed Jul 9", "Thu Jul 10", "Fri Jul 11", "Sat Jul 12", "Sun Jul 13"]

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
