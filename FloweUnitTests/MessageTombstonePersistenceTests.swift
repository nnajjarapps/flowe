import XCTest
import SwiftData
@testable import Flowe

/// Locks the "delete for everyone" tombstone to the STORE.
///
/// Written after a session spent chasing a deleted message that rendered as a blank bubble on both
/// devices. Instrumentation showed the merge setting `deleted = true`, `context.save()` succeeding, and
/// the value being `false` again by the time `refresh()` re-read it. Three hypotheses about WHY were
/// wrong in a row, so this pins the one thing that can be asserted rather than reasoned about: does the
/// flag survive a save and a re-fetch at all?
final class MessageTombstonePersistenceTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Message.self, configurations: config)
        return ModelContext(container)
    }

    /// The flag must survive `save()` + a fresh fetch. If this fails, persistence is the bug and every
    /// in-place mutation in `merge` is suspect, not just this one.
    func testDeletedFlagSurvivesSaveAndRefetch() throws {
        let context = try makeContext()
        let m = Message(remoteID: "msg-1", conversationID: "a~b", senderID: "a", recipientID: "b", text: "hi")
        context.insert(m)
        try context.save()

        // Exactly what `merge` does to an existing row when the counterpart deletes for everyone.
        m.deleted = true
        m.text = ""
        try context.save()

        let refetched = try context.fetch(FetchDescriptor<Message>())
        XCTAssertEqual(refetched.count, 1)
        XCTAssertTrue(refetched.first?.deleted == true, "the tombstone did not survive save + re-fetch")
        XCTAssertEqual(refetched.first?.text, "")
    }

    /// The same flip performed through a lookup by `remoteID`, which is how `merge` finds the row —
    /// guarding against the mutation landing on a different instance than the one re-read.
    func testFlipViaRemoteIDLookupPersists() throws {
        let context = try makeContext()
        context.insert(Message(remoteID: "msg-2", conversationID: "a~b", senderID: "a", recipientID: "b", text: "hi"))
        try context.save()

        var rows = try context.fetch(FetchDescriptor<Message>())
        guard let local = rows.first(where: { $0.remoteID == "msg-2" }) else {
            return XCTFail("row not found by remoteID")
        }
        local.deleted = true
        try context.save()

        rows = try context.fetch(FetchDescriptor<Message>())
        XCTAssertTrue(rows.first(where: { $0.remoteID == "msg-2" })?.deleted == true)
    }

    /// `displayText` must not leak ciphertext for a tombstoned row, whatever `text` holds.
    func testTombstonedRowNeverShowsCiphertext() throws {
        let m = Message(remoteID: "msg-3", conversationID: "a~b", senderID: "a", recipientID: "b",
                        text: "enc.v1.SOMECIPHERTEXT")
        m.deleted = true
        XCTAssertFalse(m.displayText.contains("SOMECIPHERTEXT"))
    }
}
