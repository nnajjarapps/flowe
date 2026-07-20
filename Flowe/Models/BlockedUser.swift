import Foundation
import SwiftData

/// Someone this user has blocked. App Store Review Guideline 1.2 requires that an app hosting
/// user-generated content lets people block abusive users.
///
/// Blocks live in the `UserData` configuration, so they ride the CloudKit **private** database and
/// follow the user across their own devices. They are deliberately *not* published anywhere shared:
/// a block is one person's decision about their own experience, and broadcasting "A blocked B" to a
/// world-readable database would leak exactly the sort of thing a blocker wants kept quiet.
///
/// The practical consequence is that a block hides the other person on *this* user's side rather
/// than stopping them writing. Without a server there is nothing to enforce a write barrier — see
/// `BOOKING-SYSTEM.md`. Their messages still land in the public database; they simply never surface.
@Model
final class BlockedUser {
    /// ownerID of the blocked person.
    var blockedID: String = ""
    /// Their display name at the time of blocking, so the unblock list is readable.
    var blockedName: String = ""
    var createdAt: Date = Date.distantPast

    init(blockedID: String = "", blockedName: String = "", createdAt: Date = Date()) {
        self.blockedID = blockedID
        self.blockedName = blockedName
        self.createdAt = createdAt
    }

    var displayName: String { blockedName.isEmpty ? "Blocked user" : blockedName }
}
