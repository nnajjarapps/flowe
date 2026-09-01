# 1.1 release runbook

Written 2026-09-01 at the end of the migration session, while the context was fresh. Follow in order — later steps assume earlier ones are done.

**State at time of writing:** messaging migration verified working on two real devices against dev. Production untouched, still serving 1.0. Both repos pushed. Two open client bugs (below). Version already bumped to **1.1.0 (53)**.

Background: `flowe_vault/nodes/system/flowe-messaging-migration.md`, `flowe-storage-split-rule.md`, `flowe-dm-key-reinstall-race.md`.

---

## Step 1 — The empty-bubble bug

**Symptom:** after "delete for everyone", the message renders as a blank bubble on BOTH devices instead of "You deleted this message" / "This message was deleted". Survives a force-quit, so it is not a rendering-refresh issue.

**Not a data bug.** The server is correct: the row is kept with `deleted=1` and `length(text)=0`. The ciphertext really is destroyed. This is cosmetic — but it looks broken.

Temporary `#if DEBUG` logs are already in place:
- `MessagingService.fetch` → `[DM] raw:` (the wire JSON) and `[DM] DECODE FAILED:`
- `MockDataStore.merge` → `[DM] merge id=… wire.deleted=… localFound=… local.deleted=… textlen=…`

Run from Xcode, open the conversation, read the console. Then:

| What you see | What it means | Fix |
|---|---|---|
| `[DM] DECODE FAILED` | the WHOLE payload fails to decode, so `fetch` returns `[]` and every merge is a silent no-op | fix `RemoteMessage`'s decoder — this would explain far more than this one bug |
| `"deleted":true` in raw, but `wire.deleted=false` | decoder is dropping the field | `RemoteMessage.init(from:)` — check the `CodingKeys` case and `decodeIfPresent(Bool.self…)`; SQLite returns 0/1, and if the Worker ever sends a number rather than a bool, decoding to `Bool` silently yields the default |
| both true, `localFound=false` | the flip can't find the local row — `remoteID` mismatch | the merge matches on `$0.remoteID == entry.id`; check what `upload()` stored |
| `deleted` absent from raw entirely | the deployed dev Worker is older than `src/index.js` | `npx wrangler deploy --env dev` |

**When fixed, REMOVE BOTH `[DM]` LOG BLOCKS.** They are marked `TEMPORARY (1.1 migration)`.

---

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

## Step 3 — Decide what happens to existing conversations

**This is a product decision, not a technical one, and it needs making before release.**

1.1 does not migrate messages. Conversations live in CloudKit `ChatMessage`; the new D1 store is empty. **On update, every existing conversation disappears from the app.** Nothing warns the user, and it reads as "the update deleted my messages."

### Option A — Don't migrate (recommended)
Accept the loss, say so in the release notes. Volume is tiny (a handful of testers plus your own thread), the text is E2E ciphertext nobody can read anyway, and it keeps the release simple.

### Option B — Migrate
Technically feasible: the ciphertext is unchanged by the move, so old rows can be copied into D1 as-is and still decrypt.

**But there is a hard constraint.** `POST /messages` forces `sender_id` to the authenticated caller — deliberately, so a message cannot be forged. So each device can only migrate the messages **it sent**. A thread is only whole once BOTH parties have updated and run the migration. Expect partial threads in the meantime.

Cost: a one-time client-side pass on first 1.1 launch, plus an idempotency guarantee so it cannot run twice. Disproportionate at this volume — but it is the honest option if losing history is unacceptable.

### Either way
Purge the CloudKit rows afterwards — see Step 4.1. Leaving them serves nobody and they stay world-readable.

---

## Step 4 — Release

Do these in order. Each has a verification gate; do not proceed past a failed one.

### 4.1 Purge the legacy CloudKit rows

CloudKit Console → **Production** → Records. For each type below, query and delete every record:

`SessionBooking` · `SessionDecision` · `SessionReview` · `EventRegistration` · `EventDecision` · `ChatMessage` · `ReadReceipt`

All are `GRANT READ TO "_world"` with the person-identifying field QUERYABLE, so **any surviving row is exactly the leak the migrations closed**. `SessionBooking` carries `studentName`; each `SessionReview` row is proof a named person completed a session with a named instructor.

The record TYPES cannot be deleted — Production schema is permanent — but empty types are harmless. It is the rows that matter.

⚠️ Check the **Production** environment specifically. Development is a separate container and tells you nothing.

### 4.2 Apply the message tables to production

```bash
cd /Users/nadinajjar/Projects/flowe-backend
npx wrangler d1 execute flowe-app --remote --yes --file=/tmp/msg-tables.sql
```

If that file is gone, take the `messages` + `read_receipts` blocks (and the three indexes) from `schema.sql`. Do **not** apply `schema.sql` wholesale to `flowe-app` — it still contains `DROP TABLE` lines that would wipe live credit grants.

**Gate:**
```bash
npx wrangler d1 execute flowe-app --remote --yes --command="SELECT name FROM sqlite_master WHERE type='table' AND name IN ('messages','read_receipts');"
```
Both must be listed. `profiles.dm_key_at` and `devices.notify_messages` are already present in production.

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

- Remove the temporary `[DM]` logs (Step 1)
- `flowe-backend` deploys TWICE now — `--env dev` and prod. Forgetting prod means production runs old code
- The dev environment only receives DEBUG builds. A TestFlight build talks to production, so it cannot exercise dev
- Take a durable copy of the production backup; the one from this session is in a temp scratchpad
