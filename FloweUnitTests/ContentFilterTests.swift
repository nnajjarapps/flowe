import XCTest
@testable import Flowe

/// Behavioural lock on `ContentFilter` — the pre-publish screen for public instructor-listing text
/// (App Store 1.2). Two jobs: (1) prove the filter still catches what it must; (2) pin the ONE
/// false-positive that shaped the design — a date range like "2016-2018" trips the phone-number regex —
/// so the reason the experience *period* field is deliberately NOT run through the filter stays
/// documented and enforced. If someone "fixes" the filter to accept date ranges, or feeds the period
/// field back into it, this file tells them exactly what breaks.
final class ContentFilterTests: XCTestCase {

    // MARK: Clean text passes

    func testOrdinaryListingTextIsAccepted() {
        XCTAssertNil(ContentFilter.reject("Reformer and mat classes for every level."))
        XCTAssertNil(ContentFilter.reject("Certified STOTT instructor since 2015."))
        XCTAssertNil(ContentFilter.reject("Classic reformer flow in a calm studio."))
    }

    func testWordsMerelyContainingABlockedSubstringAreAccepted() {
        // Word-boundary matching: "class" contains "…ass…", "Scunthorpe" contains a slur substring —
        // neither is a whole blocked word, so both must pass.
        XCTAssertNil(ContentFilter.reject("Small class sizes"))
        XCTAssertNil(ContentFilter.reject("Studio near Scunthorpe"))
    }

    // MARK: Objectionable language

    func testProfanityIsRejected() {
        // Whole-word match (the deliberate anti-"Scunthorpe" design): the blocked token must appear as
        // its own word. "fucking" is NOT in the list — only "fuck" — so it slips the regex by design;
        // that gap is exactly what the AI moderation assist covers on capable devices.
        XCTAssertEqual(ContentFilter.reject("what the fuck"), .objectionableLanguage)
    }

    func testProfanityIsCaseInsensitiveAndPunctuationSafe() {
        XCTAssertEqual(ContentFilter.reject("SHIT!"), .objectionableLanguage)
        XCTAssertEqual(ContentFilter.reject("what a (bitch)"), .objectionableLanguage)
    }

    // MARK: Contact details routed off-platform

    func testEmailAddressIsRejected() {
        XCTAssertEqual(ContentFilter.reject("reach me at coach@example.com"), .contactDetails)
    }

    func testPhoneNumberIsRejected() {
        XCTAssertEqual(ContentFilter.reject("call 052-123-4567 to book"), .contactDetails)
        XCTAssertEqual(ContentFilter.reject("+972 54 000 1122"), .contactDetails)
    }

    // MARK: The documented false-positive — WHY the period field is excluded from filtering

    func testDateRangeTripsTheContactRegex_RegressionLock() {
        // "2016-2018" is a run of digits/dashes long enough to look like a phone number to the coarse
        // contact regex. This is a KNOWN false positive. The product decision (see EditProfileView /
        // the experience editor) is to NOT screen the experience *period* field at all, precisely
        // because legitimate date ranges land here. This assertion pins that behaviour: if it ever
        // changes, revisit whether the period field can safely be filtered again.
        XCTAssertEqual(ContentFilter.reject("2016-2018"), .contactDetails)
    }

    // MARK: Multi-field form screen

    func testRejectFieldsReturnsFirstOffendingField() {
        let rejection = ContentFilter.reject(fields: [
            "Reformer classes",     // clean
            "email me: a@b.com",    // first offender
            "shit",                 // also bad, but later
        ])
        XCTAssertEqual(rejection, .contactDetails)
    }

    func testRejectFieldsPassesWhenAllClean() {
        XCTAssertNil(ContentFilter.reject(fields: [
            "Reformer classes",
            "Tel Aviv studio",
            "Certified since 2015",
        ]))
    }
}
