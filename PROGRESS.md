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
      ⚠️ Also add the `photo` field (type **Asset**, no index) for uploaded profile photos, and
      `hours` (type **String List**, no index) for per-day bookable hours — without it a student's
      device falls back to the full time slate and can request an hour the instructor doesn't teach —
      and `yearsExp` (type **Int(64)**, no index).
      Full field table in `BOOKING-SYSTEM.md` → *Instructor catalog*.
- [x] **Stable identity / Apple-only sign-in**: `ownerID` no longer falls back to `currentUser.id`,
      a fresh UUID per sign-in that orphaned every booking, message and review on logout. Email
      login verified nothing (non-empty check, no credential store), so a stable email-derived id
      would have meant impersonation, not a fix — the unauthenticated form was removed and Sign in
      with Apple is now the only path. See "Identity" in BOOKING-SYSTEM.md.
- [x] **Instructor Analytics & Earnings tabs made real**: both were empty-state stubs. Analytics
      now derives sessions / students / repeat-students / acceptance-rate / rating from real incoming
      bookings and reviews, and charts sessions by type (a real dimension — bookings carry no
      timestamp, so there is deliberately no fabricated monthly time series). Earnings shows
      collected (completed × rate) vs projected (confirmed × rate) with a by-type breakdown, and is
      explicit that Flowe doesn't process payments. Dashboard rating now derives from reviews too, so
      it agrees with the profile. A seeded instructor gets a sample workspace (incoming bookings +
      reviews, owner `local-user`) so these tabs render populated in previews/tests; the shipping app
      seeds nothing. Covered by `ReviewsUITests` (analytics/earnings/reviews populated paths).
- [x] **Real reviews**: anchored to a completed booking (`review-<bookingID>` in the public DB, so
      one review per session and resubmitting updates). Instructor rating is *derived* from them —
      nil until the first review, rather than a fabricated 0.0 — and republished onto the listing so
      the feed can sort without fetching every review. Replaces the seeded `FeedPost` rows the
      Reviews tab used to render. Covered by `ReviewsUITests` (10 tests).
      ⚠️ CloudKit Dashboard: add `SessionReview` with `bookingID`/`instructorID`/`studentID`/
      `createdAt` **queryable** (`createdAt` sortable), default `_world` read / `_creator` write.
- [x] **Moderation (Guideline 1.2)**: block (local, private-DB synced, reversible from Settings ›
      Safety), report (`ContentReport` in the public DB, reviewed from the Dashboard), and a content
      filter on public listing text. Covered by `ModerationUITests` (11 tests).
      ⚠️ CloudKit Dashboard: add `ContentReport` with `reportedID`/`contentType`/`reason`/`createdAt`
      **queryable** (`createdAt` sortable) and — unlike every other type — **`_world` read DISABLED**,
      creator-only, so a report can't expose who filed it.
      ⚠️ Still needed before submission: a live, monitored support URL; an EULA acknowledgement at
      signup; and a commitment to action reports within 24h.
- [x] **Full listing editor**: photo (PhotosPicker → downscaled JPEG → `CKAsset`), name, city, bio,
      rate, years of experience, certification (self-declared text, labelled unverified), specialties
      and session types. Profile surfaces a "Finish your profile" nudge listing what's still blank.
      Covered by `InstructorProfileEditingUITests` (12 tests).
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

## Phase 13 — Community: photo feed, no mock data  ✅
The feed shipped five seeded posts from `posts.json` — invented authors, stock Unsplash portraits,
hand-written like and comment counts — which rendered as if they were the community. Alongside them
the model carried fields only those rows ever set: `userImg`/`instImg` (Unsplash ids), `time` (a
display string real posts derived from `createdAt` anyway) and `rating`, which the design had
already ruled out ("feed posts carry no star rating"). All of it is gone, along with `posts.json`.

- [x] **Nothing is seeded**, in previews or UI tests. Every post is one a real person wrote, and the
      empty state is what an empty feed honestly looks like.
- [x] **Photos** — one per post, `PhotosPicker` → downscaled to 1200px by `ProfileImage.preparePost`
      → `CKAsset` on `CommunityPost`. A photo alone is a post; so is a caption alone.
- [x] **The feed query no longer downloads assets.** `desiredKeys` covers metadata only, and photos
      come from a separate `fetchImages` pass — newest first, 24 per sync, cached once fetched.
      Without this a pull-to-refresh pulled up to 100 photos, most never scrolled to. A `hasImage`
      flag distinguishes "no photo" from "photo not fetched yet"; the row reserves space for the
      second.
- [x] **Instagram-shaped rows** — full-bleed photo, actions beneath it, inflected like count
      (`^[n like](inflect: true)`, so never "1 likes"), author name run into the caption,
      "View n comments", timestamp. Double-tap the photo to like, one-way so a mistimed tap can't
      remove a like. A caption-only post sets its text larger and carries the row on its own.
- [x] **Fixed in passing:** a post written in a preview/UI-test build stayed under "Posting…"
      forever — `addPost` returned before the upload with `pendingUpload` still set. Previously
      masked because the only posts in those builds were seeded ones.
- [x] **Tests** — `CommunityUITests` (10) covers both empty states, the composer's photo picker,
      caption-or-photo gating, posting, persistence across tabs, the like count appearing only once
      someone has liked, and an author getting Delete rather than Report.
      ⚠️ CloudKit Dashboard: add `image` (**Asset**) and `hasImage` (**Int(64)**) to `CommunityPost`.
      There is no `rating` field.
- [ ] Photo screening. `ContentFilter` reads text and cannot inspect an image, so an attached photo
      is only moderated reactively, via report.
- [ ] One photo per post — no carousel, video, cropping or filters.

## Phase 14 — Community events  ✅
Instructors host events; students browse and join them. Community becomes segmented — the existing
post feed and a new Events sub-tab. Same public-DB shape as the feed: a `CommunityEvent` CKRecord
read by everyone, an `EventRegistration` CKRecord written by each student who joins, with SwiftData
`@Model`s in `UserData` as the offline cache. Full rationale in `BOOKING-SYSTEM.md § Events`.

- [x] **`CommunityEvent` + `EventService`** — event bodies over the public DB as raw `CKRecord`;
      client-minted `localID` → deterministic recordName `event-<localID>` so a re-publish overwrites
      one record instead of forking a workshop and splitting its roster. Editable (fetch-then-mutate
      upsert + one `serverRecordChanged` retry); `cancelled` field, so a typo is an edit not a
      cancel-everyone.
- [x] **A registration is a record, not a counter** — `reg-<eventID>-<studentID>`, created by the
      joiner and deleted on leave; the attendee count is how many an event has. Creator-write makes a
      counter on the event record impossible — same reasoning as `CommunityLike`.
- [x] **Oversubscription handled honestly** — the shared pure `EventService.admitted(_:capacity:)`
      resolves admission by server-assigned `creationDate` seniority, so both racers compute the same
      set and exactly one withdraws; the loser is told plainly and their registration released.
- [x] **No in-app payment** — price is displayed through `AppSettings.money(_:)` and settled with the
      instructor directly. Hosting is gated on the instructor subscription (the only money Flowe takes);
      a lapsed organizer's *existing* events stay visible.
- [x] **Highlight photo** — `CKAsset`, downscaled by `ProfileImage.preparePost`, excluded from the list
      query and fetched in a bounded second pass (12/sync); `hasHighlight` distinguishes "no photo" from
      "not fetched yet".
- [x] **Visually-led UI** — segmented Community host, a hero event card (16:9 highlight band, date
      medallion straddling the photo/body seam, scrim, four-way photo branch), a Fraunces-over-photo
      detail hero, a StatTile trio, scoped greying for full/ended/cancelled (photo band + price only,
      title stays full-strength). Fullness read from one place, `event.status`.
- [x] **Instructor creation** — a "Host an event" Dashboard quick action (no fifth tab, no reindexing)
      → `ComposeEventSheet`, gated behind the subscription paywall; a "YOUR EVENTS" section manages them.
- [x] **Moderation** — `ReportedContent.communityEvent`; the detail's ellipsis menu reports the event
      (text is screened at compose via `ContentFilter`; the photo is not, which is why it's reportable).
- [x] **Localization** — es/fr/ar authored by hand for every new key, including plural variations for
      counted nouns (`^[%lld spot]`, `^[%lld person]`) across all six Arabic categories; the catalog was
      diffed unit-by-unit against HEAD to prove no existing translation was dropped.
- [x] **Tests** — `EventsUITests` covers the segmented sub-tab, the events empty state (no CTA), the
      compose affordance being scoped to Feed, that a student is never offered creation while an
      instructor is, and the subscription gate in front of the composer.

      ⚠️ CloudKit Dashboard: create `CommunityEvent` (index `organizerID` Queryable, `startsAt`
      Queryable+Sortable) and `EventRegistration` (index `eventID`/`studentID`/`joinTargetID` Queryable,
      **Subscriptions permitted**), then **Deploy Schema Changes to Production** — until then every event
      query returns nothing and every publish fails silently.

Not done (deliberate, documented in `BOOKING-SYSTEM.md`):
- [ ] No in-app payment — no StoreKit, no fee, no total; price is display-only.
- [ ] No waitlist; no recurring events; no multi-photo, crop/filters or map/geo (`location` is a plain
      String).
- [ ] No server-side transactional capacity — oversubscription-by-one is an accepted, documented race.
- [ ] No student-side "new event posted" push (would be a broadcast about every instructor's every
      event) and no cancellation push to students (the event record carries no student id) — a cancelled
      event instead stays badged "Cancelled" for anyone who joined.
- [ ] Orphaned registrations on a deleted/cancelled event stay in the public DB, owned by their creators.
- [ ] The attendee roster is world-readable (public DB); showing students only a count is a product
      choice, not a security boundary.
- [ ] The "someone joined your event" instructor push (severable) is **not** wired in this phase —
      `PushService` gains no `.events` topic yet. Everything the push needs on the record side
      (`EventRegistration.joinTargetID`, Subscriptions-permitted note) is in place for a follow-up.

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
