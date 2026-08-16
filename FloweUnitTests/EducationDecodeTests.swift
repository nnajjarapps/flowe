import XCTest
import CloudKit
@testable import Flowe

/// Locks the Flowe Education CloudKit **decode contract** — the `RemoteProgram`/`RemoteVideoExercise`
/// field mapping off a public `CKRecord`, and the `ownerID` guard that drops an unattributable row (the
/// same class of bug the wire-decode tests lock for the backend DTOs). A `CKRecord` is built locally here,
/// with no CloudKit connection.
final class EducationDecodeTests: XCTestCase {

    func testProgramDecodesFromRecord() throws {
        let record = CKRecord(recordType: ProgramService.recordType,
                              recordID: CKRecord.ID(recordName: "program-abc"))
        record["ownerID"] = "ins-1"
        record["title"] = "Beginner Reformer"
        record["summary"] = "For newcomers"
        record["order"] = 2
        record["hasCover"] = 1
        record["createdAt"] = Date(timeIntervalSince1970: 100)
        record["updatedAt"] = Date(timeIntervalSince1970: 200)

        let program = try XCTUnwrap(RemoteProgram(record: record))
        XCTAssertEqual(program.id, "program-abc")           // recordName → id
        XCTAssertEqual(program.ownerID, "ins-1")            // the attribution key
        XCTAssertEqual(program.title, "Beginner Reformer")
        XCTAssertEqual(program.summary, "For newcomers")
        XCTAssertEqual(program.order, 2)
        XCTAssertTrue(program.hasCover)                     // Int 1 → true
    }

    func testProgramWithoutOwnerIDIsDropped() {
        let record = CKRecord(recordType: ProgramService.recordType,
                              recordID: CKRecord.ID(recordName: "program-x"))
        record["title"] = "no owner"                        // no ownerID → unattributable
        XCTAssertNil(RemoteProgram(record: record))
    }

    func testExerciseDecodesFromRecord() throws {
        let record = CKRecord(recordType: ExerciseService.recordType,
                              recordID: CKRecord.ID(recordName: "exercise-xyz"))
        record["ownerID"] = "ins-1"
        record["programID"] = "program-abc"
        record["title"] = "Reformer Foundations"
        record["coachingNotes"] = "Light spring"
        record["prescription"] = "3x10"
        record["focus"] = "core,mobility"
        record["level"] = "beginner"
        record["order"] = 0
        record["durationSeconds"] = 724
        record["hasThumbnail"] = 1
        record["hasVideo"] = 1
        record["createdAt"] = Date(timeIntervalSince1970: 10)
        record["updatedAt"] = Date(timeIntervalSince1970: 20)

        let exercise = try XCTUnwrap(RemoteVideoExercise(record: record))
        XCTAssertEqual(exercise.id, "exercise-xyz")
        XCTAssertEqual(exercise.ownerID, "ins-1")
        XCTAssertEqual(exercise.programID, "program-abc")   // links a child to its program's record key
        XCTAssertEqual(exercise.title, "Reformer Foundations")
        XCTAssertEqual(exercise.coachingNotes, "Light spring")
        XCTAssertEqual(exercise.prescription, "3x10")
        XCTAssertEqual(exercise.focus, "core,mobility")
        XCTAssertEqual(exercise.level, "beginner")
        XCTAssertEqual(exercise.durationSeconds, 724)
        XCTAssertTrue(exercise.hasThumbnail)
        XCTAssertTrue(exercise.hasVideo)
    }

    func testExerciseWithoutOwnerIDIsDropped() {
        let record = CKRecord(recordType: ExerciseService.recordType,
                              recordID: CKRecord.ID(recordName: "exercise-x"))
        record["title"] = "no owner"
        XCTAssertNil(RemoteVideoExercise(record: record))
    }

    /// `Program.recordKey` is what a child exercise's `programID` references, so it MUST be stable across
    /// devices: the deterministic name before delivery, the delivered `remoteID` after (they are equal),
    /// never `localID` (a merged copy mints a fresh one).
    func testProgramRecordKeyIsStable() {
        let program = Program(ownerID: "ins-1", title: "P")
        XCTAssertEqual(program.recordKey, "program-\(program.localID.uuidString)")  // pre-delivery
        program.remoteID = "program-\(program.localID.uuidString)"
        XCTAssertEqual(program.recordKey, program.remoteID)                          // post-delivery == same
    }
}
