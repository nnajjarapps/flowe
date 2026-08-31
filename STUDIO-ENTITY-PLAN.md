# Studio entity — implementation plan

**Status: PLAN ONLY. No code changed.** Drafted 2026-08-31. Nothing here ships before 1.0.1 is archived and the nine commits on `account-role-guard-and-deletion` are pushed.

Background: `flowe_vault/nodes/decision/flowe-studio-is-not-an-entity.md`.

---

## 1. The problem

A studio is not modelled. `Instructor.studioAddress` is a string plus a coordinate; there is no `Studio` type, no link between instructors at one business, and employment is free text (`Instructor.place // studio / employer`).

Consequences today:

- N instructors at one address = N map pins, N names, N Finance Centers, N subscriptions.
- Founding Studios Agreement §5.3 ("Flowe gives the Studio its own figures monthly") is satisfiable for an owner-operator and **not expressible** for a multi-instructor studio.
- `Opportunity.role` lets a studio advertise a job. Acceptance lands nowhere — the hiring funnel has no destination.

## 2. Shape

**Two account roles, one organisation.** `User.role` stays instructor/student. A studio never signs in; a person does. Studio is a container instructors belong to.

**The value is in the edge, not the entity.** The studio→instructor membership carries a type that decides the commercial layer:

| | Type | Admin | Sets price | Whose revenue | Whose client | Pays for visibility | On leaving, students |
|---|---|---|---|---|---|---|---|
| Studio owner | independent | yes | self | self | self | studio | — |
| Renter | independent | no | self | self | self | self | follow |
| Employee | employee | no | studio | studio | studio | studio | stay |

**Renter is collapsed into independent for now** (user decision, 2026-08-31). Owner and renter are commercially identical and differ only in the admin flag — one boolean, not a third type. This keeps the renter from administering the studio they rent from.

**Every existing account is already `independent`.** The type is a default, so employee support is purely additive and no current account changes behaviour.

### The dividing line

**Identity is always the instructor's** — profile, bio, certifications, Community presence, DMs. Portable; survives leaving.
**The commercial layer follows the edge** — price, revenue, client ownership, timetable, Discover placement.

Consequence worth keeping: an employee who leaves keeps their profile but loses Discover unless they subscribe themselves. The model produces the employee→paying-customer conversion without anyone engineering it.

## 3. How membership is created

**No onboarding toggle.** At signup there is no studio, so an edge type has no second end; self-declaring "employee" would let someone unilaterally opt into another party gaining rights over their revenue and clients; and instructors who teach some classes at a studio and some privately cannot answer it honestly.

Both types emerge from actions:

- **Create a studio → admin.** Nobody declares ownership; they either made one or did not.
- **Accept a studio's invite → employee.** The studio sets the type on the invite; the instructor's acceptance is the consent.
- **Accept a `.role` / `.apprenticeship` Opportunity → same edge.** This is where the existing hiring funnel finally lands.

**Membership is always granted by the studio, never self-claimed** — otherwise anyone lists themselves at a well-known studio.

### The studio is born from the first invite

No "Create studio" button. Most instructors are solo; a create button produces hundreds of one-member studios, each a duplicate Discover pin beside the instructor who already has one. **A one-member studio must not exist as a listing.**

The action is **Invite an instructor**. On the first invite, the inviter's existing `studioAddress` + coordinate are promoted into a new `Studio` record and they become admin. The studio name is captured at that moment — there is no `studioName` field anywhere today, and asking for it in onboarding would tax every solo instructor for nothing.

## 4. Data model

### 4.1 `Studio` — public CloudKit record type

Public because Discover queries it, exactly as it queries `InstructorListing`.

```
    RECORD TYPE Studio (
        "___createTime" TIMESTAMP,
        "___createdBy"  REFERENCE,
        "___etag"       STRING,
        "___modTime"    TIMESTAMP,
        "___modifiedBy" REFERENCE,
        "___recordID"   REFERENCE QUERYABLE,
        address         STRING QUERYABLE SEARCHABLE SORTABLE,
        adminIDs        LIST<STRING> QUERYABLE,
        bio             STRING,
        coverPhoto      ASSET,
        createdAt       TIMESTAMP QUERYABLE SORTABLE,
        latitude        DOUBLE QUERYABLE SORTABLE,
        logo            ASSET,
        longitude       DOUBLE QUERYABLE SORTABLE,
        memberCount     INT64 QUERYABLE SORTABLE,
        name            STRING QUERYABLE SEARCHABLE SORTABLE,
        GRANT WRITE TO "_creator",
        GRANT CREATE TO "_icloud",
        GRANT READ TO "_world"
    );
```

`memberCount` is denormalised so Discover can filter out one-member studios without a second query.

Per `CLAUDE.md`: this block goes into `CloudKit-dev-schema.ckdb` **in the same change as the code**, and must be **deployed to Production before release**. Production schema is additive-only and permanent — the field list above is the part to get right.

### 4.2 `Instructor` — one added field

```swift
var studioID: String?   // nil = independent, no studio
```

**Do not remove `studioAddress` / `latitude` / `longitude`.** Prod schema is permanent and older clients read them. Keep writing them; when `studioID` is set, the Studio's address wins at render time.

### 4.3 Membership — backend, not CloudKit

Membership is two-party state and needs a referee. CloudKit public records grant write to `_creator` only, so a studio-written invite cannot be flipped to accepted by the instructor without either a second record type or loosened permissions. `flowe-backend` already arbitrates profile, entitlement and credits.

```sql
CREATE TABLE studio_members (
  studio_id     TEXT NOT NULL,
  instructor_id TEXT NOT NULL,
  type          INTEGER NOT NULL DEFAULT 0,  -- 0 independent, 1 employee
  is_admin      INTEGER NOT NULL DEFAULT 0,
  state         INTEGER NOT NULL DEFAULT 0,  -- 0 invited, 1 active, 2 ended
  invited_by    TEXT,
  invited_at    TEXT,
  responded_at  TEXT,
  ended_at      TEXT,
  PRIMARY KEY (studio_id, instructor_id)
);
CREATE INDEX idx_members_instructor ON studio_members(instructor_id, state);
```

Routes (`flowe-backend/src/index.js`):

| Method | Route | Who | Does |
|---|---|---|---|
| `POST` | `/studio` | any instructor | create studio, caller becomes admin |
| `GET` | `/studio/:id` | any | studio + active member list |
| `POST` | `/studio/:id/invite` | admin | insert row, state=invited, sets type |
| `POST` | `/studio/:id/respond` | invitee | state → active or delete row |
| `POST` | `/studio/:id/leave` | member | state → ended |
| `DELETE` | `/studio/:id/member/:iid` | admin | state → ended |
| `GET` | `/me/studio` | self | my membership + type + admin flag |

`DELETE /me` must purge `studio_members` rows, as it already does for `entitlements`.

⚠️ `flowe-backend` is **not** under git — routes are local edits, deployed with `wrangler deploy`.

## 5. What changes in the app

### 5.1 Settings — the whole UI footprint for stage 1

`InstructorSettingsView`: a new **Studio** section between "Get Discovered" and "Preferences". Subscription lives just above it, which is where seats land in stage 2.

Empty state is one row: *Invite an instructor*. For anyone who never taps it, that row is the entire feature.

Not the Dashboard (daily teaching work). Not a new tab (five is the limit; this is rare and structural).

### 5.2 `StudioSetupWizard` — branches on type

Today's four derived steps are an **owner's** wizard: profile → author a lesson type → set your hours → go visible (paywall). For an employee, steps 2–4 are all wrong — the studio owns the catalogue, the timetable and the subscription seat.

Employee step list: **profile → join a studio → mark availability within the studio timetable.** No paywall.

`StudioSetupState` already derives every step from live model state rather than stored flags, so this is a different step list over the same derivation — not a second wizard.

The employee branch is unreachable until someone has accepted an invite, so it cannot regress any existing user.

### 5.3 Finance Center — correctness requirement, not a follow-on

`FinanceCenterView` computes revenue from `sessionEarning(for:)`. **An employee never receives that money.** In a studio where the owner also uses Flowe, the same shekels appear in two Finance Centers with two different meanings.

Employee variant shows **sessions taught and hours**, not revenue. This ships in the same stage as employee support — the moment employees exist, the current screen lies.

Studio roll-up for admins = admin's own + employees'. **Renters' revenue is excluded** — it is theirs, and the studio's income from a renter is rent, which is off-app.

### 5.4 Discover

| Instructor state | Rendering |
|---|---|
| no `studioID` | unchanged — own pin, own card |
| `studioID`, independent (renter) | keeps own pin — they are their own business |
| `studioID`, employee | no independent pin; appears on the studio card |
| Studio, `memberCount >= 2` | own pin and card, instructors listed underneath |

### 5.5 Untouched

Bookings (`Booking.instructorOwnerID ↔ studentID` — teaching is always instructor↔student), Messages, Community, student-side flows, onboarding, `AppSession`, role selection.

## 6. Phasing

**Stage 1 — brand, place, typed membership.** Studio record type + schema file + prod deploy; `Instructor.studioID`; D1 table + routes; Settings section; invite/accept; employee wizard branch; Finance Center employee variant; Discover folding. No billing, no roll-up, no permissions beyond the admin flag.

Ship the **type field from day one** even while both types behave nearly identically. A membership list without a type encodes "everyone is the same" into a permanent schema; adding the field later is legal but means retrofitting behaviour onto data that already lied.

**Stage 2 — money.** Studio roll-up (§5.3 delivered in-app), seats/billing, studio timetable, leaving/reassignment flows.

Biggest item in stage 2 is billing: `SubscriptionService.refreshEntitlements()` resolves purely from `Transaction.currentEntitlements`, with the backend as a mirror. Seats mean one Apple ID pays and N others become entitled — which makes the **backend authoritative** for seat-granted visibility. That is a real architectural shift, not a feature.

**Before stage 2**, confirm the App Store position on multi-seat B2B billing. Guideline 3.1.3(c) requires IAP for single-user sales; the multi-seat case needs checking rather than assuming — see `flowe-founding-rate-apple-mechanism`.

## 7. Effort

Stage 1: roughly **1.5–2 focused weeks** for one person. Inflated by no xcodegen (every new file is a hand-edit to `project.pbxproj`), signed-build-only verification, a CloudKit Production deploy, and AR/HE strings for every new surface.

## 8. Open questions — answer before coding

1. **Duplicate pins.** A renter and the studio share an address, so both get a pin at the same point. Cluster by address, or accept it in stage 1?
2. **DMs on departure.** An employee leaves; the client was the studio's. Does the existing 1:1 thread survive? (E2E and pairwise — Flowe cannot re-key or transfer it, so realistically it survives and the question is whether that is acceptable.)
3. **Future bookings on departure.** Reassign to another instructor, or cancel and notify?
4. **Many-to-many.** Employee at studio A and renter at studio B is real in Pilates. Recommend **one studio per instructor** for stage 1; Out-of-Studio already covers teaching elsewhere.
5. **Israeli labour law.** Once Flowe retains an employed instructor's hours-taught against a studio, that record is evidence in a wage or severance dispute. Decide retention and who can export it *before* a studio asks.
