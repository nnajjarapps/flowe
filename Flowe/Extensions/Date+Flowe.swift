import Foundation

extension Date {
    var flowTimeString: String {
        let f = DateFormatter()
        // Locale-templated so Hebrew/Arabic get their conventional 24h time instead of a forced
        // English "h:mm a" — DateFormatter already defaults to the device locale.
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f.string(from: self)
    }

    var flowShortDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: self)
    }

    var flowWeekdayShort: String {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f.string(from: self)
    }

    var flowDayNumber: String {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f.string(from: self)
    }

    var flowMonthShort: String {
        let f = DateFormatter()
        f.dateFormat = "MMM"
        return f.string(from: self)
    }

    /// Weekday + full date, e.g. "Saturday, Jul 25" — the event WHEN line. Locale-templated (not a
    /// hardcoded format) so the field order follows the reader's language rather than English.
    var flowLongDate: String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        return f.string(from: self)
    }

    func adding(days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: self) ?? self
    }

    var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }

    var isSameDay: Bool {
        Calendar.current.isDateInToday(self)
    }
}

extension String {
    /// Reformat an English "h:mm a" time-slot string (e.g. "9:00 AM") for the current locale — 24h in
    /// Hebrew/Arabic. Instructor availability hours are stored in the English preset form; this only
    /// touches DISPLAY (the stored/lookup string is unchanged). Falls back to the raw string on a
    /// parse miss so an unrecognised slot still renders.
    var localizedTimeSlot: String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "h:mm a"
        guard let d = parser.date(from: self) else { return self }
        let out = DateFormatter()
        out.setLocalizedDateFormatFromTemplate("jmm")
        return out.string(from: d)
    }
}
