import Foundation
import CloudKit

/// A video exercise as it exists in the shared public store (plain DTO decoded from a CKRecord).
struct RemoteVideoExercise {
    let id: String
    let ownerID: String
    let programID: String
    let title: String
    let coachingNotes: String
    let prescription: String
    let focus: String
    let level: String
    let order: Int
    let durationSeconds: Int
    /// Known from the metadata query without downloading the assets themselves.
    let hasThumbnail: Bool
    let hasVideo: Bool
    let createdAt: Date
    let updatedAt: Date

    init?(record: CKRecord) {
        guard let ownerID = record["ownerID"] as? String else { return nil }
        id = record.recordID.recordName
        self.ownerID = ownerID
        programID = record["programID"] as? String ?? ""
        title = record["title"] as? String ?? ""
        coachingNotes = record["coachingNotes"] as? String ?? ""
        prescription = record["prescription"] as? String ?? ""
        focus = record["focus"] as? String ?? ""
        level = record["level"] as? String ?? ""
        order = record["order"] as? Int ?? 0
        durationSeconds = record["durationSeconds"] as? Int ?? 0
        hasThumbnail = (record["hasThumbnail"] as? Int ?? 0) == 1
        hasVideo = (record["hasVideo"] as? Int ?? 0) == 1
        createdAt = record["createdAt"] as? Date ?? .distantPast
        updatedAt = record["updatedAt"] as? Date ?? .distantPast
    }
}

/// Instructor-authored video exercises over CloudKit's **public** database, shaped like
/// `LessonTypeService` but carrying TWO CKAssets: a small `thumbnail` (fetched with the metadata split,
/// like a lesson-type photo) and the large `video` (fetched ONLY on demand for playback — never on the
/// list query). Deterministic recordName `exercise-<localID>`. See [[FloweEducation]].
@MainActor
final class ExerciseService {
    static let recordType = "VideoExercise"

    private static let thumbsPerSync = 12

    /// Everything on an exercise EXCEPT the two assets. `desiredKeys: nil` would download every thumbnail
    /// AND every video clip on each refresh — the video especially must stay off the list query.
    static let exerciseMetadataKeys = [
        "ownerID", "programID", "title", "coachingNotes", "prescription", "focus", "level",
        "order", "durationSeconds", "hasThumbnail", "hasVideo", "createdAt", "updatedAt",
    ]

    #if CLOUDKIT_ENABLED
    private let database = CKContainer(identifier: FloweModelContainer.cloudKitContainerID).publicCloudDatabase
    #endif

    /// Create or edit an exercise. Fetch-then-mutate, last-writer-wins retry. Assets are PRESERVE-IF-NIL:
    /// pass `thumbnail`/`video` only to set/replace them, and a metadata-only edit (both nil) leaves the
    /// existing assets untouched — so the large clip never has to be re-uploaded to change a title, and it
    /// can't be accidentally blanked (the video is not retained in the @Model to re-send).
    func upsert(localID: UUID,
                ownerID: String,
                programID: String,
                title: String,
                coachingNotes: String,
                prescription: String,
                focus: String,
                level: String,
                order: Int,
                durationSeconds: Int,
                createdAt: Date,
                thumbnail: Data?,
                video: Data?) async -> String? {
        #if CLOUDKIT_ENABLED
        let id = CKRecord.ID(recordName: "exercise-\(localID.uuidString)")
        let record = (try? await database.record(for: id)) ?? CKRecord(recordType: Self.recordType, recordID: id)

        let thumbStaged = thumbnail.flatMap { Self.stageAsset($0, ext: "jpg") }
        let videoStaged = video.flatMap { Self.stageAsset($0, ext: "mp4") }
        defer {
            thumbStaged.map { try? FileManager.default.removeItem(at: $0) }
            videoStaged.map { try? FileManager.default.removeItem(at: $0) }
        }

        Self.apply(to: record, ownerID: ownerID, programID: programID, title: title, coachingNotes: coachingNotes,
                   prescription: prescription, focus: focus, level: level, order: order,
                   durationSeconds: durationSeconds, createdAt: createdAt, thumbStaged: thumbStaged, videoStaged: videoStaged)

        do {
            let saved = try await database.save(record)
            return saved.recordID.recordName
        } catch let error as CKError where error.code == .serverRecordChanged {
            guard let server = error.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord else { return nil }
            Self.apply(to: server, ownerID: ownerID, programID: programID, title: title, coachingNotes: coachingNotes,
                       prescription: prescription, focus: focus, level: level, order: order,
                       durationSeconds: durationSeconds, createdAt: createdAt, thumbStaged: thumbStaged, videoStaged: videoStaged)
            let saved = try? await database.save(server)
            return saved?.recordID.recordName
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    func delete(id: String) async -> Bool {
        #if CLOUDKIT_ENABLED
        return await delete(CKRecord.ID(recordName: id))
        #else
        return false
        #endif
    }

    /// One instructor's own exercises (all programs). A reader groups them by `programID`.
    func fetch(ownerID: String) async -> [RemoteVideoExercise] {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(format: "ownerID == %@", ownerID))
        do {
            let (matches, _) = try await database.records(
                matching: query, desiredKeys: Self.exerciseMetadataKeys, resultsLimit: 400
            )
            return matches.compactMap { try? $0.1.get() }.compactMap(RemoteVideoExercise.init)
        } catch {
            return []
        }
        #else
        return []
        #endif
    }

    /// Download poster thumbnails for specific exercises, capped at `thumbsPerSync`. Keyed by record name.
    func fetchThumbnails(ids: [String]) async -> [String: Data] {
        #if CLOUDKIT_ENABLED
        let wanted = Array(ids.prefix(Self.thumbsPerSync))
        guard !wanted.isEmpty else { return [:] }
        let recordIDs = wanted.map { CKRecord.ID(recordName: $0) }
        guard let results = try? await database.records(for: recordIDs, desiredKeys: ["thumbnail"]) else { return [:] }
        var images: [String: Data] = [:]
        for (id, result) in results {
            guard let record = try? result.get(),
                  let url = (record["thumbnail"] as? CKAsset)?.fileURL,
                  let data = try? Data(contentsOf: url) else { continue }
            images[id.recordName] = data
        }
        return images
        #else
        return [:]
        #endif
    }

    /// Fetch the clip for playback. A `CKAsset.fileURL` is reclaimed once the record scope ends, so this
    /// COPIES the asset to a stable temp URL for `AVPlayer`. Nil if the exercise has no video / offline.
    /// The caller owns the returned file and should remove it when playback ends.
    func fetchVideoURL(id: String) async -> URL? {
        #if CLOUDKIT_ENABLED
        guard let results = try? await database.records(for: [CKRecord.ID(recordName: id)], desiredKeys: ["video"]),
              let result = results.values.first,
              let record = try? result.get(),
              let assetURL = (record["video"] as? CKAsset)?.fileURL else { return nil }
        let dest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("exercise-video-\(UUID().uuidString).mp4")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: assetURL, to: dest)
            return dest
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Remove every exercise this owner created — the account-deletion sweep.
    func removeAll(ownerID: String) async {
        #if CLOUDKIT_ENABLED
        let query = CKQuery(recordType: Self.recordType, predicate: NSPredicate(format: "ownerID == %@", ownerID))
        guard let (matches, _) = try? await database.records(matching: query, desiredKeys: [], resultsLimit: 400) else { return }
        let ids = matches.map(\.0)
        guard !ids.isEmpty else { return }
        _ = try? await database.modifyRecords(saving: [], deleting: ids)
        #endif
    }

    // MARK: - Shared plumbing
    #if CLOUDKIT_ENABLED
    private static func apply(to record: CKRecord, ownerID: String, programID: String, title: String,
                              coachingNotes: String, prescription: String, focus: String, level: String,
                              order: Int, durationSeconds: Int, createdAt: Date, thumbStaged: URL?, videoStaged: URL?) {
        record["ownerID"] = ownerID
        record["programID"] = programID
        record["title"] = title
        record["coachingNotes"] = coachingNotes
        record["prescription"] = prescription
        record["focus"] = focus
        record["level"] = level
        record["order"] = order
        record["durationSeconds"] = durationSeconds
        record["createdAt"] = createdAt
        record["updatedAt"] = Date()
        // Preserve-if-nil: only overwrite an asset when a fresh one is staged, so a metadata-only edit
        // never re-uploads or blanks the clip. `durationSeconds` travels with a new video.
        if let thumbStaged {
            record["thumbnail"] = CKAsset(fileURL: thumbStaged)
            record["hasThumbnail"] = 1
        }
        if let videoStaged {
            record["video"] = CKAsset(fileURL: videoStaged)
            record["hasVideo"] = 1
            record["durationSeconds"] = durationSeconds
        }
    }

    private static func stageAsset(_ data: Data, ext: String) -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("exercise-asset-\(UUID().uuidString).\(ext)")
        do { try data.write(to: url); return url } catch { return nil }
    }

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
