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

    /// One week of teaching slots. Times use `FloweConstants.times`.
    static let week: [CalendarSession] = [
        // Monday
        CalendarSession(id: 1, dayIndex: 0, studentId: 1, time: FloweConstants.times[1], duration: "55 MIN", type: "Private", status: .confirmed),
        CalendarSession(id: 2, dayIndex: 0, studentId: 5, time: FloweConstants.times[3], duration: "55 MIN", type: "Duet",    status: .confirmed),
        CalendarSession(id: 3, dayIndex: 0, studentId: 3, time: FloweConstants.times[6], duration: "45 MIN", type: "Online",  status: .pending),
        // Tuesday
        CalendarSession(id: 4, dayIndex: 1, studentId: 2, time: FloweConstants.times[0], duration: "55 MIN", type: "Private", status: .confirmed),
        CalendarSession(id: 5, dayIndex: 1, studentId: 4, time: FloweConstants.times[4], duration: "50 MIN", type: "Group",   status: .confirmed),
        // Wednesday
        CalendarSession(id: 6, dayIndex: 2, studentId: 6, time: FloweConstants.times[2], duration: "55 MIN", type: "Private", status: .confirmed),
        CalendarSession(id: 7, dayIndex: 2, studentId: 1, time: FloweConstants.times[5], duration: "45 MIN", type: "Online",  status: .completed),
        // Thursday
        CalendarSession(id: 8, dayIndex: 3, studentId: 3, time: FloweConstants.times[1], duration: "55 MIN", type: "Duet",    status: .confirmed),
        // Friday
        CalendarSession(id: 9,  dayIndex: 4, studentId: 5, time: FloweConstants.times[0], duration: "55 MIN", type: "Private", status: .confirmed),
        CalendarSession(id: 10, dayIndex: 4, studentId: 2, time: FloweConstants.times[3], duration: "50 MIN", type: "Duet",    status: .confirmed),
        CalendarSession(id: 11, dayIndex: 4, studentId: 4, time: FloweConstants.times[7], duration: "45 MIN", type: "Online",  status: .pending),
        // Saturday
        CalendarSession(id: 12, dayIndex: 5, studentId: 6, time: FloweConstants.times[2], duration: "55 MIN", type: "Group",   status: .confirmed)
        // Sunday — rest day, no sessions
    ]

    static func sessions(on dayIndex: Int) -> [CalendarSession] {
        week.filter { $0.dayIndex == dayIndex }
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

    static let sample: [BookingRequest] = [
        BookingRequest(id: 1, studentId: 4, day: "Thu Jul 10", time: FloweConstants.times[4], type: "Private", duration: "55 min"),
        BookingRequest(id: 2, studentId: 6, day: "Sat Jul 12", time: FloweConstants.times[6], type: "Duet",    duration: "50 min")
    ]
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
