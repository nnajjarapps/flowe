import Foundation

/// Screens user-written text that becomes **publicly visible** before it is published, which is the
/// filtering half of App Store Review Guideline 1.2.
///
/// Scope is deliberate. This runs on instructor listing fields — name, city, bio, certification —
/// because those are broadcast to every student in the catalog. It does **not** run on private
/// messages: the guideline targets content posted to the app, and silently screening one person's
/// private correspondence with another is a different, worse product. Abuse in DMs is handled by
/// blocking and reporting instead.
///
/// This is a coarse first pass, not moderation. It catches slurs and obvious contact-harvesting in
/// a public bio; it will not catch anything adversarial. Real moderation needs review of the
/// reports `ReportService` files.
enum ContentFilter {

    enum Rejection: Equatable {
        case objectionableLanguage
        case contactDetails

        /// Shown directly to the person who typed it, so it explains rather than accuses.
        var message: String {
            switch self {
            case .objectionableLanguage:
                return "This wording can't go on a public profile. Please rephrase it."
            case .contactDetails:
                return "Please keep email addresses and phone numbers out of your public profile — "
                     + "students can reach you through Flowe messages."
            }
        }
    }

    /// Slurs and sexual terms that have no place in a public Pilates listing. Matched on word
    /// boundaries so ordinary words that merely contain them ("Scunthorpe", "class") are unaffected.
    private static let blockedTerms: Set<String> = [
        "fuck", "shit", "cunt", "bitch", "whore", "slut",
        "nigger", "faggot", "retard", "tranny",
        "porn", "escort", "nudes",
    ]

    /// Reject text that shouldn't be published, or nil if it's fine.
    static func reject(_ text: String) -> Rejection? {
        let lowered = text.lowercased()
        if containsBlockedTerm(lowered) { return .objectionableLanguage }
        if containsContactDetails(text) { return .contactDetails }
        return nil
    }

    /// First rejection across several fields — used when saving a whole form at once.
    static func reject(fields: [String]) -> Rejection? {
        fields.lazy.compactMap(reject).first
    }

    private static func containsBlockedTerm(_ lowered: String) -> Bool {
        // Split on anything that isn't a letter so punctuation and digits don't hide a term.
        let words = lowered.split { !$0.isLetter }.map(String.init)
        return words.contains { blockedTerms.contains($0) }
    }

    /// Public listings shouldn't carry direct contact details — it routes students off-platform and
    /// is the usual shape of a scam listing.
    private static func containsContactDetails(_ text: String) -> Bool {
        let patterns = [
            #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,      // email
            #"(\+?\d[\d\s().-]{7,}\d)"#,                     // phone-like run of digits
        ]
        return patterns.contains { pattern in
            text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}
