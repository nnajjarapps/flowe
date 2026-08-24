import Foundation
import SwiftData

enum PostType: String, Codable, CaseIterable, Identifiable {
    case review
    case tip
    case checkin
    /// Auto-generated practice milestone (Flowe Community slice 5) — never user-composed; created by
    /// `MockDataStore.checkMilestones` when a community-opted-in student crosses a session threshold.
    case milestone

    var id: String { rawValue }

    /// Composer label. `LocalizedStringResource` rather than `LocalizedStringKey` so the enum stays
    /// a Foundation type usable from the data layer, while still localizing inside `Text`.
    var composerLabel: LocalizedStringResource {
        switch self {
        case .review:    return "Shout-out"
        case .tip:       return "Tip"
        case .checkin:   return "Check-in"
        case .milestone: return "Milestone"
        }
    }

    /// Whether the post is about a specific instructor — a shout-out or a check-in names one; a tip and
    /// a milestone stand on their own.
    var needsInstructor: Bool { self == .review || self == .checkin }
}

/// A community feed post — the local cache of a post that lives in the shared public database
/// (see `CommunityService`), cached so the feed still renders offline.
///
/// It used to live only in the `UserData` configuration, which SwiftData mirrors to the CloudKit
/// **private** database. That is per-iCloud-account, so a post one user wrote could never be seen
/// by another: the feed was structurally incapable of being a community. Bodies now travel through
/// the public database and this model is the cache, the same shape `Message` and `Review` take.
///
/// `saved` stays deliberately local — a bookmark is one reader's private shelf, and publishing it
/// would tell everyone what you kept. `liked`/`likes` are *not* local: see `CommunityService` for
/// why a like is its own public record rather than a counter on the post.
@Model
final class FeedPost {
    var legacyId: Int = 0
    /// Stored as a raw String, not a Codable enum, so it mirrors to CloudKit as a plain STRING rather
    /// than opaque BYTES — an unknown or renamed `PostType` case then degrades to `.tip` instead of
    /// failing to decode the whole post row.
    var typeRaw: String = PostType.tip.rawValue
    var type: PostType {
        get { PostType(rawValue: typeRaw) ?? .tip }
        set { typeRaw = newValue.rawValue }
    }
    var user: String = ""
    var instructor: String?
    var text: String = ""
    /// The attached photo, already downscaled by `ProfileImage.preparePost`. Published as a
    /// `CKAsset`; external storage keeps the blob out of the SQLite row.
    ///
    /// Nil means one of two different things, which is why `hasImage` exists alongside it: this post
    /// genuinely has no photo, or it has one this device hasn't downloaded yet.
    @Attribute(.externalStorage) var image: Data?
    /// Whether the shared record carries a photo, known without downloading it. The feed query
    /// deliberately fetches every field *except* the asset (see `CommunityService`), so this is what
    /// tells a row to reserve space and what tells the image pass which posts to go and get.
    var hasImage: Bool = false
    var likes: Int = 0
    var comments: Int = 0
    var saved: Bool = false
    var liked: Bool = false
    var ownerID: String?             // Apple user id of the author
    var order: Int = 0

    // MARK: Shared-post identity
    /// recordName in the public database. Nil for a seeded post, or one that hasn't published yet.
    var remoteID: String?
    /// When the post was written — what the feed is ordered by.
    var createdAt: Date = Date.distantPast

    // MARK: Delivery state
    /// Hasn't reached the shared store yet; retried on the next sync so an undelivered post isn't
    /// silently lost.
    var pendingUpload: Bool = false
    /// The author deleted it locally but the server hasn't confirmed. Hidden from the feed
    /// meanwhile — a post that looks deleted while staying world-readable is the failure that matters.
    var pendingDelete: Bool = false
    /// A like/unlike that hasn't been pushed yet.
    var pendingLike: Bool = false

    init(
        legacyId: Int = 0,
        type: PostType = .tip,
        user: String = "",
        instructor: String? = nil,
        text: String = "",
        image: Data? = nil,
        hasImage: Bool = false,
        likes: Int = 0,
        comments: Int = 0,
        saved: Bool = false,
        liked: Bool = false,
        ownerID: String? = nil,
        order: Int = 0,
        remoteID: String? = nil,
        createdAt: Date = Date(),
        pendingUpload: Bool = false
    ) {
        self.legacyId = legacyId
        self.typeRaw = type.rawValue
        self.user = user
        self.instructor = instructor
        self.text = text
        self.image = image
        self.hasImage = hasImage
        self.likes = likes
        self.comments = comments
        self.saved = saved
        self.liked = liked
        self.ownerID = ownerID
        self.order = order
        self.remoteID = remoteID
        self.createdAt = createdAt
        self.pendingUpload = pendingUpload
    }

    /// `LocalizedStringResource`, not `String`: this is app copy shown via `Text`, and a plain
    /// String would render untranslated in every language.
    var displayName: LocalizedStringResource {
        user.isEmpty ? "Someone" : "\(user)"
    }

    /// The raw author name, for places that need a string rather than displayable copy.
    var authorNameOrEmpty: String { user }

    /// "2H AGO", derived from when the post was actually written.
    var relativeTime: LocalizedStringResource {
        FeedPost.relativeTime(since: createdAt)
    }
    

    /// Shared with `PostComment`, which shows the same stamp under a reply.
    ///
    /// Localized rather than interpolated into English: these stamps sit under every post and
    /// reply, and Latin uppercase embedded in an Arabic line also breaks the bidi run.
    static func relativeTime(since date: Date) -> LocalizedStringResource {
        let seconds = Date().timeIntervalSince(date)
        switch seconds {
        case ..<60:      return "JUST NOW"
        case ..<3600:    return "\(Int(seconds / 60))M AGO"
        case ..<86_400:  return "\(Int(seconds / 3600))H AGO"
        case ..<604_800: return "\(Int(seconds / 86_400))D AGO"
        default:
            // Template, not a fixed "d MMM": day-before-month is wrong for several locales.
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("dMMM")
            return "\(formatter.string(from: date).uppercased(with: .current))"
        }
    }
}
