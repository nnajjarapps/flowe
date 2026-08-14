import XCTest
@testable import Flowe

/// Flowe is shekel-only, and a price must render identically regardless of UI language — an Arabic or
/// Hebrew UI still shows "₪95" with Western ASCII digits. This guards the "₪ became $" class of
/// currency-symbol regression and the RTL price-formatting expectation a reviewer checks against the
/// Israel-storefront screenshots. Headless: `AppSettings` touches only UserDefaults.
final class CurrencyFormattingTests: XCTestCase {

    func testCurrencyIsShekel() {
        let s = AppSettings()
        XCTAssertEqual(s.currencySymbol, "₪")
        let m = s.money(95)
        XCTAssertTrue(m.contains("95"))
        XCTAssertFalse(m.first!.isNumber)          // symbol-prefixed, not a bare number
    }

    func testMoneyDecimalsOption() {
        let s = AppSettings()
        let d = s.money(0, decimals: true)
        XCTAssertTrue(d.contains("."))
        XCTAssertEqual(d.filter { $0 == "." }.count, 1)
    }

    func testMoneyIsLanguageIndependentWithAsciiDigits() {
        let s = AppSettings()
        let baseline = s.money(95)
        s.language = .ar
        XCTAssertEqual(s.money(95), baseline)      // language never changes the price rendering
        s.language = .he
        XCTAssertEqual(s.money(95), baseline)
        // Digits stay Western ASCII 0-9, never Eastern-Arabic-Indic ٠-٩, in any language.
        XCTAssertTrue(baseline.contains { ("0"..."9").contains($0) })
        XCTAssertFalse(baseline.contains { ("٠"..."٩").contains($0) })
    }
}
