# ⚠️ Deferred production blocker: relationship-graph deanonymization

**Status: known, accepted for a trusted TestFlight pilot only. Must be fixed before any public /
App Store release. Recorded 2026-07-26 after a production-readiness audit.**

**What it is.** `SessionBooking`, `SessionReview` and `EventRegistration` live in the world-readable
public CloudKit database and carry both an opaque `studentID` and the student's plaintext
`studentName`, alongside the session date/time (and, for events, a place). Any authenticated app user
can query these by a harvested `instructorID`/`studentID`/`eventID` and reconstruct *who trains with
whom, when, and roughly where* — a named private individual's recurring whereabouts. See the
`Field / sensitive` tables under Booking, Reviews and Events below.

**Why it isn't fixed in code.** Two approaches were evaluated and both fail:

- *Encrypting or removing `studentName`* (the approach used for message bodies) does **not** close it:
  the record still carries the opaque `studentID`, and the world-readable `StudentProfile` (recordName
  == the student's id) maps that id straight back to a name. The identity re-links. Encryption works
  for message *content* because content is the payload; here the payload is *identity + relationship*,
  and identity must stay resolvable to the counterpart on a public database.

- *CKShare / private-shared zones* is structurally incompatible with the app's model. CKShare needs a
  per-pair invite→accept handshake and offers **no cross-zone query**, but Flowe's cross-user flows are
  all "query the public DB for records addressed to me, from strangers": an instructor discovers new
  bookings via `instructorID == me` (`BookingService.fetchForInstructor`), reviews are read the same
  way (by the instructor *and* by browsing students), the community feed is an open
  `startsAt >= now` query over every organizer's events (no CKShare analog exists), and attendee counts
  require every device to see the full registration set. On top of that the app identifies users by
  their Apple Sign-In id and never resolves a CloudKit `userRecordID`, so there is nothing to seed a
  share participant with. Forcing CKShare would mean rebuilding discovery, notifications and identity
  from scratch — and it still couldn't express the open feed.

**The actual fix** is a server-side API with per-user authorization (CloudKit Web Services with a
server-to-server key, or a small backend) — the standard way a marketplace keeps relational data both
private *and* queryable-to-the-right-party. That is a product/infrastructure decision, not a code
change, and is deferred until the app moves past the pilot.

**What *was* fixed:** direct message bodies are now end-to-end encrypted (see Messaging), which closed
the most sensitive leak — message *content* — because that one is amenable to encryption.

---

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
| `studentID` | String | **Queryable** |
| `confirmed` | Int(64) | **Queryable** |
| `respondedAt` | Date/Time | — |

`studentID` is denormalised onto the decision by `respond` so the student's accept/decline push can
address them; the subscription predicate is `studentID == me AND confirmed == 1` (and `== 0`), so
**both** `studentID` and `confirmed` must be Queryable — a query-subscription needs every field it
references indexed, or the notification silently never fires.

Both types need the default Security Role: `_world` read, `_creator` write. Queries fail without the
Queryable indexes, and the app will silently show no bookings. See `CLOUDKIT-DEPLOYMENT.md` for the
consolidated, deploy-ordered schema across every record type.

## Known limitations

- **Public-DB readability.** Any authenticated app user can technically query booking records.
  Only a display name is stored — never an email or Apple user identifier beyond the opaque
  `ownerID` — but this is not private data, and it should move to a server-side API (or CKShare)
  before the user base grows beyond a pilot.
- **No availability collision check.** Two students can request the same slot; the instructor
  resolves it by declining one.
- **Requests and answers now push** (see *Push notifications* below), but only to a device that has
  been signed in at least once since the subscriptions were deployed — a subscription is created
  per device, per iCloud account.

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
| `SessionReview` | `studentID == ownerID` (reviews written *about* the user stay — they belong to their authors) |
| `CommunityPost` | `authorID == ownerID` |
| `CommunityLike` | `authorID == ownerID` (including likes left on other people's posts) |
| `CommunityComment` | `authorID == ownerID` (including replies on other people's posts) |
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

**Push subscriptions go too**, once the record sweep has succeeded (`PushService.tearDown()`). A
`CKQuerySubscription` outlives the records it matches, so an account left with its subscriptions
would keep pushing other people's activity at a user who was told their account was gone. It is
sequenced behind the sweep on purpose: a deletion that failed leaves the account fully working,
notifications included.

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

# Community

Same constraint, same place. The feed used to be `FeedPost` rows in the `UserData` configuration,
which SwiftData mirrors to the CloudKit **private** database — per-iCloud-account, so a post one
user wrote could never be seen by another. A feed in the private database is not a community, it is
a diary. Post bodies now travel through the **public** database via `CommunityService`, and
`FeedPost` / `PostComment` are the offline cache, the same shape `Message` and `Review` take.

No two-record split is needed: posts are append-only and each is written by its author, so the
default `_creator`-write role already fits. The author can delete their own post because they are
its creator — that is the whole mechanism behind the Delete Post action.

## Why a like is a record, not a counter

A public-database record is writable only by whoever created it. A `likes` integer on the post could
therefore only ever be incremented by the post's **author**; every other reader's tap would be
rejected, and a client that bumped its local copy anyway would be showing a number nobody else could
see.

So a like *is* a record. `CommunityLike` has recordName `like-<postID>-<readerID>`, is created by the
reader who taps and deleted when they untap, and the count is simply how many of them a post has.
Every write stays inside the writer's own row.

The tradeoffs are accepted deliberately:

- one extra query per feed refresh (`postID IN [...]`, sliced at 50 ids, cursor-followed);
- the count is eventually consistent — it moves locally on tap and is replaced by the server's
  answer on the next sync;
- a failed like query returns `nil`, not `[]`, so an offline refresh keeps the last known counts
  instead of zeroing every post.

Comments work the same way (`CommunityComment`, one record per reply, creator-write).

## Photos, and why they arrive separately

A post can carry one photo, downscaled by `ProfileImage.preparePost` to a 1200px longest edge and
published as a `CKAsset`. A photo alone is a complete post; so is a caption alone.

The feed query **does not download them**. It asks for `postMetadataKeys` — every field except the
asset — because `desiredKeys: nil` would pull up to 100 photos on every pull-to-refresh, most of
them for rows the reader never scrolls to. Photos come afterwards, from `fetchImages`, by record id,
newest first, capped at 24 per sync and never re-fetched once cached.

That split is why `hasImage` exists as its own Int(64) field. Without it a row could not tell "this
post has no photo" from "this post has one I haven't fetched yet" — the first should render as text,
the second should reserve space and show a spinner, and the image pass needs to know which posts to
go and ask for. It is set from whether the asset actually staged, not from whether the composer had
an image, so a photo that failed to stage is honestly a post without one.

Nothing screens the image. `ContentFilter` reads text and cannot look at a picture, which is why an
attached photo is reportable from the feed like any other content — see *Moderation*.

## What is *not* shared

`FeedPost.saved` stays local. A bookmark is one reader's private shelf, and publishing it would tell
everyone what you kept.

## Nothing is seeded

The feed has no sample data, in previews or in UI tests. It used to ship five posts from
`posts.json` — invented authors, stock Unsplash portraits, hand-written like counts — which rendered
as though they were the community. Every post in the app is now one a real person wrote, and
`CommunityView`'s empty state is what a genuinely empty feed looks like.

## Who can post about whom

`MockDataStore.postableInstructors` limits check-ins and shout-outs to instructors the user has an
actual booking with, and the composer offers only `Tip` when that list is empty. Letting anyone name
anyone would make the feed a place to manufacture endorsements — the exact failure anchoring reviews
to bookings exists to prevent. Feed posts also carry **no star rating**; ratings belong to the
booking-anchored review system.

## Delivery guarantees

`FeedPost.pendingUpload` / `pendingDelete` / `pendingLike` mark local state that hasn't reached the
server, and `flushPendingCommunityWrites()` retries them at the start of every sync — a post written
offline shows "Posting…" rather than claiming success. A post pending deletion is hidden from the
feed immediately: a post that looks deleted while staying world-readable is the failure that matters.

Sync runs on opening the Community tab, on pull-to-refresh, and when a post's replies are opened.

`syncCommunity` also prunes cached posts their authors deleted, but only inside the window the
capped fetch actually covers (nothing older than the oldest row returned) and never for posts
younger than five minutes — CloudKit is eventually consistent, and a post that hasn't reached the
query index yet is not a deleted post.

## CloudKit Dashboard setup

### `CommunityPost`

| Field | Type | Index |
|---|---|---|
| `authorID` | String | **Queryable** |
| `authorName` | String | — |
| `type` | String | — |
| `instructorName` | String | — |
| `text` | String | — |
| `image` | Asset | — |
| `hasImage` | Int(64) | — |
| `createdAt` | Date/Time | **Queryable, Sortable** |

The feed query is a `TRUEPREDICATE` sorted on `createdAt`, so the record type itself must be
**Queryable** in the Dashboard (Record Type → Indexes → add `recordName` Queryable) in addition to
the field indexes above. Without that the feed silently returns nothing.

There is no `rating` field. Feed posts never carried a star rating in the shipping design — ratings
belong to the booking-anchored review system — and the one that existed on the record was written
only by the seeded sample posts, which no longer exist.

### `CommunityLike`

| Field | Type | Index |
|---|---|---|
| `postID` | String | **Queryable** |
| `authorID` | String | **Queryable** |
| `createdAt` | Date/Time | — |

### `CommunityComment`

| Field | Type | Index |
|---|---|---|
| `postID` | String | **Queryable** |
| `authorID` | String | **Queryable** |
| `authorName` | String | — |
| `text` | String | — |
| `createdAt` | Date/Time | **Queryable, Sortable** |

All three use the default security role (`_world` read, `_creator` write) — the feed is public by
design, and creator-write is what makes author-only delete work.

## Known limitations

- **Like counts are query-bounded.** Each slice follows its cursor, but a viral post plus a large
  feed still means a lot of like records fetched per refresh. A denormalised counter needs either a
  server or a world-writable record type; neither is acceptable here yet.
- **No pagination.** The feed is the 100 most recent posts, full stop.
- **Photos trickle in.** 24 per sync, so a feed with more than that shows spinners on the older rows
  until a later refresh. Proper lazy loading would fetch on the row appearing rather than in a
  batch; this is bounded and simple, not clever.
- **One photo per post.** No carousel, no video, no cropping or filters in the composer.
- **Photos are re-decoded on every render.** `PostRowView` builds a `UIImage` from the cached bytes
  inside `body`, so SwiftUI throws the decode away and redoes it on each evaluation. Bounded today
  by the 24-per-sync cap and lazy rows, but a decoded-image cache keyed by `remoteID` is the fix
  once the feed is long enough to scroll hard.
- **Orphaned engagement.** Deleting a post removes the post, and account deletion removes that
  user's own likes and comments, but likes and comments *other* people left on a deleted post stay
  in the public database, unreachable and owned by their creators. They are invisible — nothing
  queries a postID that no longer exists — but they are not cleaned up.
- **Public-DB readability**, as everywhere else here: post and comment bodies are readable by any
  authenticated app user.

---

# Events

Same constraint as the feed, one subsystem over. An instructor hosts a class, a workshop or a retreat
and every student must see it, so the event body travels through the **public** database via
`EventService` as a `CommunityEvent` record; the `CommunityEvent` `@Model` in the `UserData`
configuration is the offline cache, exactly like `FeedPost`. Events surface as a second sub-tab inside
the student Community screen; creation lives on the instructor Dashboard (a "Host an event" quick
action), because instructors have no Community tab of their own.

The one place events diverge from posts is identity. A post mints its recordName server-side and a
duplicate is survivable — two copies of a caption. An event must never split: two copies of one
workshop would split its attendee roster. So a `CommunityEvent` carries a client-minted `localID: UUID`
and its public recordName is `event-<localID>`, deterministic, so a killed publish (or a re-publish
from a second device that received the record through the private mirror) overwrites the *same* record
instead of forking it. Editing an event is a fetch-then-mutate upsert on that same name, with a single
`serverRecordChanged` retry; cancelling is the same write with `cancelled = 1`, so a typo'd date is an
edit, not a cancel-everyone.

## Why a registration is a record, not a counter

Identical reasoning to [Why a like is a record, not a counter](#why-a-like-is-a-record-not-a-counter):
a public record is writable only by its creator, so a student cannot decrement a `spotsLeft` or bump
an `attendees` integer on the instructor's event record — CloudKit rejects the write, and a client
that bumped a local copy would show a number nobody else can see.

So a registration *is* a record. `EventRegistration` has recordName `reg-<eventID>-<studentID>`, is
created by the student who joins and deleted when they leave, and the attendee count is simply how many
of them an event has. The deterministic name means joining twice overwrites one row rather than
inflating the count. When capacity is oversubscribed, admission is resolved client-side by seniority —
the pure `EventService.admitted(_:capacity:)` sorts registrations by the server-assigned
`creationDate` (unforgeable), tie-broken by studentID, and admits the first `capacity` of them. Both
racing devices compute the identical admitted set from the identical rows, so exactly one withdraws.

A failed registration query returns `nil`, not `[]`, so an offline refresh keeps the last known counts
instead of zeroing every event — the same rule the like count follows. And `attendees` is `Int?`: nil
means "never counted", which is not "nobody joined", so an uncounted event is never declared full.

## Payments: none, same as sessions

An event carries a price, and it is **displayed, not charged** — settled with the instructor directly,
exactly like a session fee (see [Payments](#payments)). Joining is a free in-app action; there is no
StoreKit, no service fee, no total. The only money Flowe collects remains the instructor subscription.
Hosting an event is gated on that subscription: an instructor students can't even find in Discover
shouldn't broadcast events to them. The gate is deliberately one-way — a *lapsed* organizer's existing
events stay visible, so a joined student never watches the class vanish.

The highlight photo follows the feed's asset pattern: downscaled by `ProfileImage.preparePost`, published
as a `CKAsset`, excluded from the list query's `desiredKeys`, and fetched in a separate bounded pass (12
per sync, fewer than the feed's 24 — an event hero is the whole row and the list is short). A `hasHighlight`
Int(64) field lets a row tell "no photo" from "photo not fetched yet", set from whether the asset actually
staged. The photo is unscreened (`ContentFilter` reads text, not pictures), which is why an event is
reportable.

## CloudKit Dashboard setup (required before events cross devices)

In [CloudKit Console](https://icloud.developer.apple.com/) → container `iCloud.com.flowepilates.app` →
Schema, create both record types, then **Deploy Schema Changes to Production**. Until then every event
query returns nothing and every publish fails — silently, because `EventService` swallows CloudKit
errors into neutral returns.

### `CommunityEvent`

| Field | Type | Index |
|---|---|---|
| `organizerID` | String | **Queryable** |
| `organizerName` | String | — |
| `title` | String | — |
| `about` | String | — |
| `location` | String | — |
| `startsAt` | Date/Time | **Queryable, Sortable** |
| `durationMinutes` | Int(64) | — |
| `capacity` | Int(64) | — |
| `price` | Int(64) | — |
| `cancelled` | Int(64) | — |
| `highlight` | Asset | — |
| `hasHighlight` | Int(64) | — |
| `createdAt` | Date/Time | — |
| `updatedAt` | Date/Time | — |

`organizerID` Queryable — the organizer's own-events query and the account-deletion sweep filter on it.
`startsAt` Queryable and Sortable — the student list query filters (`startsAt >= now − 6h`) and orders on
it. Nothing else is indexed because capacity/price/count logic is client-side over the fetched slice.

### `EventRegistration`

| Field | Type | Index |
|---|---|---|
| `eventID` | String | **Queryable** |
| `studentID` | String | **Queryable** |
| `studentName` | String | — |
| `joinTargetID` | String | — |
| `eventTitle` | String | — |
| `createdAt` | Date/Time | — |

Both ids are stored as fields even though the recordName encodes them: a recordName is not a queryable
field, and the count query is `eventID IN [...]` sliced at 50.

`joinTargetID` — the organizer's id, `""` when the organizer joins their own event — is written in
anticipation of a "someone joined your event" push, but **no subscription consumes it yet**: that push
was deliberately not built (see § Push notifications). So it stays **unindexed** and
`EventRegistration` needs **no** Subscriptions-permitted setting until that push actually ships. Index
the field and enable subscriptions at the same time as writing the push, not before.

Both types: default Security Role — `_world` read, `_creator` write. Creator-write is the whole
architecture: it is why an organizer can cancel only their own event, why a student can create/delete only
their own registration, and why a counter on the event record is impossible.

## Known limitations

- **No availability collision check — oversubscription by one.** There is no server and no transaction,
  so two students can both pass the client-side capacity check and both write a registration; CloudKit
  accepts both. What is guaranteed: both records are real and neither is lost; every device computes the
  same admitted set from the server-assigned `creationDate`; the outside student is told plainly ("This
  event filled up") and their registration withdrawn, usually within seconds, and always by the next
  sync. The window in which an oversubscribed event exists is bounded by how long the loser stays offline,
  and during it the organizer sees the overflow row marked "OVER CAPACITY". This is the exact shape of the
  session booking race above; it is an accepted, documented race, not a bug to be papered over with an
  invented server guarantee.
- **Orphaned registrations.** Cancelling or deleting an event does not reach into the registrations other
  students created against it; they stay in the public database, owned by their creators, unreachable
  (nothing queries a dead eventID). Same class as orphaned likes — invisible, not cleaned up.
- **No student cancellation push.** A `CKQuerySubscription` predicate can only test fields on the changed
  record, and the organizer-written event record carries no student id (there are N of them), so a
  cancellation cannot notify the joiners directly. Mitigated structurally: a cancelled event **stays in
  the list wearing a "Cancelled" badge for anyone who joined it**, so the student learns on next open.
- **The roster is world-readable, not private.** Students are shown only an attendee *count*; the
  organizer sees the names. But every `EventRegistration` is world-readable like everything in this
  container, so hiding the roster from students is a product choice, not a security boundary.
- **Public-DB readability**, as everywhere else: event bodies and registration fields are readable by any
  authenticated app user.

---

# Moderation (Guideline 1.2)

An app hosting user-generated content must filter it, let users report it, let users block abusive
accounts, and publish a contact route. Flowe's user content is **community posts and replies**,
**chat messages**, and the **instructor listing text** (name, city, bio, certification) — the first
and last broadcast to every student.

## Blocking

`BlockedUser` lives in the `UserData` configuration, so it rides the CloudKit **private** database
and follows the user across their own devices. It is deliberately never published to a shared
store: a block is one person's decision, and "A blocked B" in a world-readable database leaks
exactly what a blocker wants kept quiet.

A block therefore hides the other person on the blocker's side — messages, listing, community posts
and replies, and any route to start a new conversation (`conversations`, `thread(with:)`,
`visibleInstructors`, `addressBook`, `visiblePosts`, `comments(for:)`). Without a server there is
nothing to stop the blocked person *writing*; their posts and messages still reach the public
database and simply never surface. Reversible from Settings › Safety › Blocked users.

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
| `contentType` | String | **Queryable** — `message`, `instructorListing`, `communityPost`, `communityComment` |
| `contentID` | String | — |
| `reason` | String | **Queryable** |
| `snapshot` | String | — |
| `details` | String | — |
| `createdAt` | Date/Time | **Queryable, Sortable** |

⚠️ **This record type must NOT use the default security role.** Unlike every other type here,
`_world` read has to be **disabled** — creator read/write only. A report names its reporter, and a
world-readable report would let the reported person discover who flagged them.

## Filtering

`ContentFilter` screens listing fields on save, and community posts and replies on publish,
rejecting slurs and sexual terms (matched on word boundaries, so "Scunthorpe" and "class" are fine)
and contact details (email / phone patterns, which route students off-platform and are the usual
scam shape).

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
- **Community engagement outlives the post it was on.** Deleting a post doesn't cascade to the
  likes and comments other people left on it; they become unreachable rather than removed. See the
  Community section's limitations.

---

# Instructor catalog

An instructor's public listing. Written by its owner (`recordName == ownerID`, so the default
`_creator`-write role is sufficient), read by every student's device via `CatalogService`.

## CloudKit Dashboard setup

### `InstructorListing`

| Field | Type | Index |
|---|---|---|
| `name` | String | — |
| `city` | String | — |
| `bio` | String | — |
| `price` | Int(64) | — |
| `yearsExp` | Int(64) | — |
| `rating` | Double | — |
| `reviews` | Int(64) | — |
| `specialties` | String **List** | — |
| `sessionTypes` | String **List** | — |
| `available` | String **List** | — |
| `hours` | String **List** | — |
| `paymentMethods` | String **List** | — |
| `cert` | String | — |
| `img` | String | — |
| `photo` | Asset | — |
| `certPhoto` | Asset | — |
| `visibility` | Int(64) | **Queryable + Sortable** |
| `updatedAt` | Date/Time | **Queryable** |

Security role: `_world` read, `_creator` write.

Only `visibility` and `updatedAt` are indexed, because they are the only two the catalog query
filters or orders on. Everything else is read off a record already fetched.

### `available` and `hours` are one thing stored twice

`hours` carries one `"Mon|9:00 AM"` token per bookable slot; `available` is the day-level view of
the same data (`["Mon", "Wed"]`), kept in sync on save. Both are published because the feed reads
days while the booking sheet reads slots, and re-deriving one from the other on every card render
is work the writer can do once.

Neither is a nested type for the same reason: a `CKRecord` field stores a string list, not a
dictionary, and SwiftData's mirror won't carry one either.

### `students` is not published, and is not a real number

`Instructor.students` only ever comes from the seed JSON. No instructor can edit it, nothing derives
it from bookings, and it is not on the record — so it is `0` for every real listing, forever. The
booking sheet still renders it. Either derive it from distinct booking students or drop the stat;
publishing the field as-is would only make a fabricated number travel further.

**A missing `hours` field fails quietly and badly.** `Instructor.hours(on:)` falls back to the full
standard slate for a day that is in `available` but has no hours tokens. The invariant that makes
this safe: `AvailabilityView.save()` recomputes `available` from `daysWithHours` (the days that
actually carry tokens), so after any edit `available` lists *exactly* the days with hours. A day the
instructor explicitly CLOSED is therefore ABSENT from `available`, the fallback does not fire, and it
correctly reads closed — closing a day no longer silently reopens it with the full slate. The
full-slate fallback now applies ONLY to genuinely legacy listings: days set, `hours` never populated
(written before per-day hours existed). Those stay bookable until their owner opens the editor and
saves, which materializes the displayed slate into real tokens. This distinction rides the existing
wire fields — closed = absent from the `available` String List — so no new record field is needed.

---

# Lesson types

An instructor's lesson types used to be a flat `Instructor.sessionTypes: [String]` chosen from a
fixed four-item menu. They are now `LessonType` — rich objects the instructor **authors themselves**:
a free-form name, an optional highlight photo, a description, a duration, a group-size capacity, and
an optional price. There is no predefined menu; a type is an arbitrary row the instructor adds, edits,
reorders and deletes, exactly the way they author a `CommunityEvent`.

## Why a separate record type

A `LessonType` carries a photo, and a `CKAsset` cannot ride the listing's flat `sessionTypes` String
List. So each type is its own public CKRecord (`recordType "LessonType"`, `recordName
lessontype-<localID>` from a client-minted UUID → deterministic upsert), `_creator`-write keyed by
`ownerID` — the same shape as `CommunityEvent`. The photo follows the shared pipeline: excluded from
the list query's `desiredKeys`, fetched in a bounded second pass keyed by a `hasHighlight` flag, so
browsing an instructor never downloads photos for types the student won't look at.

## Capacity is group size, not fillable spots

A `LessonType.capacity` is the **maximum group size** — a static, descriptive attribute ("1-on-1",
"Up to 10") — **not** a live "spots left / fully booked" gauge. A Flowe booking is a 1:1 request, not
a scheduled shared instance that a type could fill, so there is no registration record, no attendee
query, and no `EventStatus`/`spotsLeft` analog. A spots-remaining number would be state nobody
counts — the same fabricated-data trap the rating ("New", never 0.0) and the events design already
refuse. The composer's own footer tells the instructor this outright.

## Migration is mandatory, and lossless

Existing listings, seed data, and past bookings all predate rich types, so both directions are
covered:

- **Reading** — `MockDataStore.lessonTypes(for:)` is a resolver: it returns the instructor's rich
  `LessonType` rows when they exist, and otherwise **synthesises** minimal ones from the listing's
  legacy `sessionTypes` strings. So a student viewing an instructor who hasn't migrated still sees
  their offers rendered as cards, just without photos/details.
- **Writing** — `migrateLessonTypesIfNeeded()` (run when the instructor opens Edit Profile) converts
  their own flat strings into editable `LessonType` rows, order preserved, idempotently (it no-ops once
  rich rows exist). `Booking.type` stays a plain string key resolved by name, so past bookings keep
  rendering.

## CloudKit Dashboard setup

### `LessonType`

| Field | Type | Index |
|---|---|---|
| `ownerID` | String | **Queryable** |
| `name` | String | — |
| `details` | String | — |
| `durationMinutes` | Int(64) | — |
| `capacity` | Int(64) | — |
| `price` | Int(64) | — |
| `order` | Int(64) | — |
| `highlight` | Asset | — |
| `hasHighlight` | Int(64) | — |
| `createdAt` | Date/Time | — |
| `updatedAt` | Date/Time | — |

Default security role: `_world` read, `_creator` write. `ownerID` is the only index — every read is
`ownerID == %@`. No subscription. Until this is deployed, lesson types don't cross devices and a
student sees only the legacy-string fallback.

## Known limitations

- **Price entry hardcodes "$".** The composer's price field prefixes a literal `$` while the
  instructor types (shared with `ComposeEventSheet`), so a non-dollar instructor sees the wrong symbol
  during entry — though the value renders correctly through `settings.money(_:)` everywhere it is
  displayed. Needs a shared currency-symbol helper, fixed in both composers at once.
- **No per-type availability or scheduling.** Capacity is descriptive; making group sessions actually
  fill would require scheduled shared instances (a separate, larger build).

---

# Location

"Near you" used to mean string equality on `Instructor.city`, so "Tel Aviv" and "Tel-Aviv" were
different places and nothing was ever actually near anything. Listings now carry an optional
coordinate, and the student's device measures the distance itself.

## Precision, and why it is the whole design

The public catalog is world-readable by every authenticated user of the app, and a large share of
Pilates instructors teach from their own home. A precise coordinate on a public listing is a
published home address.

So the coordinate is snapped to a **0.01° lattice** before it is ever stored or sent — roughly
1.1 km north–south, and 1.1 km × cos(latitude) east–west (≈0.94 km at Tel Aviv's 32°N). Snapping to
a *fixed lattice*, rather than rounding relative to the true point, means every address inside a cell
publishes the identical pair of numbers: the value names a neighbourhood and cannot be walked back
toward a street by collecting samples.

This is enforced by the type system rather than by discipline. `CoarseLocation` has no public
initializer that accepts an unrounded coordinate, `LocationService` never returns a precise fix to
any caller (it hands out distances and coarse points only), and `Instructor.setCoarseLocation(_:)` is
the only way coordinates reach the model. Values arriving *from* the catalog are re-snapped on ingest,
so a listing published at finer precision by a future or tampered client still resolves to a cell
centre on this client.

A **student's** location is never published anywhere, and by construction cannot be: no API in the
app returns it. `LocationService.distance(toLatitude:longitude:)` returns metres.

## Capture is deliberate

An instructor sets their area from Edit Profile, sees the exact published coordinates and the ~1 km
promise before saving, and can remove it in one tap. Nothing is captured in the background, and
`NSLocationWhenInUseUsageDescription` is the only authorization requested. Reverse geocoding (used to
label the area and to fill an empty `city`) runs on the *coarsened* point, so not even the geocoder
receives the exact one.

Denied or restricted permission is a first-class state, never an error: the Discover feed renders
unchanged, cards fall back to the free-text city, and the only difference is that no distances
appear.

## How distance composes with Boost

Boost is a paid placement, so the visibility tier is always the primary sort key. Distance reorders
*peers within a tier* — the nearest boosted instructor leads the boosted ones, the nearest visible
instructor leads the rest — and never lifts a free listing above a paid one.

Within a tier: measured distance ascending, then listings with **no** coordinates (they rank last in
their own tier, never out of the feed — most instructors have never set an area, and an unknown
distance is not a reason to stop existing), then rating, then `order`. With no fix, the sort is
skipped entirely and the existing Boost → rating → order applies.

Distances are displayed in **kilometres** everywhere, always prefixed "~", and anything under a
kilometre shows as "Under 1 km" — printing "0.3 km" from a value with ±0.8 km of designed-in error
would misrepresent how well we know where an instructor is.

## CloudKit Dashboard setup

### `InstructorListing` (added fields)

Two more fields on the record type defined under *Instructor catalog* above.

| Field | Type | Index |
|---|---|---|
| `latitude` | Double | — |
| `longitude` | Double | — |

Deliberately **not** indexed. Ranking happens on device over the ≤200 listings `fetchVisibleListings`
already returns, so Queryable buys nothing and Sortable is meaningless for a two-axis value. The
alternative — a CloudKit `Location`-typed field with a server-side `distanceToLocation` predicate —
was rejected for the same reason plus one: it would make the catalog probeable by repeated radius
queries, which is a shape worth not having even when the underlying values are already coarse.

Both fields are absent (not zero) on a listing with no area. Removing an area deletes the keys, and
`MockDataStore.apply(_:to:)` assigns nil unconditionally, so a withdrawal actually propagates to
other people's devices.

## Known limitations

- **No radius filter.** The feed sorts by distance but never hides anyone, because a "within 10 km"
  filter would have to either drop every instructor without coordinates or show them inside a radius
  they were never measured against. Sorting says the same thing without lying.
- **Nothing re-sorts when the student moves.** A single fix is taken when the feed appears (or when
  the button is tapped); there is no continuous updating, which is the right trade for battery and
  for a feed that shouldn't reshuffle underneath a tapping finger.
- **The section header still reads "NEAR YOU"** when browsing unfiltered without location. It is
  passed as a `%@` argument into `"%@ · %lld INSTRUCTORS"`, so unlike the rest of the screen it is
  not translated — a pre-existing wart in the same line, worth fixing together.

---

# Push notifications

Flowe has no server, so nothing can *send* a notification. What can is CloudKit: a
`CKQuerySubscription` is a standing query the user registers against the **public** database, and
CloudKit pushes when a record starts matching it. Every alert in the app is one of those, plus local
notifications for session reminders (a time is not another user's action, so it needs no server at
all). `Flowe/Data/PushService.swift` owns the whole pipeline; `FloweAppDelegate` in `FlowApp.swift`
is the UIKit entry point SwiftUI does not provide.

## What fires, and at whom

| Event | Record type | Predicate | Fires on | Recipient |
|---|---|---|---|---|
| Student requests a session | `SessionBooking` | `instructorID == me` | create | instructor |
| Student cancels | `SessionBooking` | `instructorID == me` | update | instructor |
| Instructor accepts | `SessionDecision` | `studentID == me AND confirmed == 1` | create + update | student |
| Instructor declines | `SessionDecision` | `studentID == me AND confirmed == 0` | create + update | student |
| New message | `ChatMessage` | `recipientID == me` | create | recipient |
| Reply on my post | `CommunityComment` | `replyTargetID == me` | create | post author |
| New review of me | `SessionReview` | `instructorID == me` | create | instructor |

Each predicate uses the same field the matching service already queries on — the constants live on
the services themselves (`BookingService.bookingRecipientField`, `MessagingService.recipientField`,
…) so a rename can't leave a subscription that silently never fires.

**Nobody is ever notified about their own action**, and it is structural rather than a filter:
every predicate names the *counterpart's* id, which is never the writer's. CloudKit does not suppress
a notification for the record's creator, so this could not be left to chance.

Cancellation is the one subscription that fires on update rather than create. It is sound because a
public-database record is writable only by its creator: the only person who can update a booking is
the student who made it, and the only update the app performs is `cancelled = 1`.

## Two fields exist purely so a subscription can address someone

A query subscription's predicate can only test fields on the record that changed. Two records did
not name their recipient at all, so two writers now denormalise it:

- `SessionDecision.studentID` — copied off the booking by `BookingService.respond`. Without it a
  student cannot be told their request was answered.
- `CommunityComment.replyTargetID` — the post's author, looked up by `CommunityService.addComment`,
  and deliberately **empty when the commenter is the author**. A pure-equality predicate then matches
  nobody, which is how replying to your own post stays silent without a `!=` clause.

## Alert text is localized on the receiving device

`CKNotificationInfo` carries `titleLocalizationKey` / `alertLocalizationKey` /
`alertLocalizationArgs`, never literal strings. The alert is composed on the **receiver's** device
from *their* copy of `Localizable.xcstrings`, so a Spanish user gets Spanish regardless of what
language the sender was running. A literal string would be frozen at write time and unfixable
without a server. The keys are the `push.*` entries in the catalog (en/ar/es/fr).

`alertLocalizationArgs` are **record field names**, not values — CloudKit substitutes the live field
contents into the receiver's translation. `studentName`, `senderName`, `text` and `authorName` are
therefore load-bearing: removing one from a record type breaks that alert's body.

## Subscription ids, idempotency, teardown

Ids are `flowe.<version>.<topic>.<event>.<ownerID>` — stable, and parsed front-to-back because an
Apple user id contains dots. Registration fetches the existing set and saves only ids that are
missing; an id that already exists is left alone. Re-saving would either error or, worse, produce a
second subscription and a second copy of every alert. Anything in the `flowe.` namespace that is not
in the desired set is deleted, which is what makes switching a toggle off actually stop the alerts.
The `<version>` component is bumped whenever a predicate changes, so a changed rule ships as a new
subscription and the old one is swept rather than surviving with an outdated predicate.

Subscriptions are torn down on **log out** (`FlowApp`) and on **account deletion**
(`AccountDeletionService`, after the record sweep succeeds). A deleted account that kept pushing
would be proof to the user that the deletion they were promised did not happen.

## CloudKit Dashboard setup (required before this works)

1. **Apple Developer portal** → Certificates, Identifiers & Profiles → the `com.flowepilates.app`
   App ID → enable **Push Notifications**. `aps-environment` is already in `project.yml`, but the
   capability has to exist on the identifier or the APNs registration is rejected at runtime.
2. **CloudKit Console** → container `iCloud.com.flowepilates.app` → Schema, add the two new fields:

   ### `SessionDecision` (added field)

   | Field | Type | Index |
   |---|---|---|
   | `studentID` | String | **Queryable** |

   ### `CommunityComment` (added field)

   | Field | Type | Index |
   |---|---|---|
   | `replyTargetID` | String | **Queryable** |

3. Every field a predicate tests must be **Queryable**, including the ones that already existed:
   `SessionBooking.instructorID`, `SessionDecision.confirmed`, `ChatMessage.recipientID`,
   `SessionReview.instructorID`. A missing index does not error — the subscription is accepted and
   then never fires, which is the hardest version of this to debug.
4. Per record type, check **Record Type → Subscriptions** is permitted for `SessionBooking`,
   `SessionDecision`, `ChatMessage`, `CommunityComment` and `SessionReview`. Some containers ship
   with subscriptions disabled on a type, and a save that is rejected for that reason is swallowed
   like every other CloudKit failure in Flowe.
5. **Deploy Schema Changes to Production.** Subscriptions registered against the development schema
   do not exist for a TestFlight or App Store build.

## Where permission is asked

Not on first launch. iOS asks exactly once, and a denial is effectively permanent, so the prompt is
held until the user actually has something to wait on: the moment their first booking or first
message appears — a request just sent, a request just received, or a first conversation. At that
point the prompt answers a question the user is already asking. `NotificationSettingsView` also
offers the prompt directly, and offers a route to iOS Settings once permission has been refused.

## Preferences are real

The five switches in `NotificationSettingsView` map to `notif.*` keys that `PushService` reads when
it computes the desired subscription set. Turning one off deletes the subscription; there is no
server that could filter a push after the fact, so client-side hiding would have been a lie.

Two switches were **deleted** rather than left decorative:

- **Payouts** — Flowe processes no session money whatsoever (see *Payments* above). There is no
  payout, so there can be no payout notification, and the toggle implied a capability the app does
  not have.
- **Product news & offers** — nothing in the app or the container can send a marketing push. There
  is no campaign mechanism behind it at all.

A **Community replies** switch was added, because that notification does exist. Their stored keys
(`notif.payouts`, `notif.marketing`) are removed from `UserDefaults` on launch.

## Session reminders are local

One hour before each confirmed session, scheduled with `UNCalendarNotificationTrigger` on the
device. `Booking.date` is language-neutral English with no year ("Mon, Jul 7", see `FloweWeek`) and
`Booking.time` comes from `FloweConstants.times`, so parsing is pinned to `en_US_POSIX` and the year
is recovered as the next occurrence of that month/day — correct because the booking flow only offers
days inside the coming week. Anything unparseable simply gets no reminder. Pending reminders are
cleared and rebuilt on every sync, so a cancelled session stops reminding and re-running can never
stack duplicates. Reminder bodies use `NSString.localizedUserNotificationString`, resolved at
delivery rather than at scheduling.

## When a push lands

Subscriptions set `shouldSendContentAvailable`, so the app is woken in the background as well as
alerted. The delegate decodes the subscription id back into a topic and runs the matching existing
sync (`syncBookings` / `syncMessages` / `syncCommunity` / `syncReviews`), so the data behind the
alert is already there when the user opens the app. A tap additionally records the topic, and the
tab views open the tab it belongs to.

`shouldBadge` is off everywhere: no server keeps a running unread total, so an app-icon badge could
only ever be wrong.

## Known limitations

- **A subscription is per device, per iCloud account.** A user who installs Flowe on a second phone
  gets subscriptions there on first sign-in; a device that never signs in never registers.
- **No deep link past the tab.** A tap opens Bookings, Messages, Community or the instructor's
  Reviews tab — not the specific thread, request or post.
- **Message previews are in the payload.** The alert body is the message text, which is the normal
  behaviour for a messaging app but does put message content on the lock screen. There is no
  server-side setting to turn previews off; iOS's own "Show Previews" control is the only lever.
- **Decision alerts carry no instructor name.** `SessionDecision` has no name field, and adding one
  would mean a second lookup on every accept; the alert says "your instructor" instead.
- **No cancellation from the instructor's side to notify.** An instructor declines rather than
  cancels, and a confirmed session has no instructor-side cancel path yet — when it gains one it
  needs its own subscription, because the decision record's update already carries the accept text.
- **A reminder is only scheduled inside an eight-day window.** `Booking.date` carries no year and
  nothing moves a stale `confirmed` booking to `completed`, so a session read months later would
  otherwise resolve to next year's same date and promise a reminder for something that already
  happened. Bookings are made inside the coming week, so the bound costs nothing real.

## Notification language: a known limitation

Remote alert text is composed **by iOS on the receiving device**, from the localization keys in
`CKNotificationInfo`. iOS resolves those against the app bundle's preferred localization — i.e. the
device language — and has no way to know about Flowe's in-app language override (`AppSettings.language`,
which reaches SwiftUI `Text` via `.environment(\.locale,)` and nothing else).

So a user whose device is English but who has set Flowe to Arabic sees an Arabic app and English
push alerts. This cannot be fixed from the app: influencing remote alert text requires a
Notification Service Extension that rewrites the payload before display. Local notifications
(session reminders) have the same shape today for consistency.

Worth doing if the in-app language picker turns out to be widely used. If most users simply run
their device in their own language — likely — the mismatch never appears.
