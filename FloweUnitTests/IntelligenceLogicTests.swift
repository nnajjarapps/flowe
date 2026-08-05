import XCTest
@testable import Flowe

/// Locks the deterministic glue around Flowe Intelligence — the pure mapping/validation that turns the
/// on-device model's (constrained) string outputs back into Flowe's real types, plus the prompt digest.
/// The inference itself is device-only and can't be unit-tested; THIS is the part that can, and the part
/// where a silent bug would mis-file a post or a search. No model, no simulator.
final class IntelligenceLogicTests: XCTestCase {

    private let categories = ["All", "Mat", "Reformer", "Barre", "Prenatal"]

    // MARK: resolveCategory — NL Discover search

    func testResolveCategoryExactMatch() {
        XCTAssertEqual(FloweAI.resolveCategory("Reformer", in: categories), "Reformer")
    }

    func testResolveCategoryIsCaseInsensitive() {
        XCTAssertEqual(FloweAI.resolveCategory("reformer", in: categories), "Reformer")
        XCTAssertEqual(FloweAI.resolveCategory("BARRE", in: categories), "Barre")
    }

    func testResolveCategoryUnknownFallsBackToAll() {
        // A hallucinated / off-list category must never become an invalid filter value.
        XCTAssertEqual(FloweAI.resolveCategory("Yoga", in: categories), "All")
        XCTAssertEqual(FloweAI.resolveCategory("", in: categories), "All")
    }

    // MARK: opportunityKind — opportunity draft

    func testOpportunityKindMapsEveryKeyword() {
        XCTAssertEqual(FloweAI.opportunityKind(from: "cover"), .cover)
        XCTAssertEqual(FloweAI.opportunityKind(from: "recurring"), .recurring)
        XCTAssertEqual(FloweAI.opportunityKind(from: "role"), .role)
        XCTAssertEqual(FloweAI.opportunityKind(from: "apprenticeship"), .apprenticeship)
        XCTAssertEqual(FloweAI.opportunityKind(from: "space"), .space)
    }

    func testOpportunityKindIsCaseInsensitive() {
        XCTAssertEqual(FloweAI.opportunityKind(from: "ROLE"), .role)
    }

    func testOpportunityKindUnknownDefaultsToCover() {
        XCTAssertEqual(FloweAI.opportunityKind(from: "gibberish"), .cover)
        XCTAssertEqual(FloweAI.opportunityKind(from: ""), .cover)
    }

    // MARK: opportunityEligibility — opportunity draft (safe default matters)

    func testEligibilityOpenToAll() {
        XCTAssertEqual(FloweAI.opportunityEligibility(from: "openToAll"), .openToAll)
        XCTAssertEqual(FloweAI.opportunityEligibility(from: "opentoall"), .openToAll)
    }

    func testEligibilityDefaultsToCertifiedOnly() {
        // The safer, more-restrictive side — an ambiguous parse must never open a teaching role to students.
        XCTAssertEqual(FloweAI.opportunityEligibility(from: "certifiedOnly"), .certifiedOnly)
        XCTAssertEqual(FloweAI.opportunityEligibility(from: "anything else"), .certifiedOnly)
        XCTAssertEqual(FloweAI.opportunityEligibility(from: ""), .certifiedOnly)
    }

    // MARK: preferenceSummary — why-this-instructor prompt digest

    func testPreferenceSummaryFull() {
        let prefs = StudentPreferences(goals: [.strength], disciplines: ["Reformer"],
                                       experience: .beginner, format: .privateOneOnOne)
        // Uses the enums' own labels so the assertion survives copy tweaks but pins the assembly.
        let expected = "wants Reformer; goals: \(StudentGoal.strength.label); "
                     + "prefers \(SessionFormat.privateOneOnOne.label); \(ExperienceLevel.beginner.label)"
        XCTAssertEqual(FloweAI.preferenceSummary(prefs), expected)
    }

    func testPreferenceSummaryEmptyWhenNothingAnswered() {
        XCTAssertEqual(FloweAI.preferenceSummary(StudentPreferences()), "")
    }

    func testPreferenceSummaryOmitsUnansweredParts() {
        let prefs = StudentPreferences(disciplines: ["Mat", "Barre"])
        XCTAssertEqual(FloweAI.preferenceSummary(prefs), "wants Mat, Barre")
    }

    func testPreferenceSummaryJoinsMultipleGoals() {
        let prefs = StudentPreferences(goals: [.strength, .posture], disciplines: [])
        XCTAssertEqual(FloweAI.preferenceSummary(prefs),
                       "goals: \(StudentGoal.strength.label), \(StudentGoal.posture.label)")
    }
}
