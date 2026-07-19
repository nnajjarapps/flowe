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
