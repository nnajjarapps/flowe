# Flowe — Build Progress

Implementation is driven by the Figma mockup in `Flowe/Pilates app/` (excluded from the
build via `project.yml`). **Locked design decisions:**

- **Palette:** the Figma **pink** palette (`#E8789A` / `#D45880` …) is the app's source of truth.
- **Fonts:** **Fraunces + DM Sans + DM Mono** bundled as TrueType in `Flowe/Resources/Fonts/`.
- **Scope:** the **whole app** — student experience faithful to the Figma, instructor experience
  designed from this roadmap in the same design system.
- **Tooling:** XcodeGen manages the project; run `xcodegen generate` after adding files.
- **Images:** `AsyncImage` from the mockup's Unsplash photo IDs, gradient placeholder fallback.

**Status: all screens built and verified running in the simulator (build green).**
UI is complete across both role trees; several interactions are still *cosmetic* — see
**Phase 9 — Functional wiring & persistence** for the real remaining work.

---

## Phase 1 — Bootstrap, Design System, Onboarding & Auth  ✅
- [x] Xcode project (xcodegen), design system, extensions, AppSession + AppRouter, onboarding, models

## Phase 0 — Retheme Foundation (pink + real fonts)  ✅
- [x] FlowColor pink tokens, FlowGradients grad/gradDark
- [x] 11 bundled TrueType fonts + UIAppFonts; FlowTypography → FloweFont.serif/sans/mono
- [x] XcodeGen 2.46.0 installed; `Pilates app/**` excluded from build
- [x] Onboarding + all shared atoms recolored to pink

## Phase 2 — Data Layer & Models  ✅
- [x] Instructor, FeedPost (+PostType), Booking (+BookingStatus) models
- [x] Mock JSON: instructors.json, posts.json, bookings.json
- [x] MockDataStore (@Observable bundle decoder) + UnsplashImage helper + FloweConstants/ProfileMock

## Phase 3 — Shared DS Components  ✅
- [x] RemoteImage, AvatarView, SectionHeader, StarRatingView, SpecialtyTag, StatusBadge
- [x] StatTile, GradientButton, FilterChipsBar/CategoryChip, .floweCard()
- [x] Recolored IconButton / SecondaryButton / DisciplineTag

## Phase 4 — Student Shell + Discover  ✅
- [x] StudentTabView → Discover / Community / Bookings / Profile
- [x] DiscoverView (search, category filter, featured hero, list) + InstructorCard + FeaturedHeroCard

## Phase 5 — Booking Flow (4-step modal)  ✅ (UI only)
- [x] BookingSheet: bio → pick day (availability-gated) → time + type → confirmation receipt
- [x] Wired from Discover card tap and Bookings "Book again"
- ⚠️ Confirmation is cosmetic — does NOT add to `data.bookings` (see Phase 9)

## Phase 6 — Community, Bookings, Profile  ✅
- [x] CommunityView + PostRowView (stories, feed variants, like/save toggles)
- [x] BookingsView + BookingCard (stat tiles, upcoming/past, status badges)
- [x] ProfileView + WeeklyBarChart (header, achievements, account list, log out)

## Phase 7 — Instructor Experience  ✅
- [x] InstructorTabView → Dashboard / Calendar / Messages / Profile
- [x] InstructorDashboardView (KPIs, today's schedule, quick actions)
- [x] InstructorCalendarView (week strip, schedule, booking requests Accept/Decline)
- [x] InstructorProfileView (Overview / Analytics / Reviews / Earnings)
- [x] Messages: MessageListView, ConversationView, MessageBubble

## Settings — Currency & Language  ✅
- [x] `AppSettings` (@Observable, persisted) — currency + language; injected app-wide
- [x] **Currency** applied to every price (Discover, BookingSheet receipt, dashboard KPI, earnings,
      payouts) via `settings.money(_:)` — 8 currencies, locale-aware formatting (verified € and AED)
- [x] **Language** — live locale switch (en/es/fr/ar) via `.environment(\.locale)`, RTL for Arabic;
      `Localizable.xcstrings` localizes tab bar + settings chrome (verified Spanish + Arabic RTL)
- [x] `SettingsView` (currency + language pickers, notifications, log out) reachable from student
      gear + instructor profile menu
- Note: content strings (bios, posts, section headers) stay source-language — extend by adding keys
  to `Localizable.xcstrings`.

## Pilot readiness — mock-data removal & empty states  ✅
- [x] App ships **empty** — seeding gated to SwiftUI previews only; nothing pushed to CloudKit
- [x] Real user identity — `AppSession` persists the signed-in `User`; owner id scopes records
- [x] Instructor gets a real **own listing** on login (`ensureInstructorProfile`), editable via Edit Profile
- [x] Removed all hardcoded/sample data (Mia Tanaka, Sofia, DashboardSession/Calendar/InstructorProfile
      mocks, message threads); `FeaturedHeroCard` is data-driven
- [x] **Empty states** across Discover / Community / Bookings / Profile / Dashboard / Calendar /
      Messages / instructor Profile (verified in simulator, both roles)
- [x] `publishedInstructors` — incomplete listings (no rate) stay hidden from students
- Note: instructors are still **local** (SwiftData Reference store), so they don't yet appear across
  devices — needs the shared/public-catalog path (public CloudKit DB / CKSyncEngine or backend).

## Revenue — Instructor IAP subscriptions (Phase A ✅)
Flowe's first profit model. See `FLOWE-IAP-PLAN.md`.
- [x] StoreKit 2 `SubscriptionService` (@MainActor @Observable) — products, entitlements, purchase/restore,
      `Transaction.updates` listener; tiers **Visible** ($9.99, 1-mo free trial) + **Boost** ($29.99)
- [x] `Flowe.storekit` local config wired into the scheme (simulator-testable, no ASC needed)
- [x] `PaywallView` ("Get discovered") — tiers, trial, Restore, auto-renew disclosure + Terms/Privacy
- [x] Feed gating: `Instructor.visibility` (none/visible/boosted) + `visibleInstructors`/`featuredInstructor`
      ranking (7-day TTL); non-subscribed instructors are hidden; `FlowApp` stamps visibility on tier change
- [x] Entry points: dashboard "Get discovered" banner (when hidden) + instructor profile menu
- [x] Verified in simulator: boosted → featured hero, visible → feed, non-subscribed → hidden; banner + paywall render
- [x] **Phase B — public instructor catalog** (built): `CatalogService` over CloudKit `publicCloudDatabase`
      (record type `InstructorListing`, recordName == ownerID). Instructors publish their listing +
      visibility on edit/subscription change; students `syncCatalog()` on Discover/Community (pull-to-refresh
      too) → cached into the local store the feed reads; lapsed/unsubscribed listings auto-hide. Degrades
      gracefully offline. **Full cross-device sync needs real devices + iCloud + the deployed schema.**
      ⚠️ You must, in the **CloudKit Dashboard**: add the `InstructorListing` record type, make
      `visibility`/`updatedAt` **queryable** + `visibility` **sortable**, set security = `_world` read /
      `_creator` write, then **Deploy schema to Production**.
- [ ] **Phase C — App Store Connect**: create the subscription group + products/prices/trial, banking/tax,
      sandbox tester, CloudKit public-DB security roles (user-side)

## Phase 8 — Polish & Verification  ◑
- [x] Verified all 9 screens running in the simulator (student + instructor trees)
- [x] AppIcon fixed → single 1024×1024, no-alpha icon (was 3 invalid `.PNG` slots)
- [x] Sign in with Apple: added entitlement + capability, durable team signing, real
      credential parsing + cancel handling (needs iCloud on sim / paid membership on device)
- [ ] Hero matchedGeometryEffect (card → sheet), heart micro-animation, stat count-up
- [ ] Empty states + ShimmerView skeletons
- [ ] Accessibility labels/hints sweep; Dynamic Type XL + iPhone SE verification

## Phase 9 — Functional wiring & persistence  ◑ (in progress)
Screens exist but most interactions are hollow. Done so far:
- [x] **Booking creation** — BookingSheet "Confirm" adds a `Booking` to the store → shows in Bookings tab (verified)
- [x] **Persistence** — posts (likes/saves) + bookings persist to Documents JSON, survive relaunch (verified)
- [x] Bookings stat tiles now live (Upcoming / Completed / Hours computed from data)
Still hollow:
- [ ] **Dead-end buttons → real screens:** Community "+" compose, Discover 🔔 notifications,
      Profile ⚙️ settings + account rows, Cancel booking, Forgot password
- [x] **Instructor experience finalized** — every button works: Quick Actions (Add availability →
      persists days to SwiftData, Edit profile → persists bio/rate/specialties, Message students →
      Messages tab, View earnings → Profile/Earnings via InstructorRouter), Messages compose →
      NewMessageSheet, Profile settings → Edit Profile + Notifications (@AppStorage) sheets.
      Accept/Decline already functional. All 4 new screens verified rendering real data.
- [ ] Comment threads (posts show counts but no comment sheet); write-a-review flow
- [ ] Map-based search + LocationService (Info.plist already declares location permission)
- [ ] Real login/validation (email+password currently accepts anything)
- [x] **Data layer: SwiftData caching** (Phase A, verified) — models are `@Model`, two-config
      `ModelContainer` (local `Reference` for instructors + `UserData` for posts/bookings), idempotent
      JSON seeding, `MockDataStore` now a facade over `ModelContext`. See `CLOUDKIT-PLAN.md`.
- [x] **CloudKit scaffolding** (Phase B, gated) — `Flowe-CloudKit.entitlements`, a `CloudKit` build
      config with `CLOUDKIT_ENABLED` + `.private` container (compiles); flip on with a paid account.
- [x] **Ownership prep** (Phase C) — `ownerID` on `FeedPost`/`Booking`, Apple user id captured to
      Keychain in `AppSession`, credential-state validated on launch.
- [ ] Turn CloudKit live (needs paid Apple Developer account + `iCloud.com.flowepilates.app` container)

## Phase 10 — Infra  ⬜
- [ ] Unit tests (models, MockDataStore, filtering), UI smoke tests
- [ ] CI (build + test)

## Phase 11 — Booking delivery (end-to-end)  ✅
The booking loop previously did not connect the two parties: `Booking` lived in the CloudKit
**private** database, so a student's booking synced only to that student's own devices and the
instructor never received it. The instructor dashboard filtered local bookings by `legacyId`, which
could never match a booking made on another device.

- [x] **`BookingService`** — bookings exchanged over the CloudKit **public** database as raw
      `CKRecord`. Two record types (`SessionBooking` written by the student, `SessionDecision`
      written by the instructor) so the default `_creator`-write security is sufficient and no
      world-writable record type is needed. See `BOOKING-SYSTEM.md`.
- [x] **Status merge** — pending until the instructor responds; a student cancellation always wins.
      A sync never downgrades a local decision whose write hasn't landed yet.
- [x] **Delivery retry** — `pendingUpload` / `pendingDecision` mark writes that didn't reach the
      server; `flushPendingWrites()` retries them at the start of every sync. An undelivered booking
      shows "Not sent yet" rather than falsely claiming success.
- [x] **Instructor side is live** — dashboard REQUESTS section + calendar requests/schedule now read
      real incoming bookings; Accept/Decline publishes a decision (previously local-only state that
      did nothing). `CalendarSession`/`BookingRequest` placeholder models deleted.
- [x] **Student side** — Cancel button wired (was a no-op) with confirmation; pull-to-refresh on
      Bookings, Dashboard and Calendar.
- [x] **No payment in-app** — confirmation reads "Request sent!" and shows only the session fee
      marked "Paid directly to your instructor". The `serviceFee` constant and the fabricated
      service-fee/total rows were removed, since Flowe collects nothing on sessions this release.
- [x] **Tests** — `BookingFlowUITests` covers the full request flow, pending-not-confirmed, the
      absence of a service fee, cancellation, and both instructor empty states.

Not done (deliberate, documented in `BOOKING-SYSTEM.md`):
- [ ] Push notifications — an instructor learns of a request on next open/refresh. `aps-environment`
      is already entitled; a `CKQuerySubscription` on `SessionBooking` is the natural next step.
- [ ] Booking records are readable by any authenticated app user (public DB). Display name only,
      no email — but this should move server-side before scaling past a pilot.
- [ ] No double-booking check: two students can request the same slot.

## Phase 12 — Messaging (end-to-end)  ✅
Messaging was a UI shell: `MessageListView.inbox` was a hardcoded empty array nothing wrote to, and
`ConversationView.send()` appended to a local `@State` array, so messages vanished on dismiss and
were never delivered. Two deeper problems sat underneath:

- **Students had no Messages tab at all** — messaging needs two reachable sides.
- **Conversation partners were modelled as `Instructor`.** A student's counterpart is an instructor,
  but an instructor's counterpart is a *student*, who has no listing — so the instructor inbox could
  never have worked regardless of persistence.

- [x] **`Message` model + `MessagingService`** — messages exchanged over the CloudKit **public**
      database. Append-only and each written by its sender, so the default `_creator`-write role
      fits directly; no two-record split like bookings needed. See `BOOKING-SYSTEM.md`.
- [x] **Deterministic threads** — `conversationID` is the two owner ids sorted and joined, so both
      devices derive the same thread without coordinating.
- [x] **`Counterpart` abstraction** replaces `Instructor` throughout the messaging UI, making the
      inbox role-agnostic and driven by real messages.
- [x] **Role-aware address book** — students write to instructors in the feed *plus any already
      booked* (so a lapsed-subscription instructor stays reachable); instructors write to students
      who have booked them.
- [x] **Student Messages tab** added (5 tabs — a deliberate divergence from the 4-tab Figma mockup,
      since the feature is unusable without an entry point). Both roles show an unread badge.
- [x] **Delivery retry + unread state** — `pendingUpload` retried on sync, "Sending…" until
      delivered; `isRead` is recipient-local, clears when a thread is opened.
- [x] **Seed fix** — seeded instructors had no `ownerID`, so they could not be booked or messaged.
      Every real listing is keyed by its owner, so the fixture was unrealistic.
- [x] **Tests** — `MessagingUITests` covers tab access for both roles, both empty states, the
      role-aware compose lists, sending, persistence across leaving a thread, and send-button state.

Not done (documented in `BOOKING-SYSTEM.md`):
- [ ] Push notifications — messages arrive on open, pull-to-refresh, or opening a thread.
- [ ] Message bodies are readable by any authenticated app user (public DB). This is the most
      sensitive data in the app and the strongest reason to move server-side before scaling.
- [ ] No typing indicators, delivery/read receipts across users, or attachments.
