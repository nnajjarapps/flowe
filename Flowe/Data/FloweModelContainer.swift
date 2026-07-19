import Foundation
import SwiftData

/// Builds the app's SwiftData container.
///
/// Two configurations in one container:
/// - **Reference** (`Instructor`) — always local (`.none`). A read-only catalog seeded per device;
///   kept off CloudKit because SwiftData can't mirror a public DB and we don't want per-device dupes.
/// - **UserData** (`FeedPost`, `Booking`) — user-owned. Local today; mirrored to the CloudKit
///   **private** database when the app is built with `CLOUDKIT_ENABLED` (Phase B, paid account).
///
/// iOS 17's `ModelConfiguration(cloudKitDatabase:)` supports only `.private` / `.none` — there is no
/// public/shared option — which is exactly why the split above is shaped this way.
enum FloweModelContainer {

    /// CloudKit container id — must match the iCloud container created in the paid portal.
    static let cloudKitContainerID = "iCloud.com.flowepilates.app"

    static func make(inMemory: Bool = false) -> ModelContainer {
        if !inMemory { ensureApplicationSupportExists() }

        let reference = ModelConfiguration(
            "Reference",
            schema: Schema([Instructor.self]),
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )

        let userData = ModelConfiguration(
            "UserData",
            schema: Schema([FeedPost.self, Booking.self]),
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: userDataCloudKitDatabase(inMemory: inMemory)
        )

        do {
            return try ModelContainer(
                for: Instructor.self, FeedPost.self, Booking.self,
                configurations: reference, userData
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
        return inMemory ? .none : .private(cloudKitContainerID)
        #else
        return .none
        #endif
    }
}
