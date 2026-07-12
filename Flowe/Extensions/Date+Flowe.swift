import Foundation

extension Date {
    var flowTimeString: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
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
