// ============================================================================
// StudentProfile.swift  — paste verbatim into Flowe/Models/StudentProfile.swift
// The @Model counterpart to `Instructor`, minimal and NEVER shown in Discover.
// ============================================================================
import Foundation
import SwiftData

/// A student's minimal PUBLIC profile — the counterpart to `Instructor`'s catalog listing, pared to
/// the fields an instructor needs to recognise who booked them: a display name, a photo, a one-line
/// bio, and when they joined. Stored in the local (non-synced) `Reference` configuration exactly like
/// `Instructor`: SwiftData can't mirror a public database, so this travels over raw CloudKit through
/// `StudentDirectoryService` (recordName == ownerID, so only the creator can edit it), and these rows
/// are its offline cache.
///
/// NEVER queried into Discover. There is no `visibility` field and no broad query: an instructor only
/// ever fetches a SPECIFIC student they already transact with, by ownerID (recordName).
///
/// CloudKit-legal: class, every stored property defaulted, no `@Attribute(.unique)`.
@Model
final class StudentProfile {
    var legacyId: Int = 0
    /// The signed-in student who owns/edits this profile. Doubles as the CloudKit recordName.
    var ownerID: String?
    var name: String = ""
    var bio: String?
    /// When the student joined Flowe — shown as "Member since". Sourced from `User.memberSince`.
    var memberSince: Date = Date.distantPast
    /// Uploaded profile photo, already downscaled by `ProfileImage.prepare`. Published as a `CKAsset`;
    /// external storage keeps the blob out of the SQLite row. Nil means no photo (render placeholder).
    @Attribute(.externalStorage) var photo: Data?
    /// Last time this row was written — used to age the instructor-side cache. Mirrors listing updatedAt.
    var updatedAt: Date = Date.distantPast
    /// Stable display order in the local cache.
    var order: Int = 0
    /// Profile edits that never reached the public store, retried on next launch/sync. Mirrors
    /// `Instructor.pendingPublish` — set BEFORE the network call so a crash mid-publish still retries.
    var pendingPublish: Bool = false

    init(
        legacyId: Int = 0,
        ownerID: String? = nil,
        name: String = "",
        bio: String? = nil,
        memberSince: Date = Date.distantPast,
        photo: Data? = nil,
        updatedAt: Date = Date.distantPast,
        order: Int = 0
    ) {
        self.legacyId = legacyId
        self.ownerID = ownerID
        self.name = name
        self.bio = bio
        self.memberSince = memberSince
        self.photo = photo
        self.updatedAt = updatedAt
        self.order = order
    }

    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
}
