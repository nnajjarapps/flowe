import Foundation

/// Static scheduling + profile constants ported from the Figma mockup.
enum FloweConstants {
    /// Owner id for a session with no Apple credential — previews and UI tests, which never sign in.
    /// Shared so seeded instructor-side data and `AppSession.ownerID` can't drift apart.
    static let localOwnerID = "local-user"

    // The booking day picker and instructor calendar now derive their days from the real current
    // week — see `FloweWeek`. The old fixed "Mon Jul 7 … Sun Jul 13" array is gone.

    /// English weekday abbreviations, in week order. Bookings store and match on these, so they
    /// stay English regardless of display language (see `FloweWeek.matchWeekday`).
    ///
    /// Deliberately not a static on `Instructor`: referencing a static member of a `@Model` type
    /// from a View's stored-property initializer miscompiles, and the diagnostic surfaces in an
    /// unrelated file.
    static let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    static let times = ["8:00 AM", "9:00 AM", "10:00 AM", "11:00 AM", "2:00 PM", "3:30 PM", "5:00 PM", "6:00 PM"]

    static let discoverCategories = ["All", "Mat", "Reformer", "Barre", "Tower", "Prenatal", "Rehab"]

}

/// How the distance between a student and an instructor is written.
///
/// **Kilometres, everywhere.** Flowe has no existing distance convention, prices are in ILS and the
/// first market is metric, so a single unit beats a locale-derived one that would flip English users
/// in Tel Aviv to miles. The numeral itself is formatted with a fixed Western locale for exactly the
/// reason `AppSettings.money` does it: an Arabic UI should still read "~2.4 km", not switch digit
/// systems mid-row.
///
/// Every figure is prefixed "~" and nothing below a kilometre is quantified, because the underlying
/// coordinate is snapped to a ~1 km grid (see `CoarseLocation`). Printing "0.3 km" from a value with
/// ±0.8 km of designed-in error would be a lie about how well we know where an instructor is.
enum FloweDistance {
    private static let numberLocale = Locale(identifier: "en_US")

    static func label(metres: Double) -> LocalizedStringResource {
        guard metres.isFinite, metres >= 1000 else { return "Under 1 km" }
        let km = metres / 1000
        // One decimal while it still means something, whole kilometres past ten.
        let digits = km < 10 ? 1 : 0
        let value = km.formatted(
            .number.precision(.fractionLength(digits)).rounded(rule: .toNearestOrEven).locale(numberLocale)
        )
        return "~\(value) km"
    }
}

/// How an instructor accepts money. Flowe collects nothing for sessions in this release — the
/// student settles up with the instructor directly — so this is the only signal a student has about
/// how they will actually pay.
///
/// The raw ids are stable storage/wire values (SwiftData `[String]` + a public-database `CKRecord`
/// field), never shown to anyone; only `label` is user-facing and localized. Deliberately not a
/// static on `Instructor`: referencing a static member of a `@Model` type from a View's
/// stored-property initializer miscompiles, and the diagnostic surfaces in an unrelated file.
enum PaymentMethod {
    static let cash = "cash"
    /// The Israeli peer-to-peer transfer app (Bank Hapoalim); near-universal locally and the
    /// realistic alternative to cash for an ILS-priced session.
    static let bit = "bit"

    /// Canonical order — what the editor offers and the order listings are rendered in.
    static let all = [cash, bit]

    /// Display name. `LocalizedStringResource` rather than `LocalizedStringKey` so this stays a
    /// Foundation type usable from the data layer, while still localizing in `Text`.
    static func label(_ id: String) -> LocalizedStringResource {
        switch id {
        case cash: return "Cash"
        case bit: return "Bit"
        default: return "Other"
        }
    }

    /// Only the ids we know how to render, in canonical order — a listing published by a future
    /// build with an unknown method must not put a mystery chip in front of a student.
    static func known(_ ids: [String]) -> [String] { all.filter(ids.contains) }
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
