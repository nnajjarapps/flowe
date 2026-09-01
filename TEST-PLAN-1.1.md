# 1.1 test plan — two devices

Everything in 1.1 that cannot be verified by a build. Work top to bottom; later phases assume earlier ones passed.

**Setup**
- Both devices run a **Debug build from Xcode**. A TestFlight/App Store build talks to PRODUCTION and will exercise none of this.
- Both signed in with Apple normally. Do **not** use `flowe.debugAppleUserID` — it makes `FloweBackendClient` no-op entirely.
- One instructor account, one student account.
- Backend: `flowe-backend-dev` → `flowe-app-dev`. Production is untouched throughout.

Handy: `D() { npx wrangler d1 execute flowe-app-dev --remote --yes --command="$1"; }` run from `flowe-backend`.

---

## Phase A — Sign-in and identity

| # | Do | Expect | Verify |
|---|---|---|---|
| A1 | Sign in on **instructor** | reaches the dashboard | `SELECT owner_id, dm_key_at FROM profiles;` → row exists, **`dm_key_at` NOT NULL** |
| A2 | Sign in on **student** | reaches Discover | same query → **two** rows, both with `dm_key_at` |
| A3 | — | — | `SELECT owner_id, apns_token IS NOT NULL, notify_messages FROM devices;` → two rows, tokens set, `notify_messages = 1` |

`dm_key_at` on **both** is the fix from `2be4ad8`. If either is NULL, stop — that is the bug returning.

---

## Phase B — Messaging

| # | Do | Expect | Verify |
|---|---|---|---|
| B1 | Student → instructor: send a message | appears immediately | `SELECT sender_id, substr(text,1,8), deleted FROM messages;` → text starts **`enc.v1.`** |
| B2 | — | **instructor gets a push banner** | the banner shows the **student's name**, not "Someone" |
| B3 | Instructor opens the thread | message readable | `SELECT reader_id FROM read_receipts;` → instructor's id |
| B4 | Student's side | shows **"Seen"** | — |
| B5 | Instructor → student: reply | arrives + push | `SELECT COUNT(*) FROM messages;` → 2 |

B2 is the least-proven path in the whole release — Worker → APNs — and the name comes from the extension's local cache, not the payload.

---

## Phase C — Deletion semantics

| # | Do | Expect | Verify |
|---|---|---|---|
| C1 | Sender: long-press own message → **Delete for everyone** | **both** sides show *"…deleted this message"*, not a blank bubble | `SELECT deleted, length(text) FROM messages;` → `1`, `0` |
| C2 | Either: long-press → **Delete for me** | gone on that device only, still on the other | `SELECT COUNT(*) FROM hidden_messages;` → 1 |
| C3 | Instructor: **delete the conversation** | thread gone from their inbox; **student's is intact** | own messages gone from `messages`; `hidden_messages` gains a row per received message |
| C4 | Student sends again | thread re-forms for the instructor | — |

C1's blank bubble was the bug we chased all session. It was environmental, but confirm it renders text now.

---

## Phase D — Cross-device sync (new in 1.1)

The point of this phase: **sign the SAME Apple ID into a second device** (or delete + reinstall) and confirm each item returns. Use the instructor account.

| # | Do on device 1 | Verify on device 2 |
|---|---|---|
| D1 | Write a **client note** for a student (injury/pregnancy/notes) | the note is there, fully readable | `SELECT student_id, length(sealed), flagged FROM client_notes;` → sealed is long, **unreadable ciphertext** |
| D2 | **Block** someone | they are blocked on device 2 too | `SELECT blocked_id FROM blocked_users;` |
| D3 | **Unblock** them | unblocked on device 2 | row gone; `SELECT * FROM block_windows;` → a window recorded |
| D4 | **Save** an instructor (heart) | appears in saved on device 2 | `SELECT instructor_id FROM saved_instructors;` |
| D5 | Change **language**, **coverage radius**, **Out-of-Studio hours** | all three match on device 2 | `SELECT app_settings FROM profiles;` → JSON with all four fields |

D1 matters most: open the note on device 2 and confirm the *content* is right. That proves the ciphertext round-tripped AND the key followed via iCloud Keychain.

---

## Phase E — Reinstall recovery

This is what the whole session was about. **Delete the app** (not just sign out) and reinstall from Xcode.

| # | Expect after reinstall + sign-in |
|---|---|
| E1 | **Message history is intact** — the DM key was NOT regenerated. If messages show 🔒 *Message unavailable*, the guard failed |
| E2 | Profile, role and subscription state return without re-onboarding |
| E3 | **A conversation deleted before the reinstall stays deleted** |
| E4 | Client notes, blocks, saved instructors and settings all return |
| E5 | `dm_key_at` unchanged — the marker is write-once, not re-stamped |

E1 is the bug that started this: a reinstall used to mint a new key over the not-yet-synced iCloud one and orphan every message permanently.

---

## Phase F — Regressions from earlier fixes

| # | Do | Expect |
|---|---|---|
| F1 | Send a message to yourself's counterpart, then check the **bell** | no *"X sent you a message"* for a message **you** sent |
| F2 | **Student cancels** a booking | the bell does **not** say the studio cancelled it |
| F3 | Someone **likes** your post | push **and** a bell row appear |
| F4 | Long-press a message → any dialog → confirm | the action **actually happens** (this was a silent no-op) |
| F5 | Subscribe to Visible or Boost | plan updates on the **first** tap, with the celebration |
| F6 | Block/report menu on a renamed user | shows their **current** name |
| F7 | A thread with an unreadable message | smart replies do **not** suggest *"Sorry, I'm having a technical issue"* |

---

## Phase G — iCloud full (optional, needs a full account)

| # | Do | Expect |
|---|---|---|
| G1 | Sign in on a device whose iCloud storage is full | banner: *"iCloud storage is full"* with **Resume** |
| G2 | Use the app normally | **everything saves and stays saved** — edits must not revert |
| G3 | Free space, tap Resume, relaunch | banner gone, sync resumes |

Hard to stage deliberately, but G2 is the promise: Flowe works fully without iCloud space.

---

## Phase H — Notification preferences (new: enforced server-side)

The "Messages" toggle used to work by simply not registering a CloudKit subscription. That lever is gone — the server decides now, so the toggle is only real if `devices.notify_messages` actually changes.

| # | Do | Verify |
|---|---|---|
| H1 | Instructor: Settings → turn **Messages notifications OFF** | `SELECT notify_messages FROM devices;` → `0` for that owner |
| H2 | Student sends a message | it **arrives in the app**, but **no banner** on the instructor's phone |
| H3 | Turn it back **ON**, student sends again | `notify_messages` → `1`, and the banner returns |

H2 is the point: delivery and notification are now separate concerns. A silenced toggle must not silence the message itself.

---

## Phase I — Blocking × messaging

Blocks moved to the backend tonight, and they interact with message delivery. Both matter.

| # | Do | Expect |
|---|---|---|
| I1 | Instructor blocks the student | `SELECT blocked_id FROM blocked_users;` → one row |
| I2 | Student sends a message | it reaches `messages` in D1 (the sender is not told they are blocked) but **never appears** on the instructor's device, and **no push** |
| I3 | Instructor unblocks | `blocked_users` row gone; `SELECT * FROM block_windows;` → a window with sensible start/end |
| I4 | — | messages the student sent **while blocked** stay hidden; only NEW ones appear |

I4 is the block window doing its job. It is also the piece that used to live only in UserDefaults, so it silently stopped working on a new device.

---

## Phase J — Account deletion (now spans two stores and 20 tables)

`DELETE /me` grew a lot tonight. A partial deletion is a legal problem, not just a bug.

| # | Do | Verify |
|---|---|---|
| J1 | On a **throwaway** account, Settings → Delete account | every table returns 0 rows for that owner |
| J2 | — | CloudKit public records for that owner are gone (Console → Records) |
| J3 | Sign in again with the same Apple ID | treated as a **new** account: no old bookings, notes, blocks or messages |

One query covers J1:
```sql
SELECT (SELECT COUNT(*) FROM profiles WHERE owner_id=:id)
     + (SELECT COUNT(*) FROM devices WHERE owner_id=:id)
     + (SELECT COUNT(*) FROM client_notes WHERE owner_id=:id)
     + (SELECT COUNT(*) FROM blocked_users WHERE owner_id=:id)
     + (SELECT COUNT(*) FROM block_windows WHERE owner_id=:id)
     + (SELECT COUNT(*) FROM saved_instructors WHERE owner_id=:id)
     + (SELECT COUNT(*) FROM hidden_messages WHERE owner_id=:id)
     + (SELECT COUNT(*) FROM entitlements WHERE owner_id=:id)
     + (SELECT COUNT(*) FROM messages WHERE sender_id=:id OR recipient_id=:id) AS leftovers;
```
Must be **0**. J3 is the one that catches a purge that looked complete but was not.

⚠️ Use a throwaway Apple ID. This is irreversible.

---

## Phase K — Guest mode

Tonight added `ensureSessionSilently()` calls to paths that run at launch. A guest has no session and no `currentUserID`, and must stay owner-less.

| # | Do | Expect |
|---|---|---|
| K1 | Launch **without signing in**, browse Discover, open a profile | works; no crash, no auth prompt |
| K2 | — | **no new rows anywhere** — `profiles`, `devices`, `messages` unchanged |
| K3 | Try to book / message / post | prompted to sign in, and still nothing written |

K2 is the real assertion: a guest must leave no trace server-side.

---

## Phase L — Booking regression

Bookings were untouched by design, but `save()` and `Date(msEpoch:)` changed app-wide, so they are worth one pass.

| # | Do | Expect |
|---|---|---|
| L1 | Student books a session | row in `bookings`; instructor gets the request **and a push** |
| L2 | Instructor confirms | student sees confirmed **and a push** |
| L3 | **Student cancels** | instructor is notified — and the student's own bell does **NOT** say the studio cancelled it (the `2c84f8f` fix) |
| L4 | Instructor cancels | student notified |

L3 is the regression guard for a bug fixed this session.

---

## If something fails

Live Worker logs, run from `flowe-backend`:
```bash
npx wrangler tail --env dev --format pretty
```
(`timeout` does not exist on macOS — do not wrap it.)

Then check whether the request arrived at all. No request = the app is not talking to dev (wrong build, or a silent `hasSession` skip). A 4xx = authorization. A 200 with wrong data = the client.
