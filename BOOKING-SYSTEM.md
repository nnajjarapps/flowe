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

## Known limitations

- **No automated coverage of the remote sweep.** `AccountDeletionUITests` runs offline like every
  other UI test, so it exercises the local wipe and the sign-out but never `AccountDeletionService`.
  Verifying the CloudKit sweep needs a real iCloud account.
- **Community posts are local-only** and so are covered by the local wipe. When feed bodies move to
  the public database they must be added to the sweep.
