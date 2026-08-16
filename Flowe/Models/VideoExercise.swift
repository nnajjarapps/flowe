import Foundation
import SwiftData

/// One instructor-authored **video exercise** inside a `Program` — a short clip plus coaching notes and a
/// prescription (sets / reps / tempo). The atom of Flowe Education.
///
/// Same lifecycle as `LessonType` / `Program`: authored into the **public** CloudKit database (see
/// `ExerciseService`, `_world` read / `_creator` write, deterministic recordName `exercise-<localID>`),
/// cached here as the author's `@Model` in the **UserData** configuration.
///
/// ## Two assets, fetched separately
///
/// `thumbnail` is small and staged as a CKAsset exactly like `LessonType.highlight`. `video` is the same
/// mechanism (staged to a temp file → CKAsset) but large: it is NEVER pulled on the list/metadata query
/// (that would download every clip on every refresh) — a student fetches the video asset on demand for
/// playback, and only the *authoring* instructor's device holds the bytes in its private mirror (their own
/// content). At pilot scale this is fine; a large library would move video off CloudKit (see [[FloweEducation]]).
@Model
final class VideoExercise {
    // MARK: Identity
    var localID: UUID = UUID()
    /// The delivered recordName; equals "exercise-<localID>" once confirmed. Nil across the round-trip.
    var remoteID: String? = nil
    var createdAt: Date = Date.distantPast
    /// Last-writer-wins stamp for the edit-conflict retry in `ExerciseService.upsert`.
    var updatedAt: Date = Date.distantPast

    // MARK: Owner (query key)
    /// The authoring instructor's AppSession owner id — a student fetches an instructor's exercises by this.
    var ownerID: String? = nil
    /// The parent `Program.localID` as a string ("" = loose / not yet assigned). Published so a reader can
    /// group an instructor's exercises under their programs.
    var programID: String = ""

    // MARK: Content (instructor-written; travels on the record)
    /// Free-form user text ("Reformer Foundations"). Rendered verbatim, never localized.
    var title: String = ""
    /// Coaching cues shown alongside the video ("light spring, lead from the breath…"). "" = omitted.
    var coachingNotes: String = ""
    /// Free-form prescription — sets / reps / tempo ("3x10 @ 3-1-3"). "" = omitted.
    var prescription: String = ""
    /// Comma-joined focus tags ("core,mobility"). Split for the chips at the display layer.
    var focus: String = ""
    /// Difficulty ("beginner" / "intermediate" / "advanced"). "" = not stated.
    var level: String = ""
    /// Order within the parent program.
    var order: Int = 0
    /// Video length in seconds, published so a card can show the duration without fetching the clip. 0 =
    /// not yet known (upload not finished).
    var durationSeconds: Int = 0

    // MARK: Assets
    /// Poster frame, small — staged + fetched exactly like `LessonType.highlight`. Shown on the card and
    /// as the player's placeholder. Compress to well under 1MB (this @Model mirrors to the private DB,
    /// where a non-asset BYTES field is capped at 1MB).
    @Attribute(.externalStorage) var thumbnail: Data?
    var hasThumbnail: Bool = false
    /// Whether the shared record carries a playable video (set from whether the video asset staged). The
    /// clip BYTES are DELIBERATELY not persisted here: a CKAsset can be large, but this @Model mirrors to
    /// the private CloudKit DB where a non-asset field is capped at 1MB — so the video lives ONLY as a
    /// CKAsset on the PUBLIC record. The author passes the picked clip transiently to `ExerciseService`;
    /// students fetch it on demand (`fetchVideoURL`).
    var hasVideo: Bool = false

    // MARK: Delivery state
    var pendingUpload: Bool = false
    var pendingDelete: Bool = false

    init(
        localID: UUID = UUID(),
        remoteID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date.distantPast,
        ownerID: String? = nil,
        programID: String = "",
        title: String = "",
        coachingNotes: String = "",
        prescription: String = "",
        focus: String = "",
        level: String = "",
        order: Int = 0,
        durationSeconds: Int = 0,
        thumbnail: Data? = nil,
        hasThumbnail: Bool = false,
        hasVideo: Bool = false,
        pendingUpload: Bool = false,
        pendingDelete: Bool = false
    ) {
        self.localID = localID
        self.remoteID = remoteID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.ownerID = ownerID
        self.programID = programID
        self.title = title
        self.coachingNotes = coachingNotes
        self.prescription = prescription
        self.focus = focus
        self.level = level
        self.order = order
        self.durationSeconds = durationSeconds
        self.thumbnail = thumbnail
        self.hasThumbnail = hasThumbnail
        self.hasVideo = hasVideo
        self.pendingUpload = pendingUpload
        self.pendingDelete = pendingDelete
    }
}
