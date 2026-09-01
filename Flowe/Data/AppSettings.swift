import SwiftUI
import Observation

// MARK: - Currency

/// Flowe is **shekel-only**. Prices are stored as whole-shekel integers and shown as ₪ directly —
/// there is no cross-currency conversion. Kept as a one-case enum so `settings.currency` and the
/// existing `.currency(code:)` formatting call sites stay valid.
enum Currency: String, CaseIterable, Identifiable {
    // ISO 4217 code — `ils` is the shekel ("NIS" is a colloquial name Foundation does not accept).
    case ils

    var id: String { rawValue }
    var code: String { rawValue.uppercased() }
    var name: String { "Israeli New Shekel" }
}

// MARK: - Language

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, ar, he

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System default"
        case .en: return "English"
        case .ar: return "العربية"
        case .he: return "עברית"
        }
    }

    /// nil = follow the device.
    var localeIdentifier: String? { self == .system ? nil : rawValue }

    var isRTL: Bool { self == .ar || self == .he }
}

// MARK: - App settings (currency + language), persisted

@Observable
final class AppSettings {
    /// Flowe prices are always in shekels; there is nothing to switch, so this is a constant.
    let currency = Currency.ils
    var language: AppLanguage { didSet { defaults.set(language.rawValue, forKey: languageKey); pushToBackend() } }

    /// How far (km) the Out-of-Studio coverage search reaches when finding a swap instructor. Enforced
    /// only when a device fix is available (see `MockDataStore.oosCandidates`). Clamped to a sane band
    /// so the stepper can't drive it to 0 (no candidates) or an absurd radius.
    var coverageRadiusKm: Double {
        didSet {
            let clamped = min(max(coverageRadiusKm, Self.minCoverageRadiusKm), Self.maxCoverageRadiusKm)
            if clamped != coverageRadiusKm { coverageRadiusKm = clamped; return }
            defaults.set(coverageRadiusKm, forKey: coverageRadiusKey)
        }
    }

    static let minCoverageRadiusKm: Double = 1
    static let maxCoverageRadiusKm: Double = 100
    static let defaultCoverageRadiusKm: Double = 25

    /// The instructor's saved Out-of-Studio window (From / Until). Persisted so it survives closing the
    /// sheet — `OutOfStudioView` rolls a stale (past) window forward on appear, preserving the DURATION
    /// the instructor set. Mirrors `coverageRadiusKm`.
    var oosWindowStart: Date { didSet { defaults.set(oosWindowStart.timeIntervalSince1970, forKey: oosStartKey); pushToBackend() } }
    var oosWindowEnd: Date { didSet { defaults.set(oosWindowEnd.timeIntervalSince1970, forKey: oosEndKey); pushToBackend() } }

    private let defaults = UserDefaults.standard
    private let languageKey = "flowe.language"
    private let coverageRadiusKey = "flowe.coverageRadiusKm"
    private let oosStartKey = "flowe.oosWindowStart"
    private let oosEndKey = "flowe.oosWindowEnd"

    init() {
        language = defaults.string(forKey: languageKey).flatMap(AppLanguage.init) ?? .system
        let stored = defaults.object(forKey: coverageRadiusKey) as? Double
        coverageRadiusKm = stored.map { min(max($0, Self.minCoverageRadiusKm), Self.maxCoverageRadiusKm) }
            ?? Self.defaultCoverageRadiusKm
        oosWindowStart = (defaults.object(forKey: oosStartKey) as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
        oosWindowEnd = (defaults.object(forKey: oosEndKey) as? Double).map(Date.init(timeIntervalSince1970:))
            ?? Calendar.current.date(byAdding: .hour, value: 8, to: Date()) ?? Date()
    }

    /// Locale that drives both string localization and number/currency/date formatting.
    var locale: Locale {
        language.localeIdentifier.map(Locale.init(identifier:)) ?? Locale.autoupdatingCurrent
    }

    var layoutDirection: LayoutDirection {
        language.isRTL ? .rightToLeft : .leftToRight
    }

    /// Formats a whole-shekel amount for display.
    ///
    /// Flowe is shekel-only, so the integer **is** the price — there is no conversion. A fixed
    /// Western (`en_US`) locale keeps numerals and symbol placement consistent regardless of the
    /// app's display language (e.g. an Arabic UI still shows "₪95").
    func money(_ amount: Int, decimals: Bool = false) -> String {
        Double(amount).formatted(
            .currency(code: currency.code)
                .precision(.fractionLength(decimals ? 2 : 0))
                .locale(Locale(identifier: "en_US"))
        )
    }

    /// The currency symbol to prefix a price INPUT field with, so an instructor typing a rate sees
    /// the same symbol students see on the price. Derived from `money(_:)`'s own output — the symbol
    /// is everything before the first digit — so the entry prefix can never drift from the display.
    var currencySymbol: String {
        String(money(0).prefix { !$0.isNumber }).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Cross-device sync

    /// The settings that should follow the signed-in Apple ID rather than the device. Stored as one
    /// JSON blob in `profiles.app_settings`, deliberately apart from `preferences` (the student
    /// matching quiz): one is what the app looks like, the other is what it recommends, and a format
    /// change to either should not be able to break the other.
    private struct Snapshot: Codable {
        var language: String
        var coverageRadiusKm: Double
        var oosWindowStart: Double
        var oosWindowEnd: Double
    }

    /// Set while applying a snapshot pulled from the backend, so the `didSet` hooks do not immediately
    /// push what we just received straight back up.
    private var isApplyingRemote = false

    private func pushToBackend() {
        guard !isApplyingRemote else { return }
        let snap = Snapshot(
            language: language.rawValue,
            coverageRadiusKm: coverageRadiusKm,
            oosWindowStart: oosWindowStart.timeIntervalSince1970,
            oosWindowEnd: oosWindowEnd.timeIntervalSince1970
        )
        guard let data = try? JSONEncoder().encode(snap),
              let json = String(data: data, encoding: .utf8) else { return }
        Task { await FloweBackendClient.shared.saveAppSettings(json: json) }
    }

    /// Pull settings for this Apple ID. Called once at sign-in. Applied ONLY when the device has no
    /// local choice yet or the values genuinely differ, so a fresh device inherits the user's setup
    /// instead of resetting to defaults.
    @MainActor
    func restoreFromBackend() async {
        guard let json = await FloweBackendClient.shared.fetchMyProfile()?.appSettings,
              let data = json.data(using: .utf8),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        if let lang = AppLanguage(rawValue: snap.language), lang != language { language = lang }
        if snap.coverageRadiusKm != coverageRadiusKm { coverageRadiusKm = snap.coverageRadiusKm }
        let start = Date(timeIntervalSince1970: snap.oosWindowStart)
        let end = Date(timeIntervalSince1970: snap.oosWindowEnd)
        if start != oosWindowStart { oosWindowStart = start }
        if end != oosWindowEnd { oosWindowEnd = end }
    }
}
