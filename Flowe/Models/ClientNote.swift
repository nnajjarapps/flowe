import Foundation
import SwiftData

/// An instructor's PRIVATE clinical/safety note about one of their clients — injuries, pregnancy,
/// medical conditions, emergency contact, goals. A memory aid and liability record.
///
/// Like `BlockedUser`, this lives in the `UserData` configuration, so it rides the CloudKit
/// **private** database and follows the instructor across their OWN devices. It is deliberately
/// NEVER published anywhere shared: this is sensitive health data, and it must never reach the
/// world-readable public database. It is intentionally NOT a field on `Booking` — Booking is also
/// double-written to the public `SessionBooking` record, which would leak. There is NO *Service,
/// NO upload path, NO sync method for this model; MockDataStore is its only accessor.
///
/// Keyed by `studentID`: exactly one note per client, spanning all their bookings. Uniqueness is
/// enforced in code by the upsert (find-first-by-studentID), NOT by a DB constraint (CloudKit-backed
/// SwiftData models cannot use @Attribute(.unique)).
@Model
final class ClientNote {
    /// ownerID of the client this note is about.
    var studentID: String = ""

    var hasInjury: Bool = false
    var injuryNote: String = ""
    var isPregnant: Bool = false
    var pregnancyNote: String = ""
    /// Allergies / medical conditions, freeform.
    var conditions: String = ""
    /// General freeform notes.
    var notes: String = ""
    var emergencyContact: String = ""
    var goals: String = ""
    var updatedAt: Date = Date.distantPast

    init(studentID: String = "",
         hasInjury: Bool = false, injuryNote: String = "",
         isPregnant: Bool = false, pregnancyNote: String = "",
         conditions: String = "", notes: String = "",
         emergencyContact: String = "", goals: String = "",
         updatedAt: Date = Date()) {
        self.studentID = studentID
        self.hasInjury = hasInjury
        self.injuryNote = injuryNote
        self.isPregnant = isPregnant
        self.pregnancyNote = pregnancyNote
        self.conditions = conditions
        self.notes = notes
        self.emergencyContact = emergencyContact
        self.goals = goals
        self.updatedAt = updatedAt
    }

    /// Any SAFETY-CRITICAL flag set — drives the glanceable glyph. Scoped to the medically actionable
    /// trio ONLY (injury / pregnancy / conditions); emergencyContact, goals and freeform notes are
    /// informational and deliberately do NOT trip the badge, so the glyph stays a true safety signal.
    var hasFlags: Bool {
        hasInjury || isPregnant
            || !conditions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Any field populated at all — the safety trio (via `hasFlags`) OR the informational fields.
    /// Drives read-vs-empty state in the profile: an all-blank note reads as "no note yet".
    var hasContent: Bool {
        hasFlags
            || !emergencyContact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !goals.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
