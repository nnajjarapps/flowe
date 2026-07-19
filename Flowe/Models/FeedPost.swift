import Foundation
import SwiftData

enum PostType: String, Codable {
    case review
    case tip
    case checkin
}

/// Community feed post. Stored in the user `UserData` configuration (synced in Phase B).
/// `liked`/`saved` are per-user booleans — correct for a single iCloud identity's private store.
@Model
final class FeedPost {
    var legacyId: Int = 0
    var type: PostType = PostType.tip
    var user: String = ""
    var userImg: String = ""        // Unsplash photo id
    var instructor: String?
    var instImg: String?             // Unsplash photo id
    var time: String = ""
    var rating: Int?
    var text: String = ""
    var likes: Int = 0
    var comments: Int = 0
    var saved: Bool = false
    var liked: Bool = false
    var ownerID: String?             // Apple user id of the owner (Phase C)
    var order: Int = 0

    init(
        legacyId: Int = 0,
        type: PostType = .tip,
        user: String = "",
        userImg: String = "",
        instructor: String? = nil,
        instImg: String? = nil,
        time: String = "",
        rating: Int? = nil,
        text: String = "",
        likes: Int = 0,
        comments: Int = 0,
        saved: Bool = false,
        liked: Bool = false,
        ownerID: String? = nil,
        order: Int = 0
    ) {
        self.legacyId = legacyId
        self.type = type
        self.user = user
        self.userImg = userImg
        self.instructor = instructor
        self.instImg = instImg
        self.time = time
        self.rating = rating
        self.text = text
        self.likes = likes
        self.comments = comments
        self.saved = saved
        self.liked = liked
        self.ownerID = ownerID
        self.order = order
    }
}
