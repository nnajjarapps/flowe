# Booking system

How a session request gets from a student to an instructor, and back.

## Why not SwiftData/CloudKit private DB

SwiftData can only mirror CloudKit's **private** database (iOS 17 offers `.private` or `.none`).
Private means per-iCloud-account: a booking a student creates syncs to that student's own devices
and nowhere else. The instructor would never see it. Bookings therefore live in the **public**
database as raw `CKRecord`, the same approach `CatalogService` uses for instructor listings.

## Why two record types instead of one

Public-database security grants **write to `_creator`** and **read to `_world`**. A record can only
be modified by whoever created it, so an instructor cannot flip a `status` field on a record the
student wrote.

Rather than making the record type world-writable (any user could then edit anyone's bookings), a
booking is modelled as two append-only records, each written by the party that owns it:

| Record | Written by | Meaning |
|---|---|---|
| `SessionBooking` | student | the request, plus a `cancelled` flag the student can set |
| `SessionDecision` | instructor | accept/decline, referencing `bookingID` |

Effective status is merged client-side in `MockDataStore.status(for:decision:)`:

- student cancelled → **Cancelled** (always wins)
- no decision yet → **Pending**
- decision confirmed → **Confirmed**, else **Cancelled**

`SessionDecision.recordName` is `decision-<bookingID>`, so a second accept/decline updates the same
record instead of creating a duplicate, and the instructor stays its creator.

## Delivery guarantees

CloudKit errors are non-fatal, so a booking made offline (or before the schema is deployed) must not
be silently lost. `Booking.pendingUpload` / `pendingDecision` mark local state that hasn't reached
the server; `MockDataStore.flushPendingWrites()` retries them at the start of every sync. An
undelivered booking shows "Not sent yet" to the student rather than claiming success.

Sync runs on sign-in (`FlowApp`) and on pull-to-refresh in Bookings, Dashboard and Calendar.

## Payments

**This release takes no payment for sessions.** Students arrange payment with the instructor
directly, which is why the confirmation screen shows only the session fee marked "Paid directly to
your instructor" — no service fee, no total. The only money Flowe collects is the instructor
subscription (see `SubscriptionService`).

Dashboard "THIS WEEK" earnings are therefore a *projection* from accepted sessions, not a balance.

## CloudKit Dashboard setup (required before this works)

In [CloudKit Console](https://icloud.developer.apple.com/) → container `iCloud.com.flowepilates.app`
→ Schema, create both record types, then **Deploy Schema Changes to Production**.

### `SessionBooking`

| Field | Type | Index |
|---|---|---|
| `instructorID` | String | **Queryable** |
| `studentID` | String | **Queryable** |
| `studentName` | String | — |
| `date` | String | — |
| `time` | String | — |
| `type` | String | — |
| `duration` | String | — |
| `createdAt` | Date/Time | **Sortable** |
| `cancelled` | Int(64) | — |

### `SessionDecision`

| Field | Type | Index |
|---|---|---|
| `bookingID` | String | **Queryable** |
| `confirmed` | Int(64) | — |
| `respondedAt` | Date/Time | — |

Both need the default Security Role: `_world` read, `_creator` write. Queries fail without the
Queryable indexes, and the app will silently show no bookings.

## Known limitations

- **Public-DB readability.** Any authenticated app user can technically query booking records.
  Only a display name is stored — never an email or Apple user identifier beyond the opaque
  `ownerID` — but this is not private data, and it should move to a server-side API (or CKShare)
  before the user base grows beyond a pilot.
- **No push notifications.** An instructor learns about a request when they next open or refresh
  the app. `aps-environment` is already in the entitlements, so a `CKQuerySubscription` on
  `SessionBooking` is the natural next step.
- **No availability collision check.** Two students can request the same slot; the instructor
  resolves it by declining one.

---

# Messaging

Same constraint, same place: messages travel over the CloudKit **public** database, because the
private database is per-account and a message written by one user would never reach the other.

Unlike bookings, no two-record split is needed. Messages are append-only and each one is written by
its sender, so the default `_creator`-write role already fits — a participant only ever creates
their own messages and never edits the other side's.

## Threads

`conversationID` is the two participants' owner ids sorted and joined with `~`, so both devices
derive the same thread id without coordinating (`Message.conversationID(_:_:)`).

CloudKit query predicates do **not** support `OR`, so the inbox is assembled from two equality
queries — messages I sent and messages I received — rather than one compound query. Opening a
thread uses a single `conversationID ==` query so it refreshes without a full sync.

## Counterparts

A conversation's other party is a `Counterpart` (owner id + display name), deliberately **not** an
`Instructor`: a student's counterpart is an instructor, but an instructor's counterpart is a
student, who has no listing. The old inbox modelled every partner as an `Instructor`, which is why
it could never have worked on the instructor side.

Who you can start a thread with (`MockDataStore.addressBook(asInstructor:)`):

- **student** → instructors in the feed, plus any already booked, so an instructor who has since
  gone hidden (lapsed subscription) stays reachable
- **instructor** → students who have booked them

Unread state (`Message.isRead`) is recipient-local and never round-trips to the sender; it drives
the inbox dot and the tab badge, and clears when the thread is opened.

## CloudKit Dashboard setup

### `ChatMessage`

| Field | Type | Index |
|---|---|---|
| `conversationID` | String | **Queryable** |
| `senderID` | String | **Queryable** |
| `senderName` | String | — |
| `recipientID` | String | **Queryable** |
| `recipientName` | String | — |
| `text` | String | — |
| `sentAt` | Date/Time | **Queryable, Sortable** |

Default security role (`_world` read, `_creator` write). As with bookings, the queries silently
return nothing if the indexes are missing.

## Known limitations

- **No push notifications** — messages arrive on open, pull-to-refresh, or when a thread is opened.
- **No delivery/read receipts across users.** A message shows "Sending…" until it reaches the
  server; `isRead` is local to the recipient.
- **Public-DB readability.** Message bodies are readable by any authenticated app user. This is the
  most sensitive data in the app and is the strongest reason to move to a server-side API before
  going beyond a pilot.

---

# Account deletion

App Store Review Guideline 5.1.1(v) requires an in-app way to delete the account. `DeleteAccountView`
(reachable from Settings for both roles) drives `MockDataStore.deleteAccount()`, which sweeps the
public database via `AccountDeletionService`, wipes the local SwiftData store, and signs out.

## What gets swept

Only `_creator`-owned records can go — the public database grants write to whoever created a record.

| Record | Found by |
|---|---|
| `ChatMessage` | `senderID == ownerID` |
| `SessionBooking` | `studentID == ownerID` |
| `SessionDecision` | `decision-<bookingID>` for every booking where `instructorID == ownerID` |
| `InstructorListing` | `recordName == ownerID` (carries the profile photo as a `CKAsset`) |

`SessionDecision` carries no instructor id, so it can't be queried directly; its recordName is
derived from the booking it answers, which is why the sweep goes through the instructor's incoming
bookings. Decisions never written simply don't exist, and a missing record (`unknownItem`) counts as
success — the goal state is "gone".

The id sweep follows query cursors rather than trusting one page, so an account past the 400-record
page limit is still fully erased.

**Messages the other party sent are not deleted.** They are owned by their sender and the public
database won't let anyone else remove them. The departing user's own text is gone; the counterpart's
remains on their side.

## Failure is not partial

If any query or delete fails (offline, signed out of iCloud), `deleteAccount()` returns false and
wipes **nothing** locally — the user keeps their account and can retry. Signing someone out while
their records stay world-readable is precisely what 5.1.1(v) exists to prevent.

## Sign in with Apple

Token revocation is deliberately not attempted. The REST revoke endpoint needs a client-secret JWT
that cannot ship in a binary, and Flowe never retains the `authorizationCode` required to obtain a
refresh token — `AppSession.setAppleUserID` keeps only the stable user identifier.

Apple's [TN3194][tn3194] documents this exact case: delete the user's data, then direct them to
revoke the credential themselves. `DeleteAccountView`'s footer tells the user to open
Settings › their name › Sign in with Apple › Flowe › *Stop Using Apple ID*, which Apple states is
functionally equivalent to the revoke call. No backend is required.

If a backend ever exists, capture the `authorizationCode` at sign-in, exchange it for a refresh
token server-side, and revoke properly — that removes the manual step.

[tn3194]: https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple

---

# Identity

Every shared record — bookings, messages, reviews, listings, reports — is filed under an
**ownerID**. That id is the Sign in with Apple credential's user id, which Apple guarantees is
stable for this app across the user's devices and reinstalls, and which the Keychain preserves
locally (`AppSession.setAppleUserID`).

`ownerID` deliberately does **not** fall back to `currentUser.id`. That is a fresh `UUID` minted on
every sign-in, so using it as an owner id orphaned everything the user had the moment they signed
out and back in: their records stayed in the public database under an id nothing would look up
again. The bug was invisible on the Apple path (which always has a real id) and total on the email
path.

## Why email/password login was removed rather than repaired

It verified nothing. `handleLogin` checked the fields were non-empty and signed the user straight
in — there is no backend and no credential store, so there was nothing to check a password against.

That is why the orphaning couldn't be fixed by deriving a stable id from the email. With no password
check, a stable email-derived id means typing someone's address logs you in **as them** — and with
messages and bookings in a `_world`-readable database, that is a total account takeover. The fix
would have been strictly worse than the bug.

Sign in with Apple is the only credential this app can honestly issue without a server, so it is now
the only path. If a backend ever exists, real email auth can be added alongside it.

---

# Reviews

A review is anchored to a **booking**, not to an instructor. That is what makes it earned: only a
student who actually took a completed session can write one, and only one review per session.

The uniqueness is enforced by deriving the record name from the booking
(`review-<bookingID>`) rather than by a constraint — SwiftData can't express `@Attribute(.unique)`
on a CloudKit-backed model. Submitting twice updates the same record, and the student stays its
creator, so the default `_creator`-write role covers editing without a two-record split.

`MockDataStore.canReview(_:)` gates the affordance: status `completed`, a `remoteID` (a booking that
never reached the shared store was never a real session), a known instructor owner, and the booking
belonging to this user.

## Rating

An instructor's rating is **derived** from their reviews (`rating(for:)`), returning nil when there
are none — "no reviews yet" is a different thing from a 0.0 rating, and showing zero stars to a new
instructor is worse than showing none.

The derived average is written back onto the listing and republished, so the student feed can sort
and display the catalog without fetching every review for every instructor.

Before this, the profile's Reviews tab rendered seeded `FeedPost`s with `type == .review`. Those
were decorative — no student could have written them, and a brand-new instructor appeared to already
have reviews.

## CloudKit Dashboard setup

### `SessionReview`

| Field | Type | Index |
|---|---|---|
| `bookingID` | String | **Queryable** |
| `instructorID` | String | **Queryable** |
| `studentID` | String | **Queryable** |
| `studentName` | String | — |
| `rating` | Int64 | — |
| `text` | String | — |
| `createdAt` | Date/Time | **Queryable, Sortable** |

Default security role (`_world` read, `_creator` write) — reviews are public by design.

Review text is screened by `ContentFilter` on submission, the same as public listing text.

---

# Moderation (Guideline 1.2)

An app hosting user-generated content must filter it, let users report it, let users block abusive
accounts, and publish a contact route. Flowe's user content is **chat messages** and the
**instructor listing text** (name, city, bio, certification) — the latter broadcast to every
student. Community posts are seed-only today, with no compose UI, so they aren't user content yet;
when a composer lands it must be screened too.

## Blocking

`BlockedUser` lives in the `UserData` configuration, so it rides the CloudKit **private** database
and follows the user across their own devices. It is deliberately never published to a shared
store: a block is one person's decision, and "A blocked B" in a world-readable database leaks
exactly what a blocker wants kept quiet.

A block therefore hides the other person on the blocker's side — messages, listing, and any route
to start a new conversation (`conversations`, `thread(with:)`, `visibleInstructors`,
`addressBook`). Without a server there is nothing to stop the blocked person *writing*; their
messages still reach the public database and simply never surface. Reversible from
Settings › Safety › Blocked users.

## Reporting

`ReportService` writes a `ContentReport` to the public database, reviewed from the CloudKit
Dashboard. Reports carry a **snapshot** of the offending text because the original may be edited or
deleted before anyone looks at it.

### `ContentReport`

| Field | Type | Index |
|---|---|---|
| `reporterID` | String | — |
| `reportedID` | String | **Queryable** |
| `reportedName` | String | — |
| `contentType` | String | **Queryable** |
| `contentID` | String | — |
| `reason` | String | **Queryable** |
| `snapshot` | String | — |
| `details` | String | — |
| `createdAt` | Date/Time | **Queryable, Sortable** |

⚠️ **This record type must NOT use the default security role.** Unlike every other type here,
`_world` read has to be **disabled** — creator read/write only. A report names its reporter, and a
world-readable report would let the reported person discover who flagged them.

## Filtering

`ContentFilter` screens listing fields on save, rejecting slurs and sexual terms (matched on word
boundaries, so "Scunthorpe" and "class" are fine) and contact details (email / phone patterns,
which route students off-platform and are the usual scam shape).

It deliberately does **not** screen private messages. The guideline targets content posted to the
app, and silently screening one person's private correspondence with another is a different and
worse product. Abuse in DMs is handled by blocking and reporting.

This is a coarse first pass, not moderation — it will not stop anything adversarial. Real
moderation is a human reviewing the reports.

## Still outstanding for 1.2

- **No published contact route in-app.** The Support links point at `flowepilates.com/support`,
  which must actually exist and be monitored before submission.
- **No EULA acknowledgement at signup.** Apple expects UGC apps to bind users to terms with zero
  tolerance for objectionable content; today the EULA is only a link in Settings.
- **No review SLA.** Reports land in the Dashboard with nobody committed to reading them. Apple
  asks for "acting on reports within 24 hours" — that's an operational commitment, not code.

---

## Known limitations

- **No automated coverage of the remote sweep.** `AccountDeletionUITests` runs offline like every
  other UI test, so it exercises the local wipe and the sign-out but never `AccountDeletionService`.
  Verifying the CloudKit sweep needs a real iCloud account.
- **Community posts are local-only** and so are covered by the local wipe. When feed bodies move to
  the public database they must be added to the sweep.
