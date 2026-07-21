import Foundation
import CloudKit

/// A community post as it exists in the shared store (plain DTO decoded from a CKRecord).
struct RemotePost {
    let id: String
    let authorID: String
    let authorName: String
    let type: String
    let instructorName: String
    let rating: Int
    let text: String
    let createdAt: Date

    init?(record: CKRecord) {
        guard let authorID = record["authorID"] as? String,
              let text = record["text"] as? String else { return nil }
        id = record.recordID.recordName
        self.authorID = authorID
        self.text = text
        authorName = record["authorName"] as? String ?? ""
        type = record["type"] as? String ?? PostType.tip.rawValue
        instructorName = record["instructorName"] as? String ?? ""
        rating = record["rating"] as? Int ?? 0
        createdAt = record["createdAt"] as? Date ?? .distantPast
    }
}

/// One reader's like of one post. There is no count field anywhere — the count *is* how many of
/// these exist (see the note on `CommunityService`).
struct RemoteLike {
    let postID: String
    let authorID: String

    init?(record: CKRecord) {
        guard let postID = record["postID"] as? String,
              let authorID = record["authorID"] as? String else { return nil }
        self.postID = postID
        self.authorID = authorID
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

    /// How much feed is worth carrying on a phone. Also bounds the `IN` lists the engagement
    /// queries build, which CloudKit will reject if they grow without limit.
    private static let feedLimit = 100
    private static let pageSize = 400
    /// CloudKit dislikes very large `IN` arrays, so engagement is fetched in slices.
    private static let idsPerQuery = 50

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    // MARK: - Posts

    /// Publish a post. Returns the remote id, or nil if it didn't reach the server.
    func publish(authorID: String,
                 authorName: String,
                 type: String,
                 instructorName: String,
                 rating: Int,
                 text: String,
                 createdAt: Date) async -> String? {
        #if CLOUDKIT_ENABLED
        let record = CKRecord(recordType: Self.postRecordType)
        record["authorID"] = authorID
        record["authorName"] = authorName
        record["type"] = type
        record["instructorName"] = instructorName
        record["rating"] = rating
        record["text"] = text
        record["createdAt"] = createdAt
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
    func fetchRecentPosts() async -> [RemotePost] {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.postRecordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        do {
            let (matches, _) = try await database.records(
                matching: query, desiredKeys: nil, resultsLimit: Self.feedLimit
            )
            return matches.compactMap { try? $0.1.get() }.compactMap(RemotePost.init)
        } catch {
            return []
        }
        #else
        return []
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
