import Foundation

/// Static scheduling + profile constants ported from the Figma mockup.
enum FloweConstants {
    /// Booking day picker (label → first 3 chars are matched against `Instructor.available`).
    static let days = ["Mon Jul 7", "Tue Jul 8", "Wed Jul 9", "Thu Jul 10", "Fri Jul 11", "Sat Jul 12", "Sun Jul 13"]

    static let times = ["8:00 AM", "9:00 AM", "10:00 AM", "11:00 AM", "2:00 PM", "3:30 PM", "5:00 PM", "6:00 PM"]

    static let discoverCategories = ["All", "Mat", "Reformer", "Barre", "Tower", "Prenatal", "Rehab"]

    static let serviceFee = 9
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
    static let achievements = [
        Achievement(systemIcon: "flame.fill", label: "9-day streak",  sub: "Best: 18"),
        Achievement(systemIcon: "rosette",    label: "14 sessions",   sub: "This month"),
        Achievement(systemIcon: "star.fill",  label: "5 instructors", sub: "Worked with"),
    ]

    static let weeklyBars = [
        WeeklyBar(day: "M", minutes: 55),
        WeeklyBar(day: "T", minutes: 0),
        WeeklyBar(day: "W", minutes: 60),
        WeeklyBar(day: "T", minutes: 55),
        WeeklyBar(day: "F", minutes: 45),
        WeeklyBar(day: "S", minutes: 50),
        WeeklyBar(day: "S", minutes: 0),
    ]

    static let weeklyTotalMinutes = 265

    static let accountRows = ["Notifications", "Payment methods", "Privacy", "Help & Support", "Log out"]
}
