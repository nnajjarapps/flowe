import Foundation

// MARK: - Week-strip day helper

/// The instructor calendar's day is the real current-week day (see `FloweWeek`), which replaced the
/// old fixed "Mon Jul 7" strings.
typealias WeekDay = FloweWeek.Day

extension FloweWeek.Day {
    /// The current week, in the device calendar/time zone, starting today.
    static var all: [WeekDay] { FloweWeek.current() }
}

// MARK: - Calendar view mode

/// The instructor calendar toggles between a paged week strip and a month overview grid.
enum CalendarViewMode {
    case week
    case month
}
