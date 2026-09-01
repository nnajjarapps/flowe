import Foundation
import SwiftData

/// Builds the app's SwiftData container.
///
/// Two configurations in one container:
/// - **Reference** (`Instructor`) — always local (`.none`). A read-only catalog seeded per device;
///   kept off CloudKit because SwiftData can't mirror a public DB and we don't want per-device dupes.
/// - **UserData** (`FeedPost`, `Booking`, …) — user-owned. Mirrored to the CloudKit **private**
///   database when the app is built with `CLOUDKIT_ENABLED`. Anything two users must both see —
///   bookings, messages, reviews, community posts — additionally travels through the *public*
///   database as raw `CKRecord`; the models here are that shared state's offline cache.
///
/// iOS 17's `ModelConfiguration(cloudKitDatabase:)` supports only `.private` / `.none` — there is no
/// public/shared option — which is exactly why the split above is shaped this way.
enum FloweModelContainer {

    /// CloudKit container id — must match the iCloud container created in the paid portal.
    static let cloudKitContainerID = "iCloud.com.flowepilates.app"

    /// Persisted marker that the user's iCloud is full, so the private-DB mirror must be skipped.
    /// Deliberately in UserDefaults, not the store: it has to be readable BEFORE the container exists.
    static let iCloudFullKey = "flowe.icloudStorageFull"

    static func make(inMemory: Bool = false) -> ModelContainer {
        if !inMemory { ensureApplicationSupportExists() }

        let reference = ModelConfiguration(
            "Reference",
            schema: Schema([Instructor.self, StudentProfile.self, Opportunity.self, OpportunityApplication.self, ApplicationDecision.self, InstructorRecommendation.self]),
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )

        // Community models are PURE CACHES of CloudKit-public content, so they are deliberately NOT
        // mirrored to the user's private iCloud.
        //
        // Mirroring a cache there cost the user quota for re-fetchable data AND broke the feed outright
        // when their iCloud filled up: the mirror stops, `resetAfterError` discards committed local
        // writes, and a post deleted by its author kept reappearing because the prune never persisted.
        // Every field here re-fetches on the next sync, so there is nothing to lose by dropping it —
        // the last piece of local-only state was `FeedPost.saved`, which now lives on the backend.
        //
        // This is exactly how a feed is normally built: content on a server, a purely local cache, and
        // nothing depending on the reader having cloud storage free.
        let communityCache = ModelConfiguration(
            "CommunityCache",
            schema: Schema([FeedPost.self, PostComment.self, CommunityEvent.self]),
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )

        let userData = ModelConfiguration(
            "UserData",
            schema: Schema([Booking.self, Message.self,
                            BlockedUser.self, Review.self, LessonType.self,
                            ClientNote.self, Program.self, VideoExercise.self]),
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: userDataCloudKitDatabase(inMemory: inMemory)
        )

        do {
            return try ModelContainer(
                for: Instructor.self, StudentProfile.self, Opportunity.self, OpportunityApplication.self, ApplicationDecision.self, InstructorRecommendation.self, FeedPost.self, PostComment.self, Booking.self, Message.self,
                     BlockedUser.self, Review.self, CommunityEvent.self, LessonType.self, ClientNote.self, Program.self, VideoExercise.self,
                configurations: reference, communityCache, userData
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    /// iOS doesn't create `Library/Application Support` for us; SwiftData's default store URLs live
    /// there. Creating it first avoids the noisy CoreData "failed to create file" recovery on first launch.
    private static func ensureApplicationSupportExists() {
        _ = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    private static func userDataCloudKitDatabase(inMemory: Bool) -> ModelConfiguration.CloudKitDatabase {
        #if CLOUDKIT_ENABLED
        // In-memory (previews/tests) never syncs.
        if inMemory { return .none }
        #if DEBUG
        // Two-party test harness: with `-flowe.disablePrivateSync 1`, skip the private-DB mirror so
        // two simulators can share ONE iCloud account without their private stores cross-contaminating
        // (the two-party flows under test — booking, messaging, community, reviews, student photos —
        // all travel the PUBLIC database, which is unaffected by this).
        if UserDefaults.standard.bool(forKey: "flowe.disablePrivateSync") { return .none }
        #endif
        // The USER's iCloud is full. Keep the app fully working by dropping the private-DB mirror
        // entirely rather than letting it fail.
        //
        // This is not a nicety. When the mirror cannot export it repeatedly calls `resetAfterError:`,
        // and that reset DISCARDS COMMITTED LOCAL WRITES — an edit saves, then silently reverts, on any
        // screen, with no error anywhere. Running local-only is strictly better than running with a
        // broken mirror: everything persists, nothing reverts, and the only thing lost is cross-device
        // sync of the two models that have no other home (ClientNote, BlockedUser).
        //
        // Set by `MockDataStore.observeCloudKitHealth()`; cleared by the user from the banner. Read at
        // container construction, so it takes effect on the next launch.
        if UserDefaults.standard.bool(forKey: iCloudFullKey) { return .none }
        return .private(cloudKitContainerID)
        #else
        return .none
        #endif
    }
}
