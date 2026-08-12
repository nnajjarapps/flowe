import Foundation
import SwiftData

/// An instructor's PRIVATE clinical/safety note about one of their clients — injuries, pregnancy,
/// medical conditions, emergency contact, goals. A memory aid and liability record.
///
/// Like `BlockedUser`, this lives in the `UserData` configuration, so it rides the CloudKit **private**
/// database and follows the instructor across their OWN devices. It is deliberately NEVER published
/// anywhere shared, and — because it is health-adjacent data — its sensitive fields are **encrypted at
/// rest** (App Store Guideline 5.1.3, which forbids storing health data in iCloud in readable form):
/// the CloudKit private mirror holds only the `sealed` ciphertext + `studentID`/`updatedAt` metadata and
/// an opaque `flagged` glyph hint. The decryption key is a per-instructor symmetric key in their iCloud
/// Keychain (see `NoteCrypto`), so iCloud never holds readable health information. Decrypted only on the
/// instructor's device, into `ClientNoteData`.
///
/// Keyed by `studentID`: exactly one note per client, spanning all their bookings. Uniqueness is enforced
/// in code by the upsert (find-first-by-studentID), NOT by a DB constraint (CloudKit-backed SwiftData
/// models cannot use @Attribute(.unique)). Accessed only via `MockDataStore.clientNote(forStudentID:)`
/// / `saveClientNote(...)` / `clientNoteHasFlags(forStudentID:)`, which own the crypto boundary.
@Model
final class ClientNote {
    /// ownerID of the client this note is about (metadata, not health data).
    var studentID: String = ""
    var updatedAt: Date = Date.distantPast
    /// Opaque safety-flag hint for the glanceable glyph — TRUE if any safety-critical field is set. Not
    /// health data itself (it doesn't say WHICH), so it stays unencrypted for a cheap glyph check that
    /// never has to decrypt.
    var flagged: Bool = false
    /// ALL health-sensitive fields, ChaChaPoly-encrypted (base64). Empty when the note is blank.
    var sealed: String = ""

    init(studentID: String = "", updatedAt: Date = Date.distantPast, flagged: Bool = false, sealed: String = "") {
        self.studentID = studentID
        self.updatedAt = updatedAt
        self.flagged = flagged
        self.sealed = sealed
    }
}

/// Plaintext, in-memory view of a `ClientNote` — what the editor writes and the reader/glyph consume.
/// Never persisted directly; the sensitive subset is encrypted into `ClientNote.sealed`.
struct ClientNoteData {
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

    /// Any SAFETY-CRITICAL flag set — drives the glanceable glyph. Scoped to the medically actionable trio
    /// ONLY (injury / pregnancy / conditions); emergencyContact, goals and freeform notes are informational
    /// and deliberately do NOT trip the badge, so the glyph stays a true safety signal.
    var hasFlags: Bool {
        hasInjury || isPregnant
            || !conditions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Any field populated at all — the safety trio (via `hasFlags`) OR the informational fields.
    var hasContent: Bool {
        hasFlags
            || !emergencyContact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !goals.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The health-sensitive subset that gets encrypted into `ClientNote.sealed` (everything except the
    /// `studentID`/`updatedAt` metadata, which stay as plain @Model columns).
    struct Sealed: Codable {
        var hasInjury = false
        var injuryNote = ""
        var isPregnant = false
        var pregnancyNote = ""
        var conditions = ""
        var notes = ""
        var emergencyContact = ""
        var goals = ""
    }

    var sealedPayload: Sealed {
        Sealed(hasInjury: hasInjury, injuryNote: injuryNote, isPregnant: isPregnant,
               pregnancyNote: pregnancyNote, conditions: conditions, notes: notes,
               emergencyContact: emergencyContact, goals: goals)
    }

    init(studentID: String = "", updatedAt: Date = Date.distantPast, sealed s: Sealed = Sealed()) {
        self.studentID = studentID
        self.updatedAt = updatedAt
        self.hasInjury = s.hasInjury
        self.injuryNote = s.injuryNote
        self.isPregnant = s.isPregnant
        self.pregnancyNote = s.pregnancyNote
        self.conditions = s.conditions
        self.notes = s.notes
        self.emergencyContact = s.emergencyContact
        self.goals = s.goals
    }
}
