import XCTest
@testable import Flowe

/// Locks the two pure filters behind the **student opportunity browse** ([[FlowePro]] student surface):
/// which opportunities a student may browse, and which they've applied to. Both are extracted as static
/// helpers on `MockDataStore` precisely so they can be exercised here with plain in-memory model objects,
/// no live store / SwiftData container required.
final class OpportunityBrowseTests: XCTestCase {

    private func opp(_ id: String, eligibility: OpportunityEligibility = .openToAll,
                     created: TimeInterval = 0) -> Opportunity {
        // remoteID set → `key` resolves to it, exactly like a published opportunity an applicant references.
        Opportunity(remoteID: id, posterID: "poster", kind: .apprenticeship,
                    eligibility: eligibility, status: .open, title: "T",
                    createdAt: Date(timeIntervalSince1970: created))
    }

    private func application(to oppKey: String, by applicant: String,
                            withdrawn: Bool = false) -> OpportunityApplication {
        OpportunityApplication(opportunityID: oppKey, posterID: "poster",
                               applicantID: applicant, role: .student, withdrawn: withdrawn)
    }

    // MARK: studentBrowsable — students see only the openToAll slice

    func testStudentBrowsableKeepsOnlyOpenToAll() {
        let open = [
            opp("a", eligibility: .openToAll),
            opp("b", eligibility: .certifiedOnly),
            opp("c", eligibility: .openToAll),
        ]
        let result = MockDataStore.studentBrowsable(open)
        XCTAssertEqual(result.map(\.key), ["a", "c"])
    }

    func testStudentBrowsableEmptyWhenAllCertifiedOnly() {
        let open = [opp("a", eligibility: .certifiedOnly), opp("b", eligibility: .certifiedOnly)]
        XCTAssertTrue(MockDataStore.studentBrowsable(open).isEmpty)
    }

    // MARK: appliedOpportunities — the "Applied" tab

    func testAppliedReturnsOpportunitiesTheUserAppliedTo() {
        let opps = [opp("a"), opp("b"), opp("c")]
        let apps = [application(to: "a", by: "me"), application(to: "c", by: "me")]
        let result = MockDataStore.appliedOpportunities(opps, applications: apps, applicantID: "me")
        XCTAssertEqual(Set(result.map(\.key)), ["a", "c"])
    }

    func testAppliedExcludesWithdrawnApplications() {
        let opps = [opp("a"), opp("b")]
        let apps = [application(to: "a", by: "me"), application(to: "b", by: "me", withdrawn: true)]
        let result = MockDataStore.appliedOpportunities(opps, applications: apps, applicantID: "me")
        XCTAssertEqual(result.map(\.key), ["a"])
    }

    func testAppliedExcludesOtherApplicants() {
        let opps = [opp("a"), opp("b")]
        let apps = [application(to: "a", by: "me"), application(to: "b", by: "someone-else")]
        let result = MockDataStore.appliedOpportunities(opps, applications: apps, applicantID: "me")
        XCTAssertEqual(result.map(\.key), ["a"])
    }

    func testAppliedSortsNewestPostFirst() {
        let opps = [
            opp("old", created: 100),
            opp("new", created: 300),
            opp("mid", created: 200),
        ]
        let apps = [application(to: "old", by: "me"),
                    application(to: "new", by: "me"),
                    application(to: "mid", by: "me")]
        let result = MockDataStore.appliedOpportunities(opps, applications: apps, applicantID: "me")
        XCTAssertEqual(result.map(\.key), ["new", "mid", "old"])
    }

    func testAppliedMatchesByOpportunityKeyNotRecordName() {
        // The application stores the opportunity's `key` (remoteID once published). An opp whose key
        // doesn't match any application must not appear, even if a stale application references a
        // different id.
        let opps = [opp("published-key")]
        let apps = [application(to: "some-other-id", by: "me")]
        XCTAssertTrue(MockDataStore.appliedOpportunities(opps, applications: apps, applicantID: "me").isEmpty)
    }

    func testAppliedEmptyWhenNoApplications() {
        XCTAssertTrue(MockDataStore.appliedOpportunities([opp("a")], applications: [], applicantID: "me").isEmpty)
    }
}
