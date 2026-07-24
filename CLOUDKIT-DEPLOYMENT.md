# CloudKit deployment runbook

Everything Flowe's **public** database needs, in one place, so a deploy is mechanical rather than
archaeological. This is the operator's checklist; the *why* behind each record type lives in
`BOOKING-SYSTEM.md`. Where the two disagree, this file is derived directly from the service code and
wins.

> **Read this first — the failure mode is silence.** A missing Queryable index does not raise an
> error. The query returns zero rows and the screen renders its empty state. "No bookings", "no
> events", "no messages" almost always means *a field isn't indexed*, not *a bug in the app*. There
> is no error to see. This is why the deploy has to be complete, not approximate.

Container: **`iCloud.com.flowepilates.app`** · Console: <https://icloud.developer.apple.com/>

---

## How CloudKit schema actually reaches devices

Three things are true and easy to conflate:

1. **Record types and fields auto-create in _Development_.** The first time the signed app saves a
   record of a new type (against a real iCloud account), CloudKit creates the type and its fields in
   the **Development** environment. So you do *not* have to hand-type every field below — running the
   app once populates most of them. What you *do* have to add by hand are the **indexes** and the
   **security-role and subscription exceptions**; none of those are inferred from a save.

2. **Nothing auto-creates in _Production_.** Development and Production are separate schemas. TestFlight
   and the App Store use **Production**. Until you **Deploy Schema Changes to Production**, a shipped
   build talks to an empty schema and every query returns nothing.

3. **Indexes are never inferred.** A field can exist and hold data yet be unqueryable. Every
   **Queryable**/**Sortable** in the tables below is a manual step (Console → the record type →
   **Indexes**).

**The deploy, start to finish:**

1. Build and run the **signed** app on a device or simulator with a real iCloud account signed in
   (an unsigned build traps at launch — CloudKit needs the entitlement). Exercise each feature once
   (create a listing, send a booking, post, host an event…) so Development gains the record types and
   fields.
2. In the Console, **Development** environment, add every index in the tables below, set the two
   security exceptions (§ Security), and confirm **Subscriptions permitted** on the five types in
   § Push subscriptions.
3. Verify in Development (§ Verifying).
4. **Deploy Schema Changes to Production.**
5. Re-verify against a Production/TestFlight build.

Any field a table lists that the app hasn't happened to write yet (e.g. an optional one) must be
**added by hand** in the Console before deploying — auto-create only covers fields an actual save has
carried.

---

## Record types at a glance

| Record type | Written by | recordName | Push? |
|---|---|---|---|
| `InstructorListing` | instructor | `== ownerID` | — |
| `SessionBooking` | student | server-minted | ✅ |
| `SessionDecision` | instructor | `decision-<bookingID>` | ✅ |
| `ChatMessage` | either | server-minted | ✅ |
| `SessionReview` | student | `review-<bookingID>` | ✅ |
| `CommunityPost` | either | server-minted | — |
| `CommunityLike` | student | `like-<postID>-<readerID>` | — |
| `CommunityComment` | either | server-minted | ✅ |
| `CommunityEvent` | instructor | `event-<localID>` | — |
| `EventRegistration` | student | `reg-<eventID>-<studentID>` | — |
| `ContentReport` | either | server-minted | — |

Type key: **Bool → Int(64)** (CKRecord has no boolean; `0`/`1`). **String List** = the CKRecord list
type. An **Asset** field is a `CKAsset` (uploaded blob) and is never indexed.

---

## 1. `InstructorListing`

The Discover catalog. `recordName == ownerID`, so an instructor edits only their own — no
`organizerID`-style field needed to scope writes.

| Field | Type | Index |
|---|---|---|
| `name` | String | — |
| `city` | String | — |
| `bio` | String | — |
| `price` | Int(64) | — |
| `yearsExp` | Int(64) | — |
| `specialties` | String List | — |
| `sessionTypes` | String List | — |
| `available` | String List | — |
| `hours` | String List | — |
| `paymentMethods` | String List | — |
| `cert` | String | — |
| `img` | String | — |
| `photo` | Asset | — |
| `certPhoto` | Asset | — |
| `rating` | Double | — |
| `reviews` | Int(64) | — |
| `latitude` | Double | — |
| `longitude` | Double | — |
| `visibility` | Int(64) | **Queryable + Sortable** |
| `updatedAt` | Date/Time | **Queryable** |

Only `visibility` and `updatedAt` are indexed — the feed query is `visibility > 0` sorted by
`visibility`. Everything else is read off an already-fetched record. `latitude`/`longitude` are
deliberately unindexed (see `BOOKING-SYSTEM.md § Location`).

---

## 2. `SessionBooking`

| Field | Type | Index |
|---|---|---|
| `instructorID` | String | **Queryable** |
| `studentID` | String | **Queryable** |
| `studentName` | String | — |
| `date` | String | — |
| `time` | String | — |
| `type` | String | — |
| `duration` | String | — |
| `cancelled` | Int(64) | — |
| `createdAt` | Date/Time | **Sortable** |

Push: an instructor is notified of a new request (and of a cancellation, which is an *update* to the
same record). The subscription predicates on `instructorID`, already Queryable above. → **enable
Subscriptions permitted.**

---

## 3. `SessionDecision`

Written by the instructor to accept/decline; `recordName == decision-<bookingID>` so a second
response updates one row.

| Field | Type | Index |
|---|---|---|
| `bookingID` | String | **Queryable** |
| `studentID` | String | **Queryable** |
| `confirmed` | Int(64) | **Queryable** |
| `respondedAt` | Date/Time | — |

> **Correction vs. earlier docs.** `studentID` and an indexed `confirmed` are **required** and were
> missing/unindexed in the per-subsystem table. The student's accept/decline push subscribes on
> `studentID == me AND confirmed == 1` (and `== 0`); a query-subscription predicate needs **every**
> field it references indexed. Omit either and accept/decline notifications silently never fire.

Push: two subscriptions (accept, decline) split on `confirmed`, addressed by `studentID`. → **enable
Subscriptions permitted.**

---

## 4. `ChatMessage`

| Field | Type | Index |
|---|---|---|
| `conversationID` | String | **Queryable** |
| `senderID` | String | **Queryable** |
| `recipientID` | String | **Queryable** |
| `senderName` | String | — |
| `recipientName` | String | — |
| `text` | String | — |
| `sentAt` | Date/Time | **Queryable + Sortable** |

The inbox is assembled from `senderID ==` **and** `recipientID ==` (CloudKit predicates have no
`OR`); a thread opens on `conversationID ==`. Push subscribes on `recipientID`. → **enable
Subscriptions permitted.**

---

## 5. `SessionReview`

`recordName == review-<bookingID>` — one review per completed session, resubmit updates it.

| Field | Type | Index |
|---|---|---|
| `bookingID` | String | — |
| `instructorID` | String | **Queryable** |
| `studentID` | String | **Queryable** |
| `studentName` | String | — |
| `rating` | Int(64) | — |
| `text` | String | — |
| `createdAt` | Date/Time | **Queryable + Sortable** |

Push: an instructor is notified of a new review (creation only). Subscribes on `instructorID`. →
**enable Subscriptions permitted.**

---

## 6. `CommunityPost`

| Field | Type | Index |
|---|---|---|
| `authorID` | String | **Queryable** |
| `authorName` | String | — |
| `type` | String | — |
| `instructorName` | String | — |
| `text` | String | — |
| `image` | Asset | — |
| `hasImage` | Int(64) | — |
| `createdAt` | Date/Time | **Queryable + Sortable** |

> The feed query is a **`TRUEPREDICATE`** sorted on `createdAt`, so the **record type itself must be
> Queryable**: the record type → **Indexes** → add a **`recordName` Queryable** index, in addition to
> the field indexes. Without it the whole feed silently returns nothing.

`authorID` is Queryable for the account-deletion sweep. There is **no `rating` field** — feed posts
carry no stars.

---

## 7. `CommunityLike`

`recordName == like-<postID>-<readerID>`. The like count *is* the number of these a post has.

| Field | Type | Index |
|---|---|---|
| `postID` | String | **Queryable** |
| `authorID` | String | **Queryable** |
| `createdAt` | Date/Time | — |

`postID` Queryable for `postID IN [...]` engagement fetches; `authorID` for the deletion sweep.

---

## 8. `CommunityComment`

| Field | Type | Index |
|---|---|---|
| `postID` | String | **Queryable** |
| `authorID` | String | **Queryable** |
| `replyTargetID` | String | **Queryable** |
| `authorName` | String | — |
| `text` | String | — |
| `createdAt` | Date/Time | **Queryable + Sortable** |

`postID` for the engagement fetch, `authorID` for deletion. Push: a post's author is notified of a
reply; the subscription predicates on `replyTargetID` (empty when the commenter is the author, so
self-replies never notify). → **enable Subscriptions permitted.**

---

## 9. `CommunityEvent`

`recordName == event-<localID>` (client-minted) so a re-publish overwrites rather than duplicating.

| Field | Type | Index |
|---|---|---|
| `organizerID` | String | **Queryable** |
| `organizerName` | String | — |
| `title` | String | — |
| `about` | String | — |
| `location` | String | — |
| `startsAt` | Date/Time | **Queryable + Sortable** |
| `durationMinutes` | Int(64) | — |
| `capacity` | Int(64) | — |
| `price` | Int(64) | — |
| `cancelled` | Int(64) | — |
| `highlight` | Asset | — |
| `hasHighlight` | Int(64) | — |
| `createdAt` | Date/Time | — |
| `updatedAt` | Date/Time | — |

The student list queries `startsAt >= (now − 6h)` sorted ascending; an organizer's own list queries
`organizerID ==` sorted by `startsAt`. `price` absent = "not stated" (renders "—"), `0` = "Free".
No push (student-side event notifications were deliberately not built).

---

## 10. `EventRegistration`

`recordName == reg-<eventID>-<studentID>`. The attendee count *is* the number of these an event has.

| Field | Type | Index |
|---|---|---|
| `eventID` | String | **Queryable** |
| `studentID` | String | **Queryable** |
| `studentName` | String | — |
| `eventTitle` | String | — |
| `joinTargetID` | String | — |
| `createdAt` | Date/Time | — |

`eventID` for the `eventID IN [...]` attendance fetch, `studentID` for the deletion sweep.

> `joinTargetID` is written (the organizer's id, empty when they join their own event) but **no
> subscription consumes it yet** — an "someone registered for your event" push is not built. Do
> **not** enable Subscriptions permitted here, and do not index `joinTargetID`, until that push
> ships. (This corrects an aspirational note in an earlier doc.)

---

## 11. `ContentReport`

| Field | Type | Index |
|---|---|---|
| `reportedID` | String | **Queryable** |
| `reportedName` | String | — |
| `contentType` | String | **Queryable** |
| `contentID` | String | — |
| `reason` | String | — |
| `details` | String | — |
| `snapshot` | String | — |
| `reporterID` | String | — |
| `createdAt` | Date/Time | **Queryable + Sortable** |

The app only ever *writes* reports; you read them in the Console, which is what the indexes serve.
**Security exception below — this is the one type that must not be world-readable.**

---

## Push subscriptions

Enable **Subscriptions permitted** (the record type → **Subscriptions**) on exactly these five, and
nowhere else. Each needs its predicate field(s) Queryable — already covered in the tables above.

| Record type | Subscription predicate field(s) | Notified |
|---|---|---|
| `SessionBooking` | `instructorID` | instructor — new request / cancellation |
| `SessionDecision` | `studentID`, `confirmed` | student — accepted / declined |
| `ChatMessage` | `recipientID` | either — new message |
| `SessionReview` | `instructorID` | instructor — new review |
| `CommunityComment` | `replyTargetID` | author — reply to their post |

Subscriptions are created **per device, per iCloud account**, on sign-in — so a push only reaches a
device that has signed in at least once *since* the subscriptions were deployed. Also confirm the
app target's **Push Notifications** capability and `aps-environment` (Development for dev/TestFlight
sandbox, Production for the App Store) — these are in the entitlements, not here.

---

## Security roles

**Every record type uses the default `_world` read / `_creator` write — with one exception:**

- **`ContentReport` must have `_world` read DISABLED** (creator-only read and write). A report names
  its reporter; a world-readable report would let anyone see who reported whom, and let a reported
  user find their reporter. This is the single most important security setting in the schema. Set it
  in both Development and Production.

`_creator`-write is load-bearing everywhere else: it is *why* a like/registration/decision is a
separate record instead of a counter (a student cannot write the instructor's record), and *why*
author-only delete works. Do not widen any type to world-writable.

---

## Verifying (before and after the Production deploy)

Silence is the failure mode, so verify positively — see data cross a device boundary, don't just
confirm the app "doesn't error":

- [ ] Two accounts / two devices. Instructor A publishes a listing → it appears in student B's
      Discover. (Catches `InstructorListing.visibility` index + `_world` read.)
- [ ] B requests a booking → it appears on A's dashboard, and A gets a push. (`SessionBooking`
      indexes + subscription.)
- [ ] A accepts → B sees "Confirmed" and gets a push. (`SessionDecision` `studentID`+`confirmed`
      indexes — the corrected ones.)
- [ ] B messages A → arrives + push. A replies → arrives + push. (`ChatMessage`.)
- [ ] B posts to Community with a photo → visible to A; A comments → B gets a push. (`CommunityPost`
      `recordName` Queryable, `CommunityComment` subscription.)
- [ ] A (subscribed) hosts an event → appears in B's Events tab with the highlight photo; B joins →
      spots-left decrements on both. (`CommunityEvent` `startsAt` index, `EventRegistration`.)
- [ ] B reports A's content → the report appears in the Console and **B's identity is not readable
      by A**. (`ContentReport` security exception.)
- [ ] Delete B's account from Settings → B's own bookings/messages/posts/registrations are gone from
      the Console; reviews *about* others and others' likes on B's posts remain. (Sweep predicates.)

If any step shows an empty screen, the cause is almost certainly a missing index on the field that
step queries — cross-reference the table above before touching code.

---

## Quick checklist

- [ ] Signed app run once against a real iCloud account; each feature exercised (Development gains
      the types/fields)
- [ ] All **Queryable**/**Sortable** indexes from §§1–11 added in Development
- [ ] `CommunityPost` record type has a **`recordName` Queryable** index (the `TRUEPREDICATE` feed)
- [ ] **Subscriptions permitted** on the five types in § Push subscriptions — and *not* on
      `EventRegistration`
- [ ] `ContentReport` **`_world` read DISABLED**; all other types left at the default role
- [ ] Verified in Development (§ Verifying)
- [ ] **Deploy Schema Changes to Production**
- [ ] Re-verified against a Production / TestFlight build
