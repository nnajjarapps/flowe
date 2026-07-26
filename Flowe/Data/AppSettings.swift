import SwiftUI
import Observation

// MARK: - Currency

enum Currency: String, CaseIterable, Identifiable {
    // ISO 4217 codes — `ils` is the shekel ("NIS" is a colloquial name Foundation does not accept).
    // USD and ILS only for now. The USD→ILS rate is fetched live (see AppSettings), not hardcoded.
    case usd, ils

    var id: String { rawValue }
    var code: String { rawValue.uppercased() }

    var name: String {
        switch self {
        case .usd: return "US Dollar"
        case .ils: return "Israeli New Shekel"
        }
    }
}

// MARK: - Language

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, es, fr, ar

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System default"
        case .en: return "English"
        case .es: return "Español"
        case .fr: return "Français"
        case .ar: return "العربية"
        }
    }

    /// nil = follow the device.
    var localeIdentifier: String? { self == .system ? nil : rawValue }

    var isRTL: Bool { self == .ar }
}

// MARK: - App settings (currency + language), persisted

@Observable
final class AppSettings {
    var currency: Currency { didSet { defaults.set(currency.rawValue, forKey: currencyKey) } }
    var language: AppLanguage { didSet { defaults.set(language.rawValue, forKey: languageKey) } }

    /// Israeli shekels per 1 USD. Fetched live from Frankfurter (ECB daily rates), cached across
    /// launches, with a cold-start fallback. This is the single source of truth for conversion now
    /// that the per-currency static table is gone.
    private(set) var usdToILS: Double

    private let defaults = UserDefaults.standard
    private let currencyKey = "flowe.currency"
    private let languageKey = "flowe.language"
    private let fxRateKey = "flowe.fx.usdToILS"
    private let fxDateKey = "flowe.fx.date"

    /// Last-resort rate, used only on a first launch with no cached rate and no network. The live
    /// fetch replaces it immediately; steady state runs off the cached value.
    private static let fallbackUSDToILS = 3.6

    init() {
        currency = defaults.string(forKey: currencyKey).flatMap(Currency.init) ?? .usd
        language = defaults.string(forKey: languageKey).flatMap(AppLanguage.init) ?? .system
        let cached = defaults.double(forKey: fxRateKey)
        usdToILS = cached > 0 ? cached : Self.fallbackUSDToILS
    }

    /// Locale that drives both string localization and number/currency/date formatting.
    var locale: Locale {
        language.localeIdentifier.map(Locale.init(identifier:)) ?? Locale.autoupdatingCurrent
    }

    var layoutDirection: LayoutDirection {
        language.isRTL ? .rightToLeft : .leftToRight
    }

    /// Formats a USD integer amount into the selected currency.
    ///
    /// Currency is **independent of the app language** — it always uses a fixed Western locale so
    /// numerals and symbol placement stay consistent (e.g. Arabic UI can still show "$95").
    func money(_ usd: Int, decimals: Bool = false) -> String {
        let amount = currency == .ils ? Double(usd) * usdToILS : Double(usd)
        return amount.formatted(
            .currency(code: currency.code)
            .precision(.fractionLength(decimals ? 2 : 0))
            .locale(Locale(identifier: "en_US"))
        )
    }

    // MARK: - Exchange rate (Frankfurter — ECB daily rates, keyless)

    /// Refresh USD→ILS from Frankfurter. No-ops if today's rate is already cached (rates are daily),
    /// and on any failure it silently keeps the cached/fallback value — conversion never blocks on
    /// the network and never shows nothing.
    @MainActor
    func refreshExchangeRate(now: Date = Date()) async {
        let today = Self.dayStamp(now)
        if defaults.string(forKey: fxDateKey) == today, defaults.double(forKey: fxRateKey) > 0 { return }
        guard let url = URL(string: "https://api.frankfurter.dev/v1/latest?base=USD&symbols=ILS"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let payload = try? JSONDecoder().decode(FrankfurterRates.self, from: data),
              let rate = payload.rates["ILS"], rate > 0
        else { return }
        usdToILS = rate
        defaults.set(rate, forKey: fxRateKey)
        defaults.set(today, forKey: fxDateKey)
    }

    private static func dayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// The currency symbol to prefix a price INPUT field with, so an instructor typing a rate sees
    /// the same symbol students see on the price. Derived from `money(_:)`'s own output — the symbol
    /// is everything before the first digit — so the entry prefix can never drift from the display,
    /// and it tracks the selected currency instead of a hardcoded "$". `money` always formats in a
    /// fixed Western locale, so the symbol is always the leading run.
    var currencySymbol: String {
        String(money(0).prefix { !$0.isNumber }).trimmingCharacters(in: .whitespaces)
    }
}

/// Frankfurter's `/latest` response — only the rates map is needed.
private struct FrankfurterRates: Decodable {
    let rates: [String: Double]
}
