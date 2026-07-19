# Flowe Migration Plan: Mock Data → SwiftData Local Cache + CloudKit Sync

> Produced by a design workflow (5 facet agents + synthesis) reading the real code. Planning only —
> no code changed. Companion to `PROGRESS.md` Phase 9.

## Core architectural decision: facade over `@Query`

All five facets converge on one de-risking choice: **keep `MockDataStore`'s public API intact and swap only its internals** from JSON-in-Documents to a SwiftData `ModelContext`. This preserves every signature (`instructors`, `posts`, `bookings`, `upcomingBookings`, `pastBookings`, `instructor(id:)`, `toggleLike`, `toggleSave`, `addBooking`, `upcomingCount`, `completedCount`, `hoursDisplay`) so the ~14 screens reading `@Environment(MockDataStore.self)` barely change. `@Query` is deferred to a later, selective pass (it can't satisfy the synchronous preview constructors like `MockDataStore().instructors[0]`, keyed `instructor(id:)` lookups, or derived scalars). The models become `@Model` classes; the facade maps them at its boundary.

## Recommended CloudKit database split

**Private DB (SwiftData auto-mirror): user-owned data only** — `Booking`, per-user like/save engagement, profile. **Local-only non-synced config: `Instructor`** (read-only reference catalog, seeded per-device). **Public DB (deferred, raw CloudKit / `CKSyncEngine`): instructor catalog + community feed bodies.**

Rationale: SwiftData's `ModelConfiguration(cloudKitDatabase:)` in iOS 17 supports **only** `.private`/`.none` — there is no `.public`/`.shared` case. So shared data physically cannot ride the mirrored store. Private data is naturally 1:1 with an iCloud identity and gets sync+offline nearly free. Keeping `Instructor` local avoids the no-`@Attribute(.unique)` duplicate-seed problem across devices. Critically: **`FeedPost.likes` must not stay an `Int` counter** — field-level last-writer-wins loses concurrent increments; model likes/saves as per-user engagement rows so `toggleLike/toggleSave` stay conflict-free.

---

## PHASE A — SwiftData local (free team, fully simulator-testable)

No entitlement/capability needed. Runs on team `UYY2KBNZYQ` today.

1. Convert `Flowe/Models/Instructor.swift`, `FeedPost.swift`, `Booking.swift` to `@Model` classes — every stored property defaulted-or-optional, no `@Attribute(.unique)`, enums stored as `Codable`. Keep a stable `var legacyId: Int?` so `instructor(id:)` and seed cross-links still resolve. Store `status: BookingStatus = .pending` / `type: PostType = .tip` directly. **Move** `BookingStatus`'s `Color` props out to a new `Flowe/DesignSystem/BookingStatus+Badge.swift`; `Booking.swift` drops `import SwiftUI`.
2. Add `Flowe/Data/FloweModelContainer.swift` — two `ModelConfiguration`s in one container: `UserData` (`FeedPost`, `Booking`) and `Reference` (`Instructor`), both `cloudKitDatabase: .none` for now.
3. Add `Flowe/Data/SeedLoader.swift` — idempotent `seedIfNeeded` decoding bundled `Flowe/MockData/*.json`; **guard on empty-store fetch count == 0** (mandatory — no unique constraint means re-seeding multiplies rows). Relocate `Bundle.decode` here.
4. Add `Flowe/Data/PreviewSupport.swift` — `MockDataStore.preview` over an in-memory seeded container; migrate the ~13 `#Preview` blocks mechanically.
5. Rewrite `Flowe/Data/MockDataStore.swift` internals: hold a `ModelContext`, back each property with a `FetchDescriptor`, mutators as fetch-mutate-`save()`, drop the `didSet`/Documents persistence. Keep `@MainActor` (satisfies `SWIFT_STRICT_CONCURRENCY: complete`).
6. `Flowe/FlowApp.swift`: attach `.modelContainer(container)` and build `MockDataStore(container.mainContext)`.
7. Leave the instructor-side inline mocks (Dashboard/Calendar/Messages/InstructorProfile) as static presentation constants for now (promotion is an open decision).

**project.yml/xcodegen:** none beyond `xcodegen generate` for the new files.

**Verification (same loop we use now):** build + launch on simulator; screenshot Discover/Community/Bookings/Profile for pixel parity; like a post + create a booking, terminate, relaunch → state survives; `sqlite3` the store to confirm no double-seed; launch **twice** to prove the empty-store guard.

## PHASE B — CloudKit sync (requires PAID account)

A config flip on Phase A; models already obey CloudKit rules.

1. Create container `iCloud.com.flowepilates.app` in the paid portal.
2. Add `Flowe/Flowe-CloudKit.entitlements` (`icloud-services: [CloudKit]`, `icloud-container-identifiers`, `aps-environment`); keep existing `Flowe.entitlements` free-team-safe.
3. `project.yml`: add a `CloudKit` build config selecting the CloudKit entitlements via per-config `CODE_SIGN_ENTITLEMENTS` + `SWIFT_ACTIVE_COMPILATION_CONDITIONS: CLOUDKIT_ENABLED`; add `UIBackgroundModes: [remote-notification]`. Debug/Release stay on the free team untouched.
4. `FloweModelContainer.swift`: gate `UserData` config to `.private("iCloud.com.flowepilates.app")` behind `#if CLOUDKIT_ENABLED`; `Reference` stays `.none`.
5. `xcodegen generate` with Xcode signed into the paid team.

**Verification:** real device signed into iCloud (simulator sync is unreliable); confirm record types in CloudKit Dashboard → Development → Private DB; two-device convergence of a like/booking; confirm instructors did **not** duplicate. **Promote schema Development → Production** before any TestFlight build.

## PHASE C — Auth / ownership (mostly free-team code)

SIWA is already wired (`CreateAccountView`/`LoginView` → `AppSession`).

1. In `CreateAccountView.handleApple` (+ LoginView), capture `cred.user` (the only stable Apple id — currently discarded); persist to **Keychain**, not `UserDefaults`.
2. `AppSession.swift`: add `appleUserID`; validate on launch via `getCredentialState(forUserID:)`, replacing the bare `isLoggedIn` bool.
3. Add optional/defaulted `ownerID` to `FeedPost`/`Booking`, stamped in `addBooking`/engagement mutators; scope user-owned fetches by it.

**Verification:** sign in on iCloud-signed simulator, create a booking, relaunch → still signed in; simulate `.revoked` → returns to unauthenticated.

---

## Ranked open decisions

1. **Instructor storage under CloudKit** — recommended local-only reference config (avoids per-device cloud duplication). Confirm instructors never need user-editing/sync.
2. **Like/save modeling** — per-user engagement rows (required for conflict-free sync) vs. bools on `FeedPost` (loses concurrent updates). Recommend rows before Phase B.
3. **"Me = instructors.first" identity hack** (4 instructor screens) — centralize behind `data.currentInstructor` resolved from `AppSession.currentUser`; needed before multi-user CloudKit.
4. **Promote inline instructor-side mocks to `@Model`** now, or keep static until a scheduling/messaging backend exists.
5. **`Booking.date`/`time` as `String` vs `Date`** — also fixes the "55 MIN"/"55 min" duration inconsistency.
6. **Timing of the paid account** — the sole gate for all of Phase B.
7. **Keep the name `MockDataStore`** (zero screen edits) vs. rename to `FloweStore`.

**Start here:** Convert the three `Flowe/Models/*` structs to CloudKit-legal `@Model` classes and move `BookingStatus`'s colors into `Flowe/DesignSystem/BookingStatus+Badge.swift` — the foundation every later phase builds on, and fully verifiable on the free team.
