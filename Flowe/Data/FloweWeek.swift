import Foundation

/// The current week as real dates in the device's calendar, time zone and region.
///
/// Replaces the old hardcoded "Mon Jul 7 … Sun Jul 13" strings, which pinned the calendar and the
/// booking day-picker to a fixed week from the Figma mockup no matter the actual date. Seven days
/// beginning today, so the strip always starts at "now" and every offered day is bookable.
///
/// Display fields are formatted for the device region (the "sync with location" the UI needs).
/// The match/storage fields stay language-neutral (English, POSIX) on purpose: a booking's date
/// string is shared across users who may run different languages and is matched by weekday prefix,
/// so it must not shift with locale.
enum FloweWeek {
    struct Day: Identifiable, Hashable {
        let id: Int                   // ABSOLUTE day offset from today (today = 0, tomorrow = 1, …); negative for past
        let date: Date
        let isToday: Bool
        let displayWeekday: String    // localized, e.g. "Mon" / "lun." / "月"
        let displayNumber: String     // localized day-of-month
        let displayShortDate: String  // localized "Jul 7", for the booking picker
        let matchWeekday: String      // English "Mon" — stored on bookings, matched by prefix
        let pickerValue: String       // English "Mon Jul 7" — what a picked day stores
    }

    /// How far forward the booking/calendar horizon may page: offsets 0…11 (12 weeks / ~84 days),
    /// safely inside the ~26-week (182-day) ceiling of `Booking.sessionEnd`'s nearest-year date
    /// reconstruction. Never page before offset 0 (no past bookings) or beyond this.
    static let maxWeekOffset = 11

    /// The last selectable absolute day id — the final day of the last pageable week (11*7 + 6 = 83).
    static var maxDayID: Int { maxWeekOffset * 7 + 6 }

    /// Build a `Day` for `date`, tagged with its absolute offset-from-today `absOffset`.
    private static func makeDay(date: Date, absOffset: Int, calendar: Calendar) -> Day {
        Day(
            id: absOffset,
            date: date,
            isToday: calendar.isDateInToday(date),
            displayWeekday: localized(date, template: "EEE"),
            displayNumber: localized(date, template: "d"),
            displayShortDate: localized(date, template: "MMMd"),
            matchWeekday: english(date, format: "EEE"),
            pickerValue: english(date, format: "EEE MMM d")
        )
    }

    /// Seven days for the week at `offset` (0 = this week starting today, 1 = next week, …), in the
    /// device calendar and time zone. Ids are the absolute offset from today, so they stay unique
    /// across paged weeks: week `n` yields ids `7n … 7n+6`.
    static func week(offset: Int, now: Date = Date(), calendar: Calendar = .current) -> [Day] {
        let start = calendar.startOfDay(for: now)
        return (0..<7).map { i in
            let absOffset = offset * 7 + i
            let date = calendar.date(byAdding: .day, value: absOffset, to: start) ?? start
            return makeDay(date: date, absOffset: absOffset, calendar: calendar)
        }
    }

    /// Seven days starting today (week 0). Thin wrapper over `week(offset: 0)` — identical ids and
    /// behavior to before, for `WeekDay.all` callers that only want this week.
    static func current(now: Date = Date(), calendar: Calendar = .current) -> [Day] {
        week(offset: 0, now: now, calendar: calendar)
    }

    /// Localized range for the week header, e.g. "Jul 21 – Jul 27" (order follows the region).
    /// `offset` selects which paged week to label; default 0 keeps existing call sites working.
    static func rangeLabel(offset: Int = 0, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = week(offset: offset, now: now, calendar: calendar)
        guard let first = days.first?.date, let last = days.last?.date else { return "" }
        return "\(localized(first, template: "MMMd")) – \(localized(last, template: "MMMd"))"
    }

    // MARK: - Month overview grid

    /// One position in the month grid. `day == nil` is a leading/trailing pad blank that keeps the
    /// weeks aligned; `id` is the grid position (stable for `ForEach`), not a day offset.
    struct MonthCell: Identifiable, Hashable {
        let id: Int
        let day: Day?
    }

    /// A calendar-month grid for the month at `monthOffset` from the current month. Returns the
    /// localized month title, the weekday-symbol header (localized `veryShortWeekdaySymbols` rotated
    /// to the device's `firstWeekday`), and the aligned cells: leading blanks then one cell per real
    /// day. Each real day carries its absolute offset-from-today id (NEGATIVE for days before today,
    /// possibly `> maxDayID` for days beyond the cap) — the view dims/disables ids outside 0…maxDayID.
    static func monthGrid(monthOffset: Int = 0, now: Date = Date(), calendar: Calendar = .current) -> (title: String, weekdaySymbols: [String], cells: [MonthCell]) {
        let today = calendar.startOfDay(for: now)
        // First day of the target month.
        let startOfThisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
        let firstOfMonth = calendar.date(byAdding: .month, value: monthOffset, to: startOfThisMonth) ?? startOfThisMonth

        let title = localized(firstOfMonth, template: "yMMMM")

        // Weekday symbols rotated so index 0 == the device's first weekday.
        let symbols = calendar.veryShortWeekdaySymbols                 // index 0 = Sunday
        let rotate = calendar.firstWeekday - 1                          // firstWeekday is 1-based
        let weekdaySymbols = Array(symbols[rotate...] + symbols[..<rotate])

        // Leading blank count: how many pad cells before the 1st.
        let firstWeekdayComponent = calendar.component(.weekday, from: firstOfMonth)   // 1 = Sun … 7 = Sat
        let leadingBlanks = (firstWeekdayComponent - calendar.firstWeekday + 7) % 7
        let daysInMonth = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 30

        var cells: [MonthCell] = []
        var pos = 0
        for _ in 0..<leadingBlanks {
            cells.append(MonthCell(id: pos, day: nil))
            pos += 1
        }
        for dayNum in 0..<daysInMonth {
            let date = calendar.date(byAdding: .day, value: dayNum, to: firstOfMonth) ?? firstOfMonth
            let absOffset = calendar.dateComponents([.day], from: today, to: date).day ?? 0
            cells.append(MonthCell(id: pos, day: makeDay(date: date, absOffset: absOffset, calendar: calendar)))
            pos += 1
        }
        return (title: title, weekdaySymbols: weekdaySymbols, cells: cells)
    }

    /// The stored `Booking.date` string for a date ("Mon, Jul 7"), matching what the booking flow
    /// writes (see `MockDataStore.formatDay`). Language-neutral so it compares across users.
    static func bookingDateString(for date: Date) -> String {
        english(date, format: "EEE, MMM d")
    }

    /// Today's stored booking-date string — used to filter "today's" sessions.
    static var todayBookingDate: String { bookingDateString(for: Date()) }

    // MARK: - Practice / earnings week (Monday-first calendar week)
    //
    // Distinct from `current()` (a rolling 7 days from today, for the booking picker): stats like the
    // student practice chart and the instructor's weekly earnings are about *this calendar week*, and
    // are bucketed Monday…Sunday to match the "M T W T F S S" chart regardless of the device's
    // first-weekday setting.

    /// Monday 00:00 of the calendar week containing `now`.
    static func currentMonday(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: today)   // 1 = Sun … 7 = Sat
        let daysSinceMonday = (weekday + 5) % 7                   // Mon → 0 … Sun → 6
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: today) ?? today
    }

    /// The seven `startOfDay` dates Monday…Sunday of the week containing `now`.
    static func mondayWeekDays(now: Date = Date(), calendar: Calendar = .current) -> [Date] {
        let monday = currentMonday(now: now, calendar: calendar)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
    }

    /// Whether `date` falls inside the Monday-first week containing `now`.
    static func isInCurrentWeek(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let monday = currentMonday(now: now, calendar: calendar)
        guard let nextMonday = calendar.date(byAdding: .day, value: 7, to: monday) else { return false }
        return date >= monday && date < nextMonday
    }

    // MARK: - Formatting

    /// Region-aware: `setLocalizedDateFormatFromTemplate` reorders fields for the device locale.
    private static func localized(_ date: Date, template: String) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }

    /// Fixed English/POSIX — never shifts with locale, so stored dates stay matchable across users.
    private static func english(_ date: Date, format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: date)
    }
}
