import CoreLocation
import Foundation
import SwiftData

/// Instructor feed visibility, driven by their IAP subscription tier.
enum InstructorVisibility: Int {
    case none = 0     // not subscribed → hidden from the student feed
    case visible = 1  // Flowe Visible → appears in the feed
    case boosted = 2  // Flowe Boost → appears higher / featured
}

/// Reference catalog entry. Stored in the local (non-synced) `Reference` configuration.
/// CloudKit-legal: class, every stored property defaulted, no `@Attribute(.unique)`.
@Model
final class Instructor {
    var legacyId: Int = 0          // stable id from seed JSON; used by `instructor(id:)` + booking links
    var name: String = ""
    /// LEGACY free-text city. No longer written or displayed — `address` replaced it as the public,
    /// student-facing location string. Kept on the model (not deleted) so an existing local row and
    /// the `CD_`/`InstructorListing` schema don't take a breaking migration; readers may still decode
    /// an old value for back-compat but nothing shows it. Set/display `address` instead.
    var city: String = ""
    /// The instructor's exact studio address, shown publicly wherever `city` used to appear so
    /// students can find and book the studio. Set together with the exact coordinate via
    /// `setStudioLocation(latitude:longitude:address:)`. Empty = not set (show nothing / a neutral
    /// placeholder — never fall back to `city`). This deliberately reverses the old coarse-area
    /// privacy design: it is a studio/business location, standard for a booking app.
    var address: String = ""
    var rating: Double = 0
    var reviews: Int = 0
    var price: Int = 0
    /// Years teaching, self-declared in Edit Profile and published on the listing. `0` means "not
    /// stated" — the field is optional there — so render it as unknown rather than as no experience.
    var yearsExp: Int = 0
    var students: Int = 0
    var specialties: [String] = []
    var sessionTypes: [String] = []
    var cert: String = ""
    var img: String = ""            // Unsplash photo id — seeded reference listings only
    /// Uploaded profile photo, already downscaled by `ProfileImage.prepare`. Published to the public
    /// catalog as a `CKAsset`; `img` stays the fallback for seeded listings that have no upload.
    /// External storage keeps the blob out of the SQLite row.
    @Attribute(.externalStorage) var photo: Data?
    /// Photograph of the certificate itself, downscaled by `ProfileImage.prepareDocument`. Backs up
    /// the free-text `cert` claim; Flowe still verifies nothing, so it is presented as the
    /// instructor's own evidence rather than as a Flowe check.
    @Attribute(.externalStorage) var certPhoto: Data?
    /// Flowe Pro brand kit (Pillar B): a wide brand cover/banner photo, shown behind the name on the
    /// student-facing hero and atop the instructor's own profile. Downscaled by `ProfileImage.preparePost`
    /// (wide, uncropped) and published as a `CKAsset` on `InstructorListing`. Nil = no cover (fall back
    /// to the profile photo / gradient). See [[FlowePro]].
    @Attribute(.externalStorage) var coverPhoto: Data?
    /// `PaymentMethod` raw ids the instructor accepts. Flowe processes no payments in this release,
    /// so a student needs this before booking, not after. `[String]` because neither SwiftData's
    /// CloudKit mirror nor a `CKRecord` field stores a richer type.
    var paymentMethods: [String] = []
    var available: [String] = []
    /// Bookable hours, one `"Mon|9:00 AM"` token per slot. A flat `[String]` rather than a nested
    /// type because this has to survive both SwiftData and a public-database `CKRecord`, neither of
    /// which stores a dictionary. Kept alongside `available` rather than replacing it: `available`
    /// is what the feed and the catalog already publish, and it stays derived from these on save.
    var hours: [String] = []
    var bio: String?
    // MARK: - Flowe Pro (career + brand layer — see [[FlowePro]] spec)
    //
    // Set directly (like `hours`/`photo`), NOT via `init`, so adding them is a lightweight local
    // SwiftData migration with zero call-site churn. Published to the `InstructorListing` public
    // record via CatalogService in a later phase; for now they render on the instructor's OWN profile.
    /// A one-line professional tagline, distinct from `bio` — the LinkedIn-style headline under the
    /// name (e.g. "Reformer & rehab specialist · STOTT"). Empty = not set (render nothing).
    var headline: String = ""
    /// A longer brand/story paragraph for the studio brand page (Pillar B). Empty = not set.
    var story: String = ""
    /// The instructor's brand accent, as a "#RRGGBB" hex string (kept as a raw String so the model
    /// stays UI-free — views resolve it via `Color(hexString:)`, falling back to the app pink). Empty
    /// or malformed = no brand color. Part of the Flowe Pro brand kit (Pillar B).
    var brandColor: String = ""
    /// Work history, one pipe-delimited row per role: `"2020-2023|Studio Name|Reformer Lead"`. A flat
    /// `[String]` (like `hours`) so it survives both SwiftData and a `CKRecord` LIST<STRING> field with
    /// no nested type. Decode via `experience`.
    var experienceTokens: [String] = []
    /// The instructor's **exact studio point** — the coordinate a student navigates to. No longer
    /// snapped/coarsened: this is a published studio/business location, so it is stored and shown at
    /// full precision (see the location feature). Optional rather than a 0/0 sentinel so "hasn't set
    /// one" is a distinct, unambiguous state: (0, 0) is a real coordinate, and a listing that quietly
    /// claimed it would sort as "nearest" for anyone in the Gulf of Guinea and absurd for everyone else.
    ///
    /// Write these through `setStudioLocation(latitude:longitude:address:)` — from a geocoded address
    /// or the device's exact one-shot fix. Read the pair (or `studioCoordinate`) directly; distances
    /// use `CLLocation.distance(from:)`, NOT the old snapping `CoarseLocation` path. `setCoarseLocation`
    /// survives only for any remaining coarse-only caller and is no longer how the studio point is set.
    var latitude: Double?
    var longitude: Double?
    var order: Int = 0              // stable display order
    var ownerID: String?           // the signed-in instructor who owns/edits this listing
    var visibilityRaw: Int = 0     // InstructorVisibility — driven by the owner's subscription
    var visibilityVerifiedAt: Date? // last time the owner's device confirmed the subscription
    /// Listing edits that never reached the public catalog, retried on the next sync.
    ///
    /// Matters most for a *removal*: clearing a teaching area or a certificate locally while the
    /// save fails would otherwise leave that data world-readable indefinitely, since nothing else
    /// re-publishes an instructor's own listing.
    var pendingPublish: Bool = false
    /// Per-device baseline for the own-listing re-sync: the server `modificationDate` of the last
    /// own `InstructorListing` this device successfully published OR applied. Used ONLY by
    /// `hydrateOwnListingIfNeeded`'s strictly-newer gate — it applies the fetched listing when the
    /// server copy's `modifiedAt` is strictly greater than this. Always a SERVER timestamp, never a
    /// local `Date()`, so device clock skew can't corrupt the ordering. Optional/defaulted and left
    /// out of `init(...)` on purpose: `Instructor` is LOCAL-ONLY (Reference `.none` config), so this
    /// is a lightweight local SwiftData migration with no CloudKit deploy and no call-site churn.
    /// Meaningless on any cached row that isn't the signed-in user's own; only the own-listing path
    /// ever writes it.
    var lastSyncedAt: Date? = nil

    var visibility: InstructorVisibility {
        get { InstructorVisibility(rawValue: visibilityRaw) ?? .none }
        set { visibilityRaw = newValue.rawValue }
    }

    init(
        legacyId: Int = 0,
        name: String = "",
        city: String = "",
        address: String = "",
        rating: Double = 0,
        reviews: Int = 0,
        price: Int = 0,
        yearsExp: Int = 0,
        students: Int = 0,
        specialties: [String] = [],
        sessionTypes: [String] = [],
        cert: String = "",
        img: String = "",
        paymentMethods: [String] = [],
        available: [String] = [],
        hours: [String] = [],
        bio: String? = nil,
        order: Int = 0,
        ownerID: String? = nil
    ) {
        self.legacyId = legacyId
        self.name = name
        self.city = city
        self.address = address
        self.rating = rating
        self.reviews = reviews
        self.price = price
        self.yearsExp = yearsExp
        self.students = students
        self.specialties = specialties
        self.sessionTypes = sessionTypes
        self.cert = cert
        self.img = img
        self.paymentMethods = paymentMethods
        self.available = available
        self.hours = hours
        self.bio = bio
        self.order = order
        self.ownerID = ownerID
    }

    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }

    // MARK: - Flowe Pro: experience

    /// One decoded work-history row. `period` may be empty (ongoing / unstated).
    struct ExperienceEntry: Identifiable, Equatable {
        let id = UUID()
        let period: String   // "2020-2023" or "2023-now" or ""
        let place: String    // studio / employer
        let role: String     // "Reformer Lead"
    }

    /// `experienceTokens` decoded into displayable rows, newest-first (tokens are stored newest-first).
    /// A malformed token (wrong field count) is skipped rather than shown half-parsed.
    var experience: [ExperienceEntry] {
        experienceTokens.compactMap { token in
            let parts = token.components(separatedBy: "|")
            guard parts.count == 3 else { return nil }
            let place = parts[1].trimmingCharacters(in: .whitespaces)
            guard !place.isEmpty else { return nil }
            return ExperienceEntry(period: parts[0].trimmingCharacters(in: .whitespaces),
                                   place: place,
                                   role: parts[2].trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: - Studio location

    /// The exact studio point, or nil when unset. Reads `latitude`/`longitude` directly with NO
    /// snapping — the studio coordinate is published at full precision. Rejects the (0, 0) Null Island
    /// sentinel and any non-finite / out-of-range pair, so "hasn't set one" and "garbage row" both
    /// resolve to nil rather than to a bogus point on the map. This is what consumers read to place a
    /// pin or measure a distance (`CLLocation(latitude:longitude:).distance(from:)`).
    var studioCoordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude,
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              !(latitude == 0 && longitude == 0)
        else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Set (or clear) the exact studio point and its address together. Passing nil coordinates is how
    /// an instructor takes their studio location back down — the fields are cleared locally and the
    /// catalog record's keys are removed on publish. Stores the coordinate EXACTLY, with no snapping:
    /// this replaced the coarsening `setCoarseLocation` for the studio point.
    func setStudioLocation(latitude: Double?, longitude: Double?, address: String) {
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
    }

    // MARK: - Coarse location (legacy)

    /// LEGACY coarse teaching area, re-snapped on read. No longer how the studio point is set —
    /// `latitude`/`longitude` now hold the EXACT studio coordinate — but kept so any remaining caller
    /// that still wants a ~1 km-snapped value (or `CoarseLocation`'s distance maths) keeps compiling.
    var coarseLocation: CoarseLocation? {
        CoarseLocation(snappingLatitude: latitude, longitude: longitude)
    }

    /// LEGACY coarse setter. The studio point is now set exactly via `setStudioLocation`; this remains
    /// only for compatibility with any coarse-only caller and would SNAP the value, so do not use it
    /// for the studio location.
    func setCoarseLocation(_ location: CoarseLocation?) {
        latitude = location?.latitude
        longitude = location?.longitude
    }

    // MARK: - Bookable hours

    private static let separator = "|"

    /// Bookable times on a weekday, in chronological order.
    ///
    /// A day with no stored hours falls back to the standard slate — but this fallback is now
    /// LEGACY-ONLY. `AvailabilityView.save()` recomputes `available` from `daysWithHours`, so after
    /// any edit `available` holds only days that actually carry `hours` tokens. A token-less day
    /// still present in `available` can therefore only be a listing written before per-day hours
    /// existed (days set, hours never populated); returning nothing for those would silently make
    /// every one of them unbookable. A day the instructor explicitly CLOSED is instead absent from
    /// `available` (save removed it), so the fallback does not fire and it correctly reads closed —
    /// this is what fixes the "close a day silently reopens it with the full slate" bug.
    func hours(on day: String) -> [String] {
        // `self.hours` throughout: a bare `hours` here is ambiguous with this method.
        let stored = self.hours.compactMap { token -> String? in
            let parts = token.components(separatedBy: Self.separator)
            guard parts.count == 2, parts[0] == day else { return nil }
            return parts[1]
        }
        // Return the instructor's own stored times, ordered by time of day. Must NOT intersect with
        // `FloweConstants.times` — that preset only holds whole hours, so filtering through it
        // silently dropped every custom time (9:10, 9:30, …) the availability editor now allows.
        guard stored.isEmpty else { return Self.chronological(stored) }
        return available.contains(day) ? FloweConstants.times : []
    }

    /// Order year-less "h:mm a" time strings by time of day, so a day's slots read 8:00, 9:30,
    /// 10:15 rather than in insertion order. Unparseable strings sort last.
    private static func chronological(_ times: [String]) -> [String] {
        times.sorted { minutesOfDay($0) < minutesOfDay($1) }
    }

    // `en_US_POSIX` (NOT plain `en_US`): a fixed "h:mm a" parser on a non-POSIX locale still honours
    // the device's 24-Hour Time toggle (Apple QA1480), so with it on — the DEFAULT in Israel — these
    // stored 12-hour tokens failed to parse and `chronological` couldn't order a day's slots. Must stay
    // in lockstep with `AvailabilityView.timeFormatter`, which writes the tokens this reads.
    private static let timeParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private static func minutesOfDay(_ time: String) -> Int {
        guard let date = timeParser.date(from: time) else { return .max }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    /// Replace one day's hours, leaving the other days untouched.
    func setHours(_ times: [String], on day: String) {
        let others = self.hours.filter { !$0.hasPrefix(day + Self.separator) }
        self.hours = others + times.map { day + Self.separator + $0 }
    }

    /// Whether this day can be booked at all.
    func isBookable(on day: String) -> Bool { !hours(on: day).isEmpty }

    // MARK: - Date-specific overrides (vacation / one-off days)
    //
    // A date override lets an instructor break the weekly recurring pattern for ONE calendar date:
    // close it (vacation), give it different hours (a half-day), or open a normally-closed date.
    // Encoded as EXTRA tokens in this same `hours` array under a date-keyed namespace, e.g.
    // "2026-08-14|9:00 AM" (custom/opened) or "2026-08-14|CLOSED" (closed). The date key is
    // `Booking.seriesDateString` (POSIX "yyyy-MM-dd"), which can NEVER equal a `FloweConstants.weekdays`
    // entry, so the weekday-token and date-token namespaces are provably disjoint. Every existing reader
    // keys on `parts[0] == weekday` and therefore ignores date tokens unchanged — no new CloudKit field,
    // no schema deploy. Precedence: a date override WINS over the weekday pattern.

    /// Sentinel time value marking a date as fully closed. Never parses as an "h:mm a" time
    /// (`timeParser` returns nil), so it can never be mistaken for — or sorted as — a bookable slot.
    static let closedMarker = "CLOSED"

    /// A decoded date override: the date is either fully closed, or carries an explicit set of times
    /// that replaces the weekly slate.
    enum DateOverride: Equatable {
        case closed
        case custom([String])
    }

    /// Bookable times on a specific calendar DATE. A date override wins over the weekday pattern: a
    /// CLOSED date returns nothing; a custom / opened date returns its own times; a date with no
    /// override falls back to the weekly slate via `hours(on:)`. This is the single funnel every
    /// booking-time read should route through so availability is date-aware, not weekday-only.
    func hours(onDate date: Date) -> [String] {
        let key = Booking.seriesDateString(date)
        let vals = self.hours.compactMap { token -> String? in
            let parts = token.components(separatedBy: Self.separator)
            return (parts.count == 2 && parts[0] == key) ? parts[1] : nil
        }
        if vals.contains(Self.closedMarker) { return [] }            // CLOSE wins
        if !vals.isEmpty { return Self.chronological(vals) }         // CUSTOM / OPEN
        // Weekly fallback: `bookingDateString` is POSIX "EEE, MMM d", so prefix(3) is the English
        // weekday key ("Mon") that `hours(on:)` and `available` are stored under.
        return hours(on: String(FloweWeek.bookingDateString(for: date).prefix(3)))
    }

    /// Whether this date carries the explicit CLOSED sentinel (a vacation / day off). Distinct from
    /// `hours(onDate:).isEmpty`, which is ALSO true for a normally-closed weekday with no override —
    /// this checks ONLY the explicit marker. That makes it the safe gate for series materialization: a
    /// hours-less placeholder instructor reads false, so top-up is never blocked wholesale.
    func isClosedOverride(onDate date: Date) -> Bool {
        self.hours.contains(Booking.seriesDateString(date) + Self.separator + Self.closedMarker)
    }

    /// Whether this date carries ANY date override (closed or custom).
    func hasDateOverride(onDate date: Date) -> Bool {
        let prefix = Booking.seriesDateString(date) + Self.separator
        return self.hours.contains { $0.hasPrefix(prefix) }
    }

    /// Whether this specific date can be booked — routes through the date-aware resolver.
    func isBookable(onDate date: Date) -> Bool { !hours(onDate: date).isEmpty }

    // MARK: Date-override editing (mirrors `setHours`)

    /// Mark a date fully closed (vacation). Replaces any existing override on that date key.
    func setClosed(onDateKey key: String) {
        let prefix = key + Self.separator
        self.hours = self.hours.filter { !$0.hasPrefix(prefix) } + [key + Self.separator + Self.closedMarker]
    }

    /// Set explicit custom / opened times on a date. Replaces any existing override on that date key.
    /// An empty `times` clears the override entirely (no closed sentinel) — the date then falls back
    /// to its weekday pattern.
    func setHours(_ times: [String], onDateKey key: String) {
        let prefix = key + Self.separator
        let others = self.hours.filter { !$0.hasPrefix(prefix) }
        self.hours = others + times.map { key + Self.separator + $0 }
    }

    /// Remove any override on a date key, restoring the weekday fallback.
    func clearOverride(onDateKey key: String) {
        let prefix = key + Self.separator
        self.hours = self.hours.filter { !$0.hasPrefix(prefix) }
    }

    /// Remove EVERY date override, keeping only the weekly weekday tokens. Used by the editor before
    /// re-writing the current override set, so a removed override actually disappears.
    func clearAllDateOverrides() {
        self.hours = self.hours.filter { token in
            guard let first = token.components(separatedBy: Self.separator).first else { return false }
            return FloweConstants.weekdays.contains(first)
        }
    }

    /// The date keys ("yyyy-MM-dd") that carry an override, sorted ascending (POSIX keys sort
    /// chronologically as plain strings).
    var overriddenDates: [String] {
        let keys = self.hours.compactMap { token -> String? in
            guard let first = token.components(separatedBy: Self.separator).first,
                  !FloweConstants.weekdays.contains(first) else { return nil }
            return first
        }
        return Array(Set(keys)).sorted()
    }

    /// The decoded override for a date key, or nil when the date has none.
    func dateOverride(forKey key: String) -> DateOverride? {
        let vals = self.hours.compactMap { token -> String? in
            let parts = token.components(separatedBy: Self.separator)
            return (parts.count == 2 && parts[0] == key) ? parts[1] : nil
        }
        guard !vals.isEmpty else { return nil }
        if vals.contains(Self.closedMarker) { return .closed }
        return .custom(Self.chronological(vals))
    }

    /// Days with at least one bookable hour — what `available` is kept in sync with.
    var bookableDays: [String] {
        FloweConstants.weekdays.filter(isBookable(on:))
    }

    // MARK: - Profile completeness

    /// The listing fields a student actually judges an instructor on. A profile missing any of these
    /// gets booked less, so the gaps are surfaced rather than left for the instructor to notice.
    ///
    /// SINGLE SOURCE OF TRUTH for "is the profile done": both the profile screen's completeness card
    /// (`InstructorProfileView`) and the Studio Setup wizard's step-1 signal read this, so there is no
    /// parallel completion logic to drift. Returns localized display tokens ("photo", "studio location",
    /// …) so a caller can list them in a sentence; callers that only need done/pending read `.isEmpty`.
    var profileMissingPieces: [String] {
        var missing: [String] = []
        if photo == nil && img.isEmpty { missing.append(String(localized: "photo")) }
        // The studio location is the exact `address` now, not the legacy `city` — which is never
        // written, so gating on `city.isEmpty` would flag every profile as incomplete forever.
        if address.isEmpty { missing.append(String(localized: "studio location")) }
        if (bio ?? "").isEmpty { missing.append(String(localized: "bio")) }
        if cert.isEmpty { missing.append(String(localized: "certification")) }
        if specialties.isEmpty { missing.append(String(localized: "specialties")) }
        // `price` is now DERIVED (the cheapest priced lesson type — see `startingPrice(from:)`), so 0
        // means "no priced lesson type yet", not "rate left blank". The nudge token reflects that.
        if price == 0 { missing.append(String(localized: "pricing")) }
        return missing
    }

    /// The "Your profile" setup step — exactly the fields the Edit Profile editor sets. Deliberately
    /// EXCLUDES `pricing`: price is derived from lesson types (the separate "Add a lesson type" step),
    /// so a fully-filled profile form would otherwise never mark this step done (it stayed "Set up"
    /// forever because pricing can't be entered here). Photo / studio location / bio / cert /
    /// specialties only — gates on the exact `address`, not the legacy (never-written) `city`.
    var profileBasicsComplete: Bool {
        (photo != nil || !img.isEmpty)
            && !address.isEmpty
            && !(bio ?? "").isEmpty
            && !cert.isEmpty
            && !specialties.isEmpty
    }

    /// The single "starting at" price shown wherever a listing needs ONE price before a specific
    /// lesson type is chosen (Discover cards, map pins, pre-type Book CTAs). It is the CHEAPEST priced
    /// lesson type — the honest floor of what a student could pay — and it is what `Instructor.price`
    /// is re-derived to whenever lesson types change (see `MockDataStore.publishMyListing`), so the
    /// stored `price` field and every remote-feed reader keep working with zero CloudKit schema change.
    ///
    /// `pendingDelete` rows are excluded (they are on their way out and `ownedLessonTypes` does NOT
    /// filter them). `compactMap(\.price)` drops "not stated" (nil-priced) types; among the STATED
    /// prices we anchor "from" on the cheapest **paid** (> 0) one and fall back to 0 only when there is
    /// no paid type at all — so an instructor who offers a free intro *alongside* a paid class is not
    /// collapsed to a 0 "from" (which `isEligible`/`profileMissingPieces` would read as "unpriced" and
    /// hide them from Discover). A listing whose only stated price is Free, or which has no stated price,
    /// still derives 0; the serverless feed carries a single `price: Int`, so a genuinely all-free
    /// listing can't be told from an unpriced one and stays hidden until a paid type is added.
    static func startingPrice(from types: [LessonType]) -> Int {
        let stated = types.filter { !$0.pendingDelete }.compactMap(\.price)
        return stated.filter { $0 > 0 }.min() ?? 0
    }

    /// Days that have at least one explicit hour token, in weekday order. Unlike `bookableDays` this
    /// reads only `hours`, never the fallback in `hours(on:)`, so it stays correct even while
    /// `available` still holds a pre-save value. `save()` derives the new `available` from THIS, not
    /// from `bookableDays`: routing through `bookableDays` → `isBookable` → `hours(on:)` re-reads the
    /// old `available`, hits the legacy full-slate fallback, and re-opens a day the instructor just
    /// closed (the reopen-with-full-slate bug).
    var daysWithHours: [String] {
        let days = Set(hours.compactMap { $0.components(separatedBy: Self.separator).first })
        return FloweConstants.weekdays.filter(days.contains)
    }
}
