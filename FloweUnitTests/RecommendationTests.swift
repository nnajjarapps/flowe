import XCTest
@testable import Flowe

/// Locks Flowe Pro **Phase 5** peer recommendations: the deterministic `rec-<from>-<to>` recordName
/// (one endorsement per author→recipient pair, so re-writing upserts) and the pure filter behind an
/// instructor profile's recommendation list (addressed-to match, blocked-author exclusion, newest-first).
final class RecommendationTests: XCTestCase {

    // MARK: recordName — deterministic, upsert-friendly

    func testRecordNameFormat() {
        XCTAssertEqual(InstructorRecommendation.recordName(from: "maya", to: "noa"), "rec-maya-noa")
    }

    func testInstanceRecordNameMatchesStatic() {
        let rec = InstructorRecommendation(fromID: "maya", toID: "noa")
        XCTAssertEqual(rec.recordName, InstructorRecommendation.recordName(from: "maya", to: "noa"))
    }

    func testRecordNameIsStablePerPair() {
        // Re-writing the same endorsement resolves to the same record → edit, not duplicate.
        let a = InstructorRecommendation(fromID: "maya", toID: "noa", text: "first")
        let b = InstructorRecommendation(fromID: "maya", toID: "noa", text: "edited")
        XCTAssertEqual(a.recordName, b.recordName)
    }

    func testRecordNameDistinguishesDirection() {
        // Maya→Noa and Noa→Maya are different endorsements.
        let forward = InstructorRecommendation(fromID: "maya", toID: "noa")
        let reverse = InstructorRecommendation(fromID: "noa", toID: "maya")
        XCTAssertNotEqual(forward.recordName, reverse.recordName)
    }

    // MARK: recommendations(for:) — the profile's endorsement list

    private func rec(from: String, to: String, at created: TimeInterval = 0) -> InstructorRecommendation {
        InstructorRecommendation(fromID: from, fromName: from, toID: to,
                                 createdAt: Date(timeIntervalSince1970: created))
    }

    func testKeepsOnlyRecommendationsAddressedToThisInstructor() {
        let all = [rec(from: "a", to: "noa"), rec(from: "b", to: "someone-else"), rec(from: "c", to: "noa")]
        let result = MockDataStore.recommendations(all, for: "noa", blocked: [])
        XCTAssertEqual(Set(result.map(\.fromID)), ["a", "c"])
    }

    func testExcludesBlockedAuthors() {
        let all = [rec(from: "a", to: "noa"), rec(from: "blocked-peer", to: "noa")]
        let result = MockDataStore.recommendations(all, for: "noa", blocked: ["blocked-peer"])
        XCTAssertEqual(result.map(\.fromID), ["a"])
    }

    func testSortsNewestFirst() {
        let all = [rec(from: "old", to: "noa", at: 100),
                   rec(from: "new", to: "noa", at: 300),
                   rec(from: "mid", to: "noa", at: 200)]
        let result = MockDataStore.recommendations(all, for: "noa", blocked: [])
        XCTAssertEqual(result.map(\.fromID), ["new", "mid", "old"])
    }

    func testEmptyWhenNoneAddressedToInstructor() {
        let all = [rec(from: "a", to: "someone-else")]
        XCTAssertTrue(MockDataStore.recommendations(all, for: "noa", blocked: []).isEmpty)
    }
}
