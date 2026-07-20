import XCTest

/// Language switching. The bug: only ~25 of the app's strings were translated, and several UI
/// labels were built with SwiftUI's non-localizing `Text(String)` initializer, so most of the app
/// stayed English when a non-English language was selected.
///
/// These launch directly in Spanish (the app resolves its locale from `flowe.language`) and assert
/// that both the always-worked chrome and the previously-broken strings render translated.
final class LocalizationUITests: FloweUITestCase {

    // MARK: - Chrome that was already translated (regression guard)

    func testTabsAreTranslatedInSpanish() {
        launch(as: .student, language: "es")
        // "Discover" → "Descubre", "Bookings" → "Reservas", "Profile" → "Perfil".
        XCTAssertTrue(app.tabBars.buttons["Reservas"].waitForExistence(timeout: timeout)
                      || app.tabBars.buttons["Perfil"].waitForExistence(timeout: timeout),
                      "Tab bar should be in Spanish")
        XCTAssertFalse(app.tabBars.buttons["Bookings"].exists,
                       "English tab labels should not remain in Spanish")
    }

    // MARK: - Strings that were previously untranslated (the actual bug)

    func testProfileBodyStringsAreTranslated() {
        launch(as: .student, seeded: true, language: "es")
        selectTab("Perfil")
        // "Settings" gear content and section copy were English-only before.
        XCTAssertTrue(waitForAnyText(["Ajustes", "Cerrar sesión"], timeout: 15),
                      "Profile account rows should be translated")
    }

    func testSettingsScreenIsTranslated() {
        launch(as: .student, language: "es")
        selectTab("Perfil")
        // Open settings — the gear identifier is stable across languages.
        let gear = app.buttons["student.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: timeout), "Settings gear missing")
        _ = waitUntil({ gear.isHittable })
        gear.tap()
        XCTAssertTrue(waitForAnyText(["Preferencias", "Idioma", "Moneda"], timeout: 15),
                      "Settings labels should be translated (Preferences/Language/Currency)")
    }

    /// The dashboard greeting was computed with `Text(String)` and never localized — the headline
    /// case of the bug.
    func testInstructorDashboardGreetingIsTranslated() {
        launch(as: .instructor, language: "es")
        // Any of the three Spanish greetings, depending on the hour.
        XCTAssertTrue(waitForAnyText(["BUENOS DÍAS", "BUENAS TARDES", "BUENAS NOCHES"], timeout: 20),
                      "The time-of-day greeting must translate")
        XCTAssertNil(anyStaticText(["GOOD MORNING", "GOOD AFTERNOON", "GOOD EVENING"]),
                     "The English greeting should not remain")
    }

    /// Quick-action tiles were built from an enum of English literals via `Text(String)`.
    func testInstructorQuickActionsAreTranslated() {
        launch(as: .instructor, language: "es")
        XCTAssertTrue(scrollToText(["Añadir disponibilidad", "Ver ganancias"]),
                      "Dashboard quick actions should be translated")
    }

    // MARK: - Arabic / RTL

    func testArabicSwitchesLanguage() {
        launch(as: .student, language: "ar")
        // "Community" → "المجتمع" is a translated tab; assert the app isn't stuck in English.
        XCTAssertFalse(app.tabBars.buttons["Bookings"].waitForExistence(timeout: 15),
                       "Arabic launch should not show English tabs")
    }
}
