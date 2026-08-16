import Foundation
import SwiftData

/// An instructor-authored **training program** — an ordered collection of `VideoExercise`s
/// ("Beginner Reformer", "Post-natal Flow"). The student-facing half of Flowe Education.
///
/// Same shape and lifecycle as `LessonType`: the body lives in the shared **public** CloudKit database
/// (see `ProgramService`, `_world` read / `_creator` write) and this `@Model` is the author's offline
/// cache in the **UserData** configuration (SwiftData mirrors UserData to the *private* CloudKit DB, so a
/// program one instructor authors reaches students only via the raw public record, which this row caches).
/// The recordName is deterministic (`program-<localID>`) so a re-publish upserts the *same* record.
///
/// The library is **open** (v1): any student viewing the instructor can browse and play. There is no
/// per-student access grant — see [[FloweEducation]] for that decision and its trade-offs.
@Model
final class Program {
    // MARK: Identity
    var localID: UUID = UUID()
    /// The delivered recordName; equals "program-<localID>" once the server confirms. Nil for the whole
    /// publish round-trip, so it must never be read as "never published".
    var remoteID: String? = nil
    var createdAt: Date = Date.distantPast
    /// Last-writer-wins stamp for the edit-conflict retry in `ProgramService.upsert`.
    var updatedAt: Date = Date.distantPast

    // MARK: Owner (query key)
    /// The authoring instructor's AppSession owner id (Apple credential id, same identity as
    /// `LessonType.ownerID` / `CommunityEvent.organizerID`). A student fetches one instructor's programs
    /// by this field; the single field a row cannot be attributed without.
    var ownerID: String? = nil

    // MARK: Content (instructor-written; travels on the record)
    /// Free-form user text ("Beginner Reformer"). Rendered verbatim, never localized.
    var title: String = ""
    /// Optional public blurb shown on the program header. "" = omitted.
    var summary: String = ""
    /// Explicit instructor-controlled display order, published so students see the same order.
    var order: Int = 0

    // MARK: Cover photo (small — staged as a CKAsset exactly like `LessonType.highlight`)
    @Attribute(.externalStorage) var cover: Data?
    /// Whether the shared record carries a cover, known without downloading it — set from whether the
    /// asset actually staged, never from `cover != nil`.
    var hasCover: Bool = false

    // MARK: Delivery state (set BEFORE the network call, cleared only on confirmed delivery)
    var pendingUpload: Bool = false
    var pendingDelete: Bool = false

    init(
        localID: UUID = UUID(),
        remoteID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date.distantPast,
        ownerID: String? = nil,
        title: String = "",
        summary: String = "",
        order: Int = 0,
        cover: Data? = nil,
        hasCover: Bool = false,
        pendingUpload: Bool = false,
        pendingDelete: Bool = false
    ) {
        self.localID = localID
        self.remoteID = remoteID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.ownerID = ownerID
        self.title = title
        self.summary = summary
        self.order = order
        self.cover = cover
        self.hasCover = hasCover
        self.pendingUpload = pendingUpload
        self.pendingDelete = pendingDelete
    }
}
