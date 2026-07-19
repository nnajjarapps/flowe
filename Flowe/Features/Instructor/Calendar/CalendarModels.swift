import SwiftUI

// MARK: - Local calendar models (calendar-only; students drawn from data.instructors)

/// A booked teaching slot on a given weekday.
/// `dayIndex` maps to `FloweConstants.days` (0 = Mon … 6 = Sun).
/// `studentId` indexes into `data.instructors` for a name + avatar.
struct CalendarSession: Identifiable {
    let id: Int
    let dayIndex: Int
    let studentId: Int
    let time: String
    let duration: String
    let type: String
    let status: BookingStatus

    /// The instructor's booked slots for a given weekday. There is no real
    /// booking data yet, so every day is empty until students book sessions.
    static func sessions(on dayIndex: Int) -> [CalendarSession] {
        []
    }
}

/// A pending session request awaiting the instructor's decision.
/// Local `state` lets Accept / Decline toggle without a data layer.
struct BookingRequest: Identifiable {
    enum Decision { case pending, accepted, declined }

    let id: Int
    let studentId: Int
    let day: String
    let time: String
    let type: String
    let duration: String
    var state: Decision = .pending
}

// MARK: - Week-strip day helper

/// A parsed entry from `FloweConstants.days` ("Mon Jul 7").
struct WeekDay: Identifiable {
    let id: Int          // index 0…6
    let weekday: String  // "Mon"
    let number: String   // "7"

    static let all: [WeekDay] = FloweConstants.days.enumerated().map { index, raw in
        let parts = raw.split(separator: " ").map(String.init)
        return WeekDay(id: index,
                       weekday: parts.first ?? "",
                       number: parts.last ?? "")
    }
}
