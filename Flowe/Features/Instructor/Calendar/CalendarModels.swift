import SwiftUI

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
