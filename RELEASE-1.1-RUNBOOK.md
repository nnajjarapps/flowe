# 1.1 release runbook

Written 2026-09-01 at the end of the migration session, while the context was fresh. Follow in order — later steps assume earlier ones are done.

**Biggest change since this file was written:** the private CloudKit mirror is RETIRED. Nothing writes
to the user's iCloud any more, so a full iCloud cannot break the app — which it did, twice, in ways
that looked like feature bugs. Local state now syncs from the backend keyed by the Apple ID, so it also
works on a device not signed into iCloud at all. **On first launch of 1.1 the local store starts empty
and repopulates from the backend** — expected, and the thing to watch during release verification.

**State (updated 2026-09-01):** messaging migration verified on two real devices against dev. Client notes, block list, block windows, saved instructors and app settings all moved to the backend — **nothing in the app now depends on the user having iCloud space**, and everything follows the signed-in Apple ID across devices. Production untouched, still serving 1.0. Both repos pushed. Version already **1.1.0 (53)**.

**One open bug** (Step 2) and **one product decision** (Step 3) remain before release.

Background: `flowe_vault/nodes/system/flowe-messaging-migration.md`, `flowe-storage-split-rule.md`, `flowe-dm-key-reinstall-race.md`.

---

## Step 1 — ~~The empty-bubble bug~~ RESOLVED (environmental)

**Not a messaging bug, and no code was at fault.** The test device's iCloud storage was full. SwiftData's CloudKit mirror then fails every export with `CKError 25 "Quota Exceeded"`, never initialises, and repeatedly calls `resetAfterError:` — and that reset discards committed local writes. `context.save()` succeeded; the mirror threw the change away afterwards.

Fixed in `8677488` + `0e912df`: the quota state is now detected, explained by a banner, and the private-DB mirror is DROPPED rather than left to fail, so the app keeps working. Two silent-error paths found on the way were also removed (`try? context.save()`, and a decode failure returning an empty inbox).

Then closed properly in `3426077` + `21eb79a` / `e88f736`: client notes, the block list, block windows, saved instructors and app settings all moved to the backend, so **nothing depends on the user having iCloud space**. See `flowe_vault/nodes/system/flowe-cross-device-sync.md`.

The temporary `[DM]` logs are gone. Nothing to do here.

## Step 2 — `activateMessaging()` not completing

**Symptom:** `profiles.dm_key_at` is NULL for both test accounts even though the DM key demonstrably exists (messages encrypt fine). The student has **no `profiles` row at all**.

**Why it matters:** `dm_key_at` is the environment-independent proof that an account has a keypair. Without it, `MessageCrypto.resolvedPrivateKey` falls back to the CloudKit `PublicKey` record — which is PER-CONTAINER, so a debug build on a fresh device looks in Development, finds nothing, mints, and destroys the production key it shares through the iCloud Keychain. **That is the hole this was meant to close, and it is still open.** Not a regression (1.0 behaves the same), but an unfulfilled fix.

**Already ruled out:** the Worker route and its SQL are correct and deployed — an isolated UPSERT with `dmKeyPublished:true` sets the column.

So `reportDMKeyPublished()` is never reached. It sits at the end of `MessageCrypto.activate()`:

```swift
myOwnerID = ownerID
guard let key = await resolvedPrivateKey(ownerID: ownerID) else { return }   // ← A
await directory.publish(ownerID: ownerID, publicKey: key.publicKey.rawRepresentation)  // ← B
await FloweBackendClient.shared.reportDMKeyPublished()                       // ← C
```

Corroborating clue: the student has no `profiles` row, so `setPresenceVisible` — the FIRST line of `activateMessaging()`, before `activate` is even called — did not run on that device either. That points upstream of `activate`, at `activateMessaging` or its caller.

**Diagnose by bisection.** Add four temporary prints: entry to `activateMessaging` (MockDataStore ~2014), entry to `activate`, between A and B, and between B and C. Run on the STUDENT device, which is the one that produced no profile row at all.

- nothing prints → `activateMessaging` is not being called; look at `FlowApp.swift:195` and its `authState` gate
- A returns nil → the key guard is in its WAIT state (see `flowe-dm-key-reinstall-race`); expected on a device whose Keychain has not synced, and it self-resolves after `keySyncGrace` (15 min)
- stops between B and C → `directory.publish` is hanging on CloudKit; make it non-blocking or time-boxed so a CloudKit stall cannot prevent the backend report
- reaches C but the column stays NULL → `hasSession` is false at that moment; reorder so the report happens after the session is established

---

## Step 3 — ~~Existing conversations~~ DECIDED: do not migrate

1.1 reads messages from D1; the CloudKit `ChatMessage` records stay where they are, unread. Every
existing conversation therefore disappears from the app on update.

**Decided 2026-09-01: accept it.** The entire user base is two people the developer knows personally
(plus the developer's own test accounts), so a migration — a one-time client pass, an idempotency
guarantee, and threads that stay half-empty until BOTH parties update — is disproportionate. Tell them
directly; no release note needed.

Purge the old `ChatMessage` and `ReadReceipt` rows in Step 4.1 while you are there. They are
world-readable and serve nobody once 1.1 ships.

**Revisit this if 1.1 ever slips far enough that real users accumulate first.** The reasoning is
entirely about volume, not about the data being unimportant — at a hundred users the answer flips, and
the migration is ~20 lines: for each local message I sent, POST it to `/messages`. The local SwiftData
cache is the source, not CloudKit, and deterministic ids make it idempotent.

## Step 4 — Release

Do these in order. Each has a verification gate; do not proceed past a failed one.

### 4.1 Purge the legacy CloudKit rows

CloudKit Console → **Production** → Records. For each type below, query and delete every record:

`SessionBooking` · `SessionDecision` · `SessionReview` · `EventRegistration` · `EventDecision` · `ChatMessage` · `ReadReceipt`

All are `GRANT READ TO "_world"` with the person-identifying field QUERYABLE, so **any surviving row is exactly the leak the migrations closed**. `SessionBooking` carries `studentName`; each `SessionReview` row is proof a named person completed a session with a named instructor.

The record TYPES cannot be deleted — Production schema is permanent — but empty types are harmless. It is the rows that matter.

⚠️ Check the **Production** environment specifically. Development is a separate container and tells you nothing.

### 4.2 Apply the schema to production

`flowe-app` is missing **6 tables and 1 column** relative to dev. This list was derived by diffing the two databases on 2026-09-01, not written from memory:

| Missing in production | From |
|---|---|
| `messages`, `read_receipts` | DM delivery moved off CloudKit |
| `client_notes`, `blocked_users` | moved off the CloudKit private mirror |
| `block_windows`, `saved_instructors` | moved off UserDefaults |
| `content_reports`, `removed_content` | moderation — reports queryable, takedown list |
| `saved_posts` | post bookmarks, moved off `FeedPost.saved` |
| `booking_local`, `message_read` | the last private-mirror state — attendance, No-Show fee, cover ledger, read state |
| `deleted_content` | author deletions, so they propagate as data not absence |
| `profiles.app_settings` (column) | language / coverage radius / OOS window |

**Twelve tables and one column**, re-derived from a live dev-vs-prod diff.

`devices.notify_messages` and `profiles.dm_key_at` are **already in production** — both were added schema-before-code.

```bash
cd /Users/nadinajjar/Projects/flowe-backend
npx wrangler d1 execute flowe-app --remote --yes --file=migrations/1.1-production.sql
```

Then the column, kept separate because SQLite's `ALTER TABLE` has no `IF NOT EXISTS`, so re-running the file above must never fail:

```bash
npx wrangler d1 execute flowe-app --remote --yes --command="ALTER TABLE profiles ADD COLUMN app_settings TEXT;"
```

Every statement in the migration file is additive and idempotent — it cannot touch existing data.

⚠️ Do **NOT** apply `schema.sql` wholesale to production instead. It still contains `DROP TABLE` statements that would wipe live credit grants.

**Gate — re-run the diff and expect no output:**
```bash
npx wrangler d1 execute flowe-app --remote --yes --command="SELECT name FROM sqlite_master WHERE type='table' AND name IN ('messages','read_receipts','client_notes','blocked_users','block_windows','saved_instructors','content_reports','removed_content','saved_posts','booking_local','message_read','deleted_content');"
```
All twelve must be listed, and `pragma_table_info('profiles')` must include `app_settings`.

### 4.2b CloudKit: make `likeTargetID` QUERYABLE in Production

**Confirmed by testing, not assumed.** Like notifications fire through a `CKQuerySubscription` whose
predicate filters on `CommunityLike.likeTargetID`, and a subscription predicate requires that field to
be **QUERYABLE**. A field CloudKit auto-creates from a record write is **not** indexed — so the like
records fine, the bell row appears, and **the push silently never fires**. That is exactly what
happened in dev until the schema was imported.

CloudKit Console → **Production** → Schema → import `CloudKit-dev-schema.ckdb`, or add the index on
`CommunityLike.likeTargetID` by hand. Then check **Subscriptions** for `flowe.v2.community.like.…`.

⚠️ Without this, likes notify nobody in production and nothing reports an error.

### 4.3 Deploy the production Worker

```bash
cd /Users/nadinajjar/Projects/flowe-backend && npx wrangler deploy
```

**Order matters:** tables BEFORE the Worker. Deploying first leaves routes selecting tables that do not exist.

This is additive — the 1.0 app never calls the message routes, so production behaviour does not change until the new app ships.

### 4.4 Archive and upload

Confirm 1.1.0 (53) survived into the build — this is what produced errors 90186/90062 last time:

```bash
plutil -extract CFBundleShortVersionString raw /Users/nadinajjar/Projects/flowe/Flowe/Info.plist
```

Then in Xcode: destination **Any iOS Device (arm64)** → Product → Archive → Distribute App → App Store Connect → Upload. Organizer re-signs for distribution; a Development-signed archive is normal and fine.

Then ASC → create 1.1.0, attach build 53, write What's New, submit.

### 4.5 After it is live

Watch for: messages not arriving (authz), "Someone" instead of names (profile cache — expected for a non-booker now that names are not stored), and silent notifications (push is the newest, least-proven path).

**Rollback:** the old databases `flowe-bookings` and `flowe-bookings-dev` are kept untouched. Point `wrangler.jsonc` back and redeploy. Do not delete them until 1.1 has been live for a while.

---

## Do not forget

- `flowe-backend` deploys TWICE now — `--env dev` and prod. Forgetting prod means production runs old code
- The dev environment only receives DEBUG builds. A TestFlight build talks to production, so it cannot exercise dev
- Take a durable copy of the production backup; the one from this session is in a temp scratchpad
- After release, re-run the dev-vs-prod schema diff — it is the cheapest way to catch a missed migration, and it is how the 6-table list in 4.2 was built
