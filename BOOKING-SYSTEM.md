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
