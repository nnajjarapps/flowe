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
        let id: Int
        let date: Date
        let isToday: Bool
        let displayWeekday: String    // localized, e.g. "Mon" / "lun." / "月"
        let displayNumber: String     // localized day-of-month
        let displayShortDate: String  // localized "Jul 7", for the booking picker
        let matchWeekday: String      // English "Mon" — stored on bookings, matched by prefix
        let pickerValue: String       // English "Mon Jul 7" — what a picked day stores
    }

    /// Seven days starting today, in the device calendar and time zone.
    static func current(now: Date = Date(), calendar: Calendar = .current) -> [Day] {
        let start = calendar.startOfDay(for: now)
        return (0..<7).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            return Day(
                id: offset,
                date: date,
                isToday: calendar.isDateInToday(date),
                displayWeekday: localized(date, template: "EEE"),
                displayNumber: localized(date, template: "d"),
                displayShortDate: localized(date, template: "MMMd"),
                matchWeekday: english(date, format: "EEE"),
                pickerValue: english(date, format: "EEE MMM d")
            )
        }
    }

    /// Localized range for the week header, e.g. "Jul 21 – Jul 27" (order follows the region).
    static func rangeLabel(now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = current(now: now, calendar: calendar)
        guard let first = days.first?.date, let last = days.last?.date else { return "" }
        return "\(localized(first, template: "MMMd")) – \(localized(last, template: "MMMd"))"
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
