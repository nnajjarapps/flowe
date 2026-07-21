import Foundation
import SwiftData

/// A reply on a community post, cached locally from the shared store (see `CommunityService`).
///
/// Comments are append-only and each is written by its author, so — like messages and posts — the
/// public database's default `_creator`-write role already fits: an author can delete their own
/// reply and nobody else's.
@Model
final class PostComment {
    /// recordName in the public database. Nil while the comment is still queued for upload.
    var remoteID: String?
    /// Remote id of the post being replied to.
    var postID: String = ""
    /// ownerID of whoever wrote it — what the block list is checked against.
    var authorID: String = ""
    /// Denormalised so the row renders without a second lookup.
    var authorName: String = ""
    var text: String = ""
    var createdAt: Date = Date.distantPast
    /// Hasn't reached the shared store yet; retried on the next sync.
    var pendingUpload: Bool = false
    /// A deletion the server has not confirmed. Needed because `remoteID` is nil for the whole
    /// publish round-trip, so "no id" cannot be read as "never published".
    var pendingDelete: Bool = false

    init(
        remoteID: String? = nil,
        postID: String = "",
        authorID: String = "",
        authorName: String = "",
        text: String = "",
        createdAt: Date = Date(),
        pendingUpload: Bool = false,
        pendingDelete: Bool = false
    ) {
        self.remoteID = remoteID
        self.postID = postID
        self.authorID = authorID
        self.authorName = authorName
        self.text = text
        self.createdAt = createdAt
        self.pendingUpload = pendingUpload
        self.pendingDelete = pendingDelete
    }

    /// `LocalizedStringResource` so the "Someone" fallback translates — see `FeedPost`.
    var displayName: LocalizedStringResource {
        authorName.isEmpty ? "Someone" : "\(authorName)"
    }

    var relativeTime: LocalizedStringResource { FeedPost.relativeTime(since: createdAt) }
}
