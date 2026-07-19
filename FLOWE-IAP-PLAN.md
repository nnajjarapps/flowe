# Flowe Instructor IAP + Public Catalog + Feed Gating — Design

> Flowe's first revenue model. Instructor subscriptions gate feed visibility. Produced by a design
> workflow grounded in the code. Companion to PROGRESS.md.

## Revenue model
One App Store subscription **group** (`flowe_instructor_visibility`), two levels, one active at a time:
- **Flowe Visible** — `com.flowepilates.app.visible.monthly`, **$9.99/mo**, **1-month free trial** (intro offer) → listing appears in the student feed.
- **Flowe Boost** — `com.flowepilates.app.boost.monthly`, **$29.99/mo** → includes Visible, ranked higher / featured. No intro offer.

Digital in-app service → **Apple IAP is mandatory** (Guideline 3.1.1); Stripe is prohibited here. Apple takes 15–30%.

## Architecture
- **StoreKit 2** `SubscriptionService` (@MainActor @Observable): `tier` (visible/boost), `isVisible`/`isBoosted`, `purchase()`, `restore()`, `Transaction.currentEntitlements` + `Transaction.updates` listener.
- **`Flowe.storekit`** local config → full simulator testing, no App Store Connect needed.
- **PaywallView** ("Get discovered") — two tiers via `product.displayPrice`, trial terms, auto-renew disclosure, Restore, Terms/Privacy links (App Review requirements).
- **Feed gating** — `Instructor.visibilityRaw` (0 none / 1 visible / 2 boosted) + `visibilityVerifiedAt`; store exposes `visibleInstructors` (gated + Boost-first ranking) + `featuredInstructor`; 7-day TTL backstop. Replaces the old `price > 0` check.
- **Public catalog** — `CatalogService` over `CKContainer.publicCloudDatabase`, record type `InstructorListing` (recordName == ownerID). Instructors publish their listing + visibility to the public DB; students query visible listings and cache them into the local store the feed reads. (SwiftData can't mirror a public DB, so this is raw CloudKit.)

## Phases
- **A — buildable/testable NOW** (no ASC, no money): StoreKit service + `.storekit` + Paywall + visibility fields + feed gating + wiring. Verify in the simulator with the StoreKit config + Transaction Manager.
- **B — public catalog** (CloudKit public DB): cross-device instructor listings. Needs real devices + iCloud.
- **C — App Store Connect + sandbox + submit**: create the products/prices/trial, banking/tax, sandbox tester.

## AI builds vs you do
- **AI:** all client code, the `.storekit` test config, PaywallView, gating, catalog sync code.
- **You (App Store Connect):** create the subscription group + 2 products (matching the ids above), set $9.99 + $29.99 prices, add the 1-month free trial on Visible, complete Paid Apps agreement + tax/banking, create a sandbox tester, set CloudKit public-DB security roles.
