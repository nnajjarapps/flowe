import SwiftUI
import Observation

// MARK: - Currency

enum Currency: String, CaseIterable, Identifiable {
    case usd, eur, gbp, cad, aud, aed, inr, jpy

    var id: String { rawValue }
    var code: String { rawValue.uppercased() }

    /// Approximate units per 1 USD (static demo rates).
    var rate: Double {
        switch self {
        case .usd: return 1
        case .eur: return 0.92
        case .gbp: return 0.79
        case .cad: return 1.36
        case .aud: return 1.52
        case .aed: return 3.67
        case .inr: return 83
        case .jpy: return 149
        }
    }

    var name: String {
        switch self {
        case .usd: return "US Dollar"
        case .eur: return "Euro"
        case .gbp: return "British Pound"
        case .cad: return "Canadian Dollar"
        case .aud: return "Australian Dollar"
        case .aed: return "UAE Dirham"
        case .inr: return "Indian Rupee"
        case .jpy: return "Japanese Yen"
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

    private let defaults = UserDefaults.standard
    private let currencyKey = "flowe.currency"
    private let languageKey = "flowe.language"

    init() {
        currency = defaults.string(forKey: currencyKey).flatMap(Currency.init) ?? .usd
        language = defaults.string(forKey: languageKey).flatMap(AppLanguage.init) ?? .system
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
        let amount = Double(usd) * currency.rate
        return amount.formatted(
            .currency(code: currency.code)
            .precision(.fractionLength(decimals ? 2 : 0))
            .locale(Locale(identifier: "en_US"))
        )
    }
}
