import XCTest
@testable import Flowe

/// Locks the **deterministic recordName / key** contracts. These strings are how the client achieves
/// idempotency against a serverless CloudKit backend (apply-once, upsert-on-advance, no duplicate DMs):
/// the same logical action must always resolve to the same recordName so a retry overwrites rather than
/// duplicates. If any of these formats drift, in-flight records on real devices stop matching their
/// server counterparts — silent duplication or lost upserts. Pure value logic; no host state needed.
final class RecordNameTests: XCTestCase {

    private let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    // MARK: Message — "msg-<localID>" (the duplicate-DM fix)

    func testMessageRecordNameFormat() {
        XCTAssertEqual(Message.recordName(localID: uuid), "msg-\(uuid.uuidString)")
    }

    func testMessageRecordNameIsDeterministic() {
        // Same localID → same recordName on every call: an idempotent resend overwrites, never dupes.
        XCTAssertEqual(Message.recordName(localID: uuid), Message.recordName(localID: uuid))
    }

    // MARK: Opportunity — "opp-<localID>" and key = remoteID ?? recordName

    func testOpportunityRecordNameFormat() {
        let opp = Opportunity(localID: uuid)
        XCTAssertEqual(opp.recordName, "opp-\(uuid.uuidString)")
    }

    func testOpportunityKeyFallsBackToRecordNameWhenUnpublished() {
        let opp = Opportunity(localID: uuid, remoteID: nil)
        XCTAssertEqual(opp.key, "opp-\(uuid.uuidString)")
    }

    func testOpportunityKeyPrefersRemoteIDOncePublished() {
        let opp = Opportunity(localID: uuid, remoteID: "published-record-name")
        XCTAssertEqual(opp.key, "published-record-name")
    }

    // MARK: OpportunityApplication — "oppapp-<oppKey>-<applicantID>" (apply-once)

    func testApplicationRecordNameFormat() {
        let app = OpportunityApplication(opportunityID: "opp-KEY", applicantID: "user-9")
        XCTAssertEqual(app.recordName, "oppapp-opp-KEY-user-9")
    }

    func testApplicationRecordNameIsStablePerApplicantPerOpportunity() {
        // Re-applying to the same opportunity resolves to the same record → apply-once, not spam.
        let a = OpportunityApplication(opportunityID: "opp-KEY", applicantID: "user-9")
        let b = OpportunityApplication(opportunityID: "opp-KEY", applicantID: "user-9", note: "second try")
        XCTAssertEqual(a.recordName, b.recordName)
    }

    // MARK: ApplicationDecision — "oppdec-<oppKey>-<applicantID>" (upsert as stage advances)

    func testDecisionRecordNameFormat() {
        let dec = ApplicationDecision(opportunityID: "opp-KEY", applicantID: "user-9")
        XCTAssertEqual(dec.recordName, "oppdec-opp-KEY-user-9")
    }

    func testDecisionRecordNameStableAcrossStageChanges() {
        // Advancing applied → offer must UPSERT the same record, not create a new one per stage.
        let applied = ApplicationDecision(opportunityID: "opp-KEY", applicantID: "user-9", stage: .applied)
        let offered = ApplicationDecision(opportunityID: "opp-KEY", applicantID: "user-9", stage: .offer)
        XCTAssertEqual(applied.recordName, offered.recordName)
    }

    // MARK: Cross-record wiring — an application and its decision share the same (oppKey, applicant)

    func testApplicationAndDecisionAgreeOnKeyComponents() {
        let oppKey = "opp-\(uuid.uuidString)"
        let app = OpportunityApplication(opportunityID: oppKey, applicantID: "lina")
        let dec = ApplicationDecision(opportunityID: oppKey, applicantID: "lina")
        // Both must key off the identical (opportunity, applicant) pair so the poster's decision lands
        // on exactly the application it answers.
        XCTAssertEqual(app.opportunityID, dec.opportunityID)
        XCTAssertEqual(app.applicantID, dec.applicantID)
    }
}
