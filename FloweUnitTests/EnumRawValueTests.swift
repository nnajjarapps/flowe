import XCTest
@testable import Flowe

/// Pins the **integer raw values** of every enum that is persisted (stored as `…Raw: Int` on an @Model
/// and mirrored into a CloudKit field). These ints are an on-the-wire / on-disk contract: reordering a
/// case, or inserting one in the middle, silently reinterprets every already-stored record on real
/// devices (a `hired` decision becomes `offer`, a `role` post becomes `recurring`). Reordering is a
/// tempting, innocent-looking edit — this test makes it fail loudly instead. Also guards the
/// `?? default` fallbacks the model getters use for unknown/forward values.
final class EnumRawValueTests: XCTestCase {

    func testOpportunityKindRawValues() {
        XCTAssertEqual(OpportunityKind.cover.rawValue, 0)
        XCTAssertEqual(OpportunityKind.recurring.rawValue, 1)
        XCTAssertEqual(OpportunityKind.role.rawValue, 2)
        XCTAssertEqual(OpportunityKind.apprenticeship.rawValue, 3)
        XCTAssertEqual(OpportunityKind.space.rawValue, 4)
    }

    func testOpportunityEligibilityRawValues() {
        XCTAssertEqual(OpportunityEligibility.openToAll.rawValue, 0)
        XCTAssertEqual(OpportunityEligibility.certifiedOnly.rawValue, 1)
    }

    func testOpportunityStatusRawValues() {
        XCTAssertEqual(OpportunityStatus.open.rawValue, 0)
        XCTAssertEqual(OpportunityStatus.closed.rawValue, 1)
        XCTAssertEqual(OpportunityStatus.filled.rawValue, 2)
    }

    func testApplicantRoleRawValues() {
        XCTAssertEqual(ApplicantRole.student.rawValue, 0)
        XCTAssertEqual(ApplicantRole.instructor.rawValue, 1)
    }

    func testApplicationStageRawValues() {
        XCTAssertEqual(ApplicationStage.applied.rawValue, 0)
        XCTAssertEqual(ApplicationStage.shortlisted.rawValue, 1)
        XCTAssertEqual(ApplicationStage.talking.rawValue, 2)
        XCTAssertEqual(ApplicationStage.offer.rawValue, 3)
        XCTAssertEqual(ApplicationStage.hired.rawValue, 4)
        XCTAssertEqual(ApplicationStage.declined.rawValue, 5)
    }

    // MARK: Model getters resolve raw → enum, with a safe fallback for unknown values

    func testOpportunityGettersResolveStoredRawValues() {
        let opp = Opportunity(kind: .role, eligibility: .certifiedOnly, status: .filled)
        XCTAssertEqual(opp.kind, .role)
        XCTAssertEqual(opp.eligibility, .certifiedOnly)
        XCTAssertEqual(opp.status, .filled)
    }

    func testOpportunityGettersFallBackWhenRawIsUnknown() {
        // A forward-compatible record written by a newer client carries an out-of-range raw value; the
        // getter must degrade to the documented default rather than trap.
        let opp = Opportunity()
        opp.kindRaw = 999
        opp.eligibilityRaw = 999
        opp.statusRaw = 999
        XCTAssertEqual(opp.kind, .cover)
        XCTAssertEqual(opp.eligibility, .openToAll)
        XCTAssertEqual(opp.status, .open)
    }

    func testApplicationRoleGetterFallsBackToInstructor() {
        let app = OpportunityApplication()
        app.applicantRoleRaw = 999
        XCTAssertEqual(app.role, .instructor)
    }

    func testDecisionStageGetterFallsBackToApplied() {
        let dec = ApplicationDecision()
        dec.stageRaw = 999
        XCTAssertEqual(dec.stage, .applied)
    }
}
