import Foundation
import CloudKit

/// A community post as it exists in the shared store (plain DTO decoded from a CKRecord).
struct RemotePost {
    let id: String
    let authorID: String
    let authorName: String
    let type: String
    let instructorName: String
    let text: String
    let createdAt: Date
    /// Whether the record carries a photo. Known from the feed query, which does *not* download the
    /// asset itself — see `CommunityService.postMetadataKeys`.
    let hasImage: Bool

    init?(record: CKRecord) {
        // `text` is no longer required: a photo with no caption is a whole post.
        guard let authorID = record["authorID"] as? String else { return nil }
        id = record.recordID.recordName
        self.authorID = authorID
        text = record["text"] as? String ?? ""
        authorName = record["authorName"] as? String ?? ""
        type = record["type"] as? String ?? PostType.tip.rawValue
        instructorName = record["instructorName"] as? String ?? ""
        createdAt = record["createdAt"] as? Date ?? .distantPast
        hasImage = (record["hasImage"] as? Int ?? 0) == 1
    }
}

/// One reader's like of one post. There is no count field anywhere — the count *is* how many of
/// these exist (see the note on `CommunityService`).
struct RemoteLike {
    let postID: String
    let authorID: String
    /// When the like landed. Already stored on the record and QUERYABLE/SORTABLE in the schema — it
    /// just was not decoded until the Activity feed needed something to sort a "liked your post" row
    /// by. Falls back to `.distantPast` so a pre-existing like without one sorts oldest rather than
    /// dropping the row entirely.
    let createdAt: Date

    init?(record: CKRecord) {
        guard let postID = record["postID"] as? String,
              let authorID = record["authorID"] as? String else { return nil }
        self.postID = postID
        self.authorID = authorID
        self.createdAt = record["createdAt"] as? Date ?? .distantPast
    }
}

/// A reply on a post.
struct RemoteComment {
    let id: String
    let postID: String
    let authorID: String
    let authorName: String
    let text: String
    let createdAt: Date

    init?(record: CKRecord) {
        guard let postID = record["postID"] as? String,
              let authorID = record["authorID"] as? String,
              let text = record["text"] as? String else { return nil }
        id = record.recordID.recordName
        self.postID = postID
        self.authorID = authorID
        self.text = text
        authorName = record["authorName"] as? String ?? ""
        createdAt = record["createdAt"] as? Date ?? .distantPast
    }
}

/// One follow edge in the student practice-friends graph (Flowe Community slice 6). Directed:
/// `followerID` follows `followeeID`. `followeeName` denormalised so a friends list renders without a
/// second lookup. World-readable like the rest of the community.
struct RemoteFollow {
    let id: String
    let followerID: String
    let followeeID: String
    let followeeName: String
    let createdAt: Date

    init(id: String, followerID: String, followeeID: String, followeeName: String, createdAt: Date) {
        self.id = id; self.followerID = followerID; self.followeeID = followeeID
        self.followeeName = followeeName; self.createdAt = createdAt
    }

    init?(record: CKRecord) {
        guard let followerID = record["followerID"] as? String,
              let followeeID = record["followeeID"] as? String else { return nil }
        self.init(id: record.recordID.recordName, followerID: followerID, followeeID: followeeID,
                  followeeName: record["followeeName"] as? String ?? "",
                  createdAt: record["createdAt"] as? Date ?? .distantPast)
    }
}

/// The community feed over CloudKit's **public** database, for the same reason bookings, messages
/// and reviews live there: SwiftData can only mirror the *private* database, which is
/// per-iCloud-account, so a post one user writes could never reach another. A feed in the private
/// database is not a community — it is a diary.
///
/// Posts are append-only and each is written by its author, so the default `_creator`-write role
/// fits and no two-record split like `BookingService` needs is required. The author can delete
/// their own post because they are its creator.
///
/// ## Why a like is a record and not a counter
///
/// A public-database record is writable only by whoever created it. A `likes` integer on the post
/// could therefore only ever be incremented by the post's *author* — every other reader's tap would
/// be rejected by CloudKit, and a client that "optimistically" bumped a local copy would be showing
/// a number nobody else could see. So a like is its own record, `like-<postID>-<readerID>`, created
/// by the reader who taps and deleted when they untap. Every write stays inside the writer's own
/// row, and the count is simply how many like records a post has.
///
/// The tradeoffs are real and deliberate: one extra query per feed refresh, a count that is
/// eventually consistent rather than instant, and a count that is only as complete as that query —
/// which is why the fetch follows its cursor instead of trusting a single page. A stale-by-a-refresh
/// number that is genuinely the number of people who liked the post beats an invented one.
@MainActor
final class CommunityService {
    static let postRecordType = "CommunityPost"
    static let likeRecordType = "CommunityLike"
    static let commentRecordType = "CommunityComment"

    /// The field a comment names the person to alert by — the post's author, and empty when that is
    /// the commenter themselves (see `replyTarget`). Shared with `PushService`.
    static let replyTargetField = "replyTargetID"

    /// The field a LIKE names the person to alert by — the post's author, and empty when that is the
    /// liker themselves. Exact mirror of `replyTargetField`; see `likeTarget`. Shared with `PushService`.
    static let likeTargetField = "likeTargetID"

    /// How much feed is worth carrying on a phone. Also bounds the `IN` lists the engagement
    /// queries build, which CloudKit will reject if they grow without limit.
    private static let feedLimit = 100
    private static let pageSize = 400
    /// CloudKit dislikes very large `IN` arrays, so engagement is fetched in slices.
    private static let idsPerQuery = 50

    /// Everything on a post *except* the photo.
    ///
    /// The feed query asks for exactly these. Passing `desiredKeys: nil` would download every
    /// attached `CKAsset` too — up to `feedLimit` photos, a couple of hundred kilobytes each, on
    /// every pull-to-refresh, most of them for rows the reader will never scroll to. Photos come
    /// afterwards from `fetchImages`, once, per post, and are cached from then on.
    private static let postMetadataKeys = [
        "authorID", "authorName", "type", "instructorName", "text", "createdAt", "hasImage",
    ]

    /// How many photos one sync will pull. The feed carries 100 posts; fetching every attached
    /// photo at once is the exact cost the split above exists to avoid, so a pass takes the newest
    /// slice and the next sync takes the next.
    private static let imagesPerSync = 24

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    // MARK: - Posts

    /// Publish a post. Returns the remote id, or nil if it didn't reach the server.
    func publish(authorID: String,
                 authorName: String,
                 type: String,
                 instructorName: String,
                 text: String,
                 image: Data?,
                 createdAt: Date) async -> String? {
        #if CLOUDKIT_ENABLED
        let record = CKRecord(recordType: Self.postRecordType)
        record["authorID"] = authorID
        record["authorName"] = authorName
        record["type"] = type
        record["instructorName"] = instructorName
        record["text"] = text
        record["createdAt"] = createdAt

        // A CKAsset uploads from a file, so the photo has to be staged on disk for the save and
        // cleaned up afterwards — the same dance `CatalogService` does for listing photos.
        let staged = image.flatMap { Self.stageAsset($0) }
        record["image"] = staged.map { CKAsset(fileURL: $0) }
        // Set from what actually got staged, not from `image != nil`: a photo that failed to stage
        // is a post without one, and claiming otherwise would leave every reader's row holding
        // space for an asset that will never arrive.
        record["hasImage"] = staged == nil ? 0 : 1
        defer { staged.map { try? FileManager.default.removeItem(at: $0) } }

        do {
            let saved = try await database.save(record)
            return saved.recordID.recordName
        } catch {
            return nil   // offline / not signed into iCloud / schema not deployed
        }
        #else
        return nil
        #endif
    }

    /// Publish an AUTO milestone post under a DETERMINISTIC recordName (`milestone-<studentID>-<N>`) so a
    /// milestone is celebrated exactly once — re-detecting the same threshold on any device / after a
    /// reinstall upserts rather than duplicating. No image, no instructor. See [[Flowe-Community]].
    @discardableResult
    func publishMilestone(recordName: String, authorID: String, authorName: String,
                          text: String, createdAt: Date) async -> String? {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: recordName)
        let record = (try? await database.record(for: id)) ?? CKRecord(recordType: Self.postRecordType, recordID: id)
        record["authorID"] = authorID
        record["authorName"] = authorName
        record["type"] = "milestone"
        record["instructorName"] = ""
        record["text"] = text
        record["hasImage"] = 0
        if record["createdAt"] == nil { record["createdAt"] = createdAt }
        do {
            let saved = try await database.save(record)
            return saved.recordID.recordName
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    // MARK: - Practice-friends graph (Flowe Community slice 6)

    static let followRecordType = "StudentFollow"
    static func followRecordName(follower: String, followee: String) -> String { "follow-\(follower)-\(followee)" }

    /// Follow a practice-friend — one edge per (follower, followee), upserted so following twice is a
    /// no-op. `_creator`-write fits (you own your own follows). Returns whether it reached the server.
    @discardableResult
    func follow(followerID: String, followeeID: String, followeeName: String) async -> String? {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: Self.followRecordName(follower: followerID, followee: followeeID))
        let record = (try? await database.record(for: id)) ?? CKRecord(recordType: Self.followRecordType, recordID: id)
        record["followerID"] = followerID
        record["followeeID"] = followeeID
        record["followeeName"] = followeeName
        if record["createdAt"] == nil { record["createdAt"] = Date() }
        do { let saved = try await database.save(record); return saved.recordID.recordName }
        catch { return nil }
        #else
        return nil
        #endif
    }

    func unfollow(followerID: String, followeeID: String) async {
        #if CLOUDKIT_ENABLED
        _ = try? await database.deleteRecord(withID: CKRecord.ID(recordName: Self.followRecordName(follower: followerID, followee: followeeID)))
        #endif
    }

    /// The edges the signed-in student authored — who they follow. Nil on query failure; empty when none.
    /// Follows the query cursor so a student who follows more than one page of peers gets their WHOLE list,
    /// not a silently-truncated first page (mirrors `fetchComments`).
    func fetchFollows(followerID: String) async -> [RemoteFollow]? {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.followRecordType, predicate: NSPredicate(format: "followerID == %@", followerID))
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        do {
            var records: [CKRecord] = []
            var page = try await database.records(matching: query, resultsLimit: Self.pageSize)
            records += page.matchResults.compactMap { try? $0.1.get() }
            while let cursor = page.queryCursor {
                page = try await database.records(continuingMatchFrom: cursor, resultsLimit: Self.pageSize)
                records += page.matchResults.compactMap { try? $0.1.get() }
            }
            return records.compactMap(RemoteFollow.init)
        } catch { return nil }
        #else
        return nil
        #endif
    }

    /// Download the photos for specific posts, newest-first and capped at `imagesPerSync`.
    ///
    /// Keyed by record name; a post whose fetch failed is simply absent, so the caller keeps
    /// whatever it already had rather than caching an empty image over a good one.
    func fetchImages(postIDs: [String]) async -> [String: Data] {
        #if CLOUDKIT_ENABLED
        let wanted = Array(postIDs.prefix(Self.imagesPerSync))
        guard !wanted.isEmpty else { return [:] }
        let ids = wanted.map { CKRecord.ID(recordName: $0) }
        guard let results = try? await database.records(for: ids, desiredKeys: ["image"]) else {
            return [:]
        }
        var images: [String: Data] = [:]
        for (id, result) in results {
            guard let record = try? result.get(),
                  let url = (record["image"] as? CKAsset)?.fileURL,
                  // Read now: CloudKit reclaims the staged copy once this scope ends.
                  let data = try? Data(contentsOf: url) else { continue }
            images[id.recordName] = data
        }
        return images
        #else
        return [:]
        #endif
    }

    /// Delete a post. Only its author can do this — the public database enforces it, so there is no
    /// client-side check to bypass. Returns whether the post is now gone from the server.
    func deletePost(id: String) async -> Bool {
        #if CLOUDKIT_ENABLED
        return await delete(CKRecord.ID(recordName: id))
        #else
        return false
        #endif
    }

    /// The most recent posts, newest first. There is no per-user feed to assemble: the community
    /// tab is the whole community.
    /// Nil when the query failed (offline / schema not deployed) — distinct from an empty array, which
    /// means "genuinely no posts yet".
    func fetchRecentPosts() async -> [RemotePost]? {
        #if CLOUDKIT_ENABLED
        // Query on the queryable `createdAt` field rather than `NSPredicate(value: true)`. A fetch-all
        // TRUEPREDICATE query makes CloudKit fall back to the `recordName` system index, which is NOT
        // marked queryable on `CommunityPost` — so it fails server-side with CKError 2015 "Field
        // 'recordName' is not marked queryable" and the whole feed shows "Couldn't load". Filtering on
        // `createdAt` (QUERYABLE+SORTABLE) uses that index instead and still returns every post (all have
        // a createdAt after the epoch). No CloudKit schema change needed.
        let query = CKQuery(
            recordType: Self.postRecordType,
            predicate: NSPredicate(format: "createdAt > %@", Date(timeIntervalSince1970: 0) as NSDate)
        )
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        do {
            let (matches, _) = try await database.records(
                matching: query, desiredKeys: Self.postMetadataKeys, resultsLimit: Self.feedLimit
            )
            return matches.compactMap { try? $0.1.get() }.compactMap(RemotePost.init)
        } catch {
            return nil   // query failed — NOT "no posts"
        }
        #else
        return nil
        #endif
    }

    // MARK: - Likes

    /// Deterministic record name, so liking twice updates one row instead of inflating the count,
    /// and so the reader stays the creator of the record they later delete.
    static func likeRecordName(postID: String, authorID: String) -> String {
        "like-\(postID)-\(authorID)"
    }

    /// Add or remove this reader's like. Returns whether the change reached the server.
    @discardableResult
    func setLike(_ liked: Bool, postID: String, authorID: String) async -> Bool {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: Self.likeRecordName(postID: postID, authorID: authorID))
        guard liked else { return await delete(id) }
        let record = CKRecord(recordType: Self.likeRecordType, recordID: id)
        record["postID"] = postID
        record["authorID"] = authorID
        record["createdAt"] = Date()
        // Denormalised post author, so "someone liked your post" is deliverable at all — a
        // subscription predicate can only test fields on the record that changed, and a like
        // otherwise names only its own author. Empty on a self-like, which is what stops you being
        // notified about your own tap. See `likeTarget`.
        record[Self.likeTargetField] = await likeTarget(postID: postID, likerID: authorID)
        // Overwrite rather than fetch-then-save: the record is keyed by (post, reader), so a save
        // that collides with an existing row is this same reader liking again, not a conflict.
        do {
            let (saves, _) = try await database.modifyRecords(
                saving: [record], deleting: [], savePolicy: .allKeys
            )
            // Per-record failures don't throw, so the operation succeeding isn't enough.
            return saves.values.allSatisfy { if case .success = $0 { return true } else { return false } }
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    /// Every like on the given posts. Returns nil when the query itself failed, which is different
    /// from "nobody liked anything" — conflating the two would zero every count when offline.
    func fetchLikes(postIDs: [String]) async -> [RemoteLike]? {
        #if CLOUDKIT_ENABLED
        let records = await fetchAll(recordType: Self.likeRecordType, postIDs: postIDs, sortKey: nil)
        return records.map { $0.compactMap(RemoteLike.init) }
        #else
        return nil
        #endif
    }

    // MARK: - Comments

    /// Post a comment. Returns the remote id, or nil if it didn't land.
    func addComment(postID: String,
                    authorID: String,
                    authorName: String,
                    text: String,
                    createdAt: Date) async -> String? {
        #if CLOUDKIT_ENABLED
        let record = CKRecord(recordType: Self.commentRecordType)
        record["postID"] = postID
        record["authorID"] = authorID
        record["authorName"] = authorName
        record["text"] = text
        record["createdAt"] = createdAt
        record["replyTargetID"] = await replyTarget(postID: postID, commenterID: authorID)
        do {
            let saved = try await database.save(record)
            return saved.recordID.recordName
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Delete a comment — again creator-only, enforced by the database.
    func deleteComment(id: String) async -> Bool {
        #if CLOUDKIT_ENABLED
        return await delete(CKRecord.ID(recordName: id))
        #else
        return false
        #endif
    }

    /// Every comment on the given posts, oldest first. Nil means the query failed.
    func fetchComments(postIDs: [String]) async -> [RemoteComment]? {
        #if CLOUDKIT_ENABLED
        let records = await fetchAll(recordType: Self.commentRecordType,
                                     postIDs: postIDs, sortKey: "createdAt")
        return records.map { $0.compactMap(RemoteComment.init) }
        #else
        return nil
        #endif
    }

    // MARK: - Push subscriptions

    #if CLOUDKIT_ENABLED

    /// Who should be told about this reply — the post's author, denormalised onto the comment.
    ///
    /// A `CKQuerySubscription` predicate can only test fields on the record that changed, and a
    /// comment otherwise names only its own author. Without this field "someone replied to your
    /// post" is undeliverable: the alternative would be a subscription per post the user owns,
    /// re-created every time they post.
    ///
    /// Empty when the commenter *is* the author. A pure-equality predicate (`replyTargetID == me`)
    /// then matches nobody, so replying to your own post can never notify you — self-notification is
    /// prevented by the data rather than by a `!=` clause, which query subscriptions handle far less
    /// reliably than plain equality.
    ///
    /// A failed lookup yields an empty string: the reply still posts, it just goes unannounced.
    private func replyTarget(postID: String, commenterID: String) async -> String {
        let post = try? await database.record(for: CKRecord.ID(recordName: postID))
        guard let authorID = post?["authorID"] as? String, authorID != commenterID else { return "" }
        return authorID
    }

    /// Who should be told about this like — the post's author, denormalised onto the like.
    ///
    /// Identical reasoning to `replyTarget`: a `CKQuerySubscription` predicate can only test fields
    /// on the changed record, so without this "someone liked your post" is undeliverable.
    ///
    /// Empty when the liker *is* the author, so a pure-equality predicate (`likeTargetID == me`)
    /// matches nobody and liking your own post can never notify you. Deliberately NOT a `!=` clause:
    /// query subscriptions handle plain equality far more reliably — a `!=` predicate is in fact
    /// rejected outright at registration (see the CommunityEvent broadcast, fixed 2026-08-30).
    ///
    /// A failed lookup yields an empty string: the like still lands, it just goes unannounced.
    private func likeTarget(postID: String, likerID: String) async -> String {
        let post = try? await database.record(for: CKRecord.ID(recordName: postID))
        guard let authorID = post?["authorID"] as? String, authorID != likerID else { return "" }
        return authorID
    }

    #endif

    // MARK: - Shared plumbing

    #if CLOUDKIT_ENABLED

    /// Records of `recordType` attached to any of `postIDs`, in slices small enough for an `IN`
    /// predicate and following each slice's cursor so a popular post's tail isn't silently dropped.
    ///
    /// Nil on failure; an empty array means there genuinely are none.
    private func fetchAll(recordType: String,
                          postIDs: [String],
                          sortKey: String?) async -> [CKRecord]? {
        guard !postIDs.isEmpty else { return [] }
        var records: [CKRecord] = []

        for start in stride(from: 0, to: postIDs.count, by: Self.idsPerQuery) {
            let slice = Array(postIDs[start..<min(start + Self.idsPerQuery, postIDs.count)])
            let query = CKQuery(recordType: recordType,
                                predicate: NSPredicate(format: "postID IN %@", slice))
            if let sortKey {
                query.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: true)]
            }
            do {
                var page = try await database.records(
                    matching: query, desiredKeys: nil, resultsLimit: Self.pageSize
                )
                records += page.matchResults.compactMap { try? $0.1.get() }
                while let cursor = page.queryCursor {
                    page = try await database.records(
                        continuingMatchFrom: cursor, desiredKeys: nil, resultsLimit: Self.pageSize
                    )
                    records += page.matchResults.compactMap { try? $0.1.get() }
                }
            } catch {
                return nil
            }
        }
        return records
    }

    /// Write image bytes to a temp file so `CKAsset` can upload them. Nil simply means this post
    /// carries no photo rather than failing the whole publish — the caption is still worth posting.
    private static func stageAsset(_ data: Data) -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("post-image-\(UUID().uuidString).jpg")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// A record that is already absent is the goal state, not a failure — an unlike sent twice, or
    /// a post deleted from another device.
    private func delete(_ id: CKRecord.ID) async -> Bool {
        do {
            _ = try await database.deleteRecord(withID: id)
            return true
        } catch let error as CKError where error.code == .unknownItem {
            return true
        } catch {
            return false
        }
    }

    #endif
}
