import CoreLocation
import Foundation
import Observation

// MARK: - Coarse location

/// A coordinate that has already been blurred to the point where it is safe to publish.
///
/// This type is the **only** way a coordinate leaves `LocationService`, and the only way one gets
/// onto `Instructor` (see `Instructor.setCoarseLocation`). That is deliberate: a precise fix has no
/// representable path to the public CloudKit database, because no API hands one out. Many Pilates
/// instructors teach from their living room, and the public database is world-readable by any
/// authenticated user — publishing an exact fix would publish a home address.
///
/// **Precision: a 0.01° lattice, i.e. ~1.1 km north–south and ~1.1 km × cos(latitude) east–west**
/// (≈0.94 km at Tel Aviv's 32°N). Snapping to a fixed lattice rather than rounding relative to the
/// true point means every address inside a cell publishes the *same* number, so the value identifies
/// a neighbourhood and cannot be walked back toward a street. A kilometre is the smallest cell that
/// still reliably contains a few thousand residences in a dense city while remaining useful for
/// "how far is this instructor" — the only question a student is actually asking.
struct CoarseLocation: Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    /// Lattice denominator: coordinates are snapped to whole multiples of 1/100°.
    /// Expressed as a divisor rather than as `0.01` so snapping is exact in binary floating point —
    /// `(v * 100).rounded() / 100` lands on the canonical two-decimal double, `v / 0.01 * 0.01`
    /// does not, and a coordinate that jitters in its 15th digit is a coordinate that keeps
    /// republishing itself.
    private static let gridDivisor: Double = 100

    /// Cell size in degrees — what the instructor-facing copy promises.
    static var gridDegrees: Double { 1 / gridDivisor }

    /// Private: the only way in is through a snapping initializer, so an unblurred pair of doubles
    /// can never be smuggled into this type.
    private init(snappedLatitude: Double, snappedLongitude: Double) {
        latitude = snappedLatitude
        longitude = snappedLongitude
    }

    init?(snapping coordinate: CLLocationCoordinate2D) {
        self.init(snappingLatitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    /// Snaps a stored or fetched pair. Fails on anything that isn't a real coordinate, including the
    /// (0, 0) "Null Island" pair — a listing in the Gulf of Guinea is a bug, not a location.
    init?(snappingLatitude latitude: Double?, longitude: Double?) {
        guard let latitude, let longitude else { return nil }
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              !(latitude == 0 && longitude == 0) else { return nil }
        self.init(snappedLatitude: Self.snap(latitude), snappedLongitude: Self.snap(longitude))
    }

    private static func snap(_ value: Double) -> Double {
        (value * gridDivisor).rounded() / gridDivisor
    }

    /// "32.08, 34.78" — shown to the instructor so they can see exactly what gets published.
    /// Not localized: this is a coordinate, and its two decimals are the privacy promise.
    var displayText: String {
        String(format: "%.2f, %.2f", latitude, longitude)
    }
}

// MARK: - Location service

/// Thin `CLLocationManager` wrapper: authorization state, a one-shot fix, and distance maths.
///
/// The precise fix is stored privately and **never exposed**. Callers can ask for a distance
/// (computed here, on device) or for an already-coarsened point (safe to publish) — there is no
/// accessor that returns where the user actually is. That is what keeps a *student's* location
/// unpublishable by construction: the student-facing screens have nothing to publish even if they
/// wanted to, because `distance(toLatitude:longitude:)` returns a scalar, not a place.
///
/// Denial is a normal state, not an error. Every call answers, the feed never blocks on a fix, and
/// the free-text `city` remains the fallback everywhere.
@MainActor
@Observable
final class LocationService {

    // MARK: Observable state

    /// The user has been asked and said yes.
    private(set) var isAuthorized = false
    /// Denied or restricted (parental controls / MDM). Asking again does nothing — only Settings can
    /// change it, so the UI offers that instead of re-prompting.
    private(set) var isDenied = false
    /// Never asked. The only state in which a prompt may be raised.
    private(set) var isUndetermined = true
    /// A fix is being acquired right now.
    private(set) var isLocating = false
    /// Whether a usable fix exists. An observable proxy for `precise`, which stays private — views
    /// need to know *that* we can measure, never *where* the user is.
    private(set) var hasFix = false

    // MARK: Private state

    /// The precise fix. Deliberately private and observation-ignored: nothing outside this file can
    /// read it, so nothing outside this file can persist, publish or log it.
    @ObservationIgnored private var precise: CLLocation?
    @ObservationIgnored private var fixWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var authWaiters: [CheckedContinuation<Void, Never>] = []

    private let manager = CLLocationManager()
    private let proxy = LocationDelegateProxy()

    init() {
        // ~100 m is as good as this app ever needs: what we publish is snapped to a kilometre and
        // what we display is rounded to one. Asking for `kCLLocationAccuracyBest` would spin up GPS
        // and hold a more sensitive fix than any screen can use.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        proxy.onAuthorization = { [weak self] status in
            Task { @MainActor in self?.apply(status) }
        }
        proxy.onFix = { [weak self] fix in
            Task { @MainActor in self?.apply(fix) }
        }
        manager.delegate = proxy
        apply(manager.authorizationStatus)
    }

    // MARK: - Requests

    /// Raise the permission prompt if it has never been raised, and report whether we may proceed.
    /// Returns false for denied/restricted without prompting — iOS would ignore the request anyway.
    @discardableResult
    func ensureAuthorization() async -> Bool {
        if isAuthorized { return true }
        guard isUndetermined else { return false }
        manager.requestWhenInUseAuthorization()
        await waitForAuthorization()
        return isAuthorized
    }

    /// Acquire (or refresh) a one-shot fix. Returns whether one is available afterwards.
    /// Safe to call when the user has refused — it simply returns false.
    @discardableResult
    func refresh() async -> Bool {
        guard await ensureAuthorization() else { return false }
        if isLocating {
            // A second caller joins the in-flight request rather than queueing another GPS session.
            await waitForFix()
            return hasFix
        }
        isLocating = true
        manager.requestLocation()
        await waitForFix()
        return hasFix
    }

    /// A fix reduced to something publishable. The precise coordinate is snapped *here*, inside the
    /// service, so it is never returned to a caller in the first place.
    func requestCoarseLocation() async -> CoarseLocation? {
        guard await refresh(), let precise else { return nil }
        return CoarseLocation(snapping: precise.coordinate)
    }

    // MARK: - Measurement

    /// Metres from this device to a listing's published area, or nil when either side has no
    /// location. Computed on device; nothing is sent anywhere.
    ///
    /// The stored pair is re-snapped before use, so a listing published by some future or tampered
    /// client at street precision still only ever measures to the centre of its kilometre cell.
    func distance(toLatitude latitude: Double?, longitude: Double?) -> Double? {
        guard let precise,
              let coarse = CoarseLocation(snappingLatitude: latitude, longitude: longitude)
        else { return nil }
        return precise.distance(from: CLLocation(latitude: coarse.latitude, longitude: coarse.longitude))
    }

    /// Human name for a coarse area ("Tel Aviv-Yafo"), for the instructor's own confirmation.
    ///
    /// Geocodes the **coarsened** point, never the precise one: reverse geocoding is a network
    /// request, and there is no reason for Apple's geocoder to receive a finer coordinate than the
    /// one we are willing to publish.
    func areaName(for location: CoarseLocation) async -> String? {
        await Self.resolveAreaName(latitude: location.latitude, longitude: location.longitude)
    }

    /// Runs entirely off the main actor and returns only a `String`, so no non-Sendable placemark
    /// ever crosses an isolation boundary.
    private nonisolated static func resolveAreaName(latitude: Double, longitude: Double) async -> String? {
        let point = CLLocation(latitude: latitude, longitude: longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(point).first else { return nil }
        // City first — it is what the free-text `city` field means, and what a student searches by.
        guard let name = placemark.locality ?? placemark.subLocality ?? placemark.administrativeArea,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return name
    }

    // MARK: - Delegate plumbing

    private func apply(_ status: CLAuthorizationStatus) {
        isUndetermined = status == .notDetermined
        isAuthorized = status == .authorizedWhenInUse || status == .authorizedAlways
        isDenied = status == .denied || status == .restricted
        if !isAuthorized {
            // Permission revoked in Settings mid-session: drop the fix immediately rather than
            // keeping on measuring from a location the user has just withdrawn.
            precise = nil
            hasFix = false
        }
        resumeAuthWaiters()
    }

    private func apply(_ fix: LocationFix?) {
        // A failed update keeps whatever fix we already had: a stale position a few hundred metres
        // out is still a better answer than none, and the display is approximate by design.
        if let fix, fix.accuracy >= 0 {
            precise = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
            hasFix = true
        }
        isLocating = false
        resumeFixWaiters()
    }

    private func waitForAuthorization() async {
        await withCheckedContinuation { continuation in
            authWaiters.append(continuation)
            // Watchdog. CoreLocation does answer a prompt, but a continuation that is never resumed
            // suspends its caller forever — and that caller is a button the user just tapped.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
                self?.resumeAuthWaiters()
            }
        }
    }

    private func waitForFix() async {
        await withCheckedContinuation { continuation in
            fixWaiters.append(continuation)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20 * NSEC_PER_SEC)
                self?.timeOutFix()
            }
        }
    }

    private func timeOutFix() {
        guard !fixWaiters.isEmpty else { return }
        isLocating = false
        resumeFixWaiters()
    }

    /// Draining into a local first makes a double resume impossible even if two callbacks race.
    private func resumeAuthWaiters() {
        let waiting = authWaiters
        authWaiters = []
        for continuation in waiting { continuation.resume() }
    }

    private func resumeFixWaiters() {
        let waiting = fixWaiters
        fixWaiters = []
        for continuation in waiting { continuation.resume() }
    }
}

// MARK: - Sendable delegate bridge

/// One fix, flattened to scalars. CoreLocation's callbacks arrive outside the main actor, and
/// hopping back with plain `Double`s keeps the boundary trivially Sendable-correct.
private struct LocationFix: Sendable {
    let latitude: Double
    let longitude: Double
    let accuracy: Double
}

/// The `CLLocationManagerDelegate` conformance lives here rather than on `LocationService` so the
/// service can stay `@MainActor` without fighting the protocol's non-isolated callbacks.
///
/// `@unchecked Sendable` is honest: the two closures are assigned once during `LocationService.init`
/// — before the manager is given this object as its delegate — and never mutated again.
private final class LocationDelegateProxy: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    var onAuthorization: (@Sendable (CLAuthorizationStatus) -> Void)?
    var onFix: (@Sendable (LocationFix?) -> Void)?

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorization?(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else {
            onFix?(nil)
            return
        }
        onFix?(LocationFix(latitude: latest.coordinate.latitude,
                           longitude: latest.coordinate.longitude,
                           accuracy: latest.horizontalAccuracy))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Swallowed like every other optional service in this app: no fix simply means the feed
        // keeps its rating order and cards show a city instead of a distance.
        onFix?(nil)
    }
}
