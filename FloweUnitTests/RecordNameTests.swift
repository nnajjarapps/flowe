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

    // MARK: AccountRole — "role-<ownerID>" (cross-device role guard)

    func testAccountRoleRecordNameFormat() {
        XCTAssertEqual(AccountRoleService.recordName(for: "user-9"), "role-user-9")
    }

    func testAccountRoleRecordNameDoesNotCollideWithBareOwnerID() {
        // InstructorListing keys on the BARE ownerID in the same public zone; the claim MUST be
        // namespaced or the two collide (the StudentDirectoryService hazard). See AccountRoleService.
        let ownerID = "user-9"
        XCTAssertNotEqual(AccountRoleService.recordName(for: ownerID), ownerID)
    }

    // MARK: Role gate — one Apple ID acts as ONE role at a time (switchable, never divergent)

    func testRoleGateNewAccountProceedsAndClaims() {
        let g = AppSession.roleGate(desired: .student, established: .none)
        XCTAssertTrue(g.proceed)
        XCTAssertTrue(g.claim)              // brand-new → write the claim
        XCTAssertNil(g.existing)
    }

    func testRoleGateMatchingClaimProceedsWithoutRewriting() {
        let g = AppSession.roleGate(desired: .instructor, established: .claimed(.instructor))
        XCTAssertTrue(g.proceed)
        XCTAssertFalse(g.claim)             // already correct → no rewrite
    }

    func testRoleGateConflictingClaimBlocks() {
        // The Elissa case: this Apple ID is an instructor; a second device tries to sign in as a student.
        let g = AppSession.roleGate(desired: .student, established: .claimed(.instructor))
        XCTAssertFalse(g.proceed)           // blocked before any split-brain is created
        XCTAssertEqual(g.existing, .instructor)
    }

    func testRoleGateUnreachableFailsOpenButNeverClaims() {
        // Offline: proceed as chosen so a legit user isn't stranded, but DON'T write a claim — a transient
        // read failure must not overwrite a real one. reconcileRole() repairs it on next foreground.
        let g = AppSession.roleGate(desired: .student, established: .unavailable)
        XCTAssertTrue(g.proceed)
        XCTAssertFalse(g.claim)
    }

    // MARK: Account-deletion sweep — every predicated field MUST be QUERYABLE in the schema
    //
    // AccountDeletionService enumerates a user's records by field predicates. If a queried field is not
    // QUERYABLE in the DEPLOYED (Production) schema, CloudKit returns `.invalidArguments` and those
    // records SURVIVE deletion — silently. This test locks `CloudKit-dev-schema.ckdb` (the importable
    // Dev→Prod source of truth) so a missing index fails CI, not a user's account deletion. It is the
    // compile-time guard behind the `recordIDs()` `.invalidArguments` hardening.

    /// (recordType, predicated field) pairs AccountDeletionService.deleteAllRecords queries on. Keep in
    /// sync with the predicates there — a new sweep predicate MUST be added here (and marked QUERYABLE).
    private static let deletionSweepFields: [(type: String, field: String)] = [
        (MessagingService.recordType, "senderID"),
        (MessagingService.readReceiptRecordType, "readerID"),
        (BookingService.bookingRecordType, "studentID"),
        (BookingService.bookingRecordType, "instructorID"),
        (ReviewService.recordType, "studentID"),
        (CommunityService.postRecordType, "authorID"),
        (CommunityService.likeRecordType, "authorID"),
        (CommunityService.commentRecordType, "authorID"),
        (CommunityService.followRecordType, "followerID"),
        (EventService.eventRecordType, "organizerID"),
        (EventService.registrationRecordType, "studentID"),
        (EventService.decisionRecordType, "organizerID"),
        (LessonTypeService.recordType, "ownerID"),
        (OpportunityService.recordType, "posterID"),
        (OpportunityService.applicationRecordType, "applicantID"),
        (OpportunityService.decisionRecordType, "posterID"),
        (RecommendationService.recordType, "fromID"),
        (CoverageService.requestRecordType, "requesterID"),
        (CoverageService.offerRecordType, "requesterID"),
        (CoverageService.claimRecordType, "replacerID"),
        (CoverageService.sessionRecordType, "requesterID"),
    ]

    func testDeletionSweepFieldsAreQueryableInSchema() throws {
        // Locate the ckdb at the repo root, relative to this source file (…/flowe/FloweUnitTests/<this>).
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let schemaURL = repoRoot.appendingPathComponent("CloudKit-dev-schema.ckdb")
        let schema = try String(contentsOf: schemaURL, encoding: .utf8)

        for (type, field) in Self.deletionSweepFields {
            guard let block = Self.recordTypeBlock(named: type, in: schema) else {
                XCTFail("CloudKit-dev-schema.ckdb has no `RECORD TYPE \(type)`, but account deletion sweeps it by `\(field)`.")
                continue
            }
            XCTAssertTrue(Self.fieldIsQueryable(field, inBlock: block),
                "\(type).\(field) is queried by AccountDeletionService but is NOT marked QUERYABLE in the schema — its records would survive deletion (CKError.invalidArguments). Add QUERYABLE and deploy to Production.")
        }
    }

    /// The body of a `RECORD TYPE <name> ( … );` block, or nil if absent.
    private static func recordTypeBlock(named type: String, in schema: String) -> String? {
        guard let start = schema.range(of: "RECORD TYPE \(type) ("),
              let end = schema.range(of: ");", range: start.upperBound..<schema.endIndex) else { return nil }
        return String(schema[start.upperBound..<end.lowerBound])
    }

    /// Whether a `<field> TYPE … QUERYABLE …,` line in the block marks `field` QUERYABLE. Matches the
    /// field only at a token boundary so `poster` never matches `posterID`.
    private static func fieldIsQueryable(_ field: String, inBlock block: String) -> Bool {
        for raw in block.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == field || line.hasPrefix(field + " ") || line.hasPrefix(field + "\t") {
                return line.contains("QUERYABLE")
            }
        }
        return false
    }
}
