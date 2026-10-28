import XCTest
@testable import ThreadbearCore

/// Editing a message (docs/protocol.md, "Editing a message"): the cut
/// events make no rows, and only Mike's turn-starting messages can be edited.
final class MessageEditTests: XCTestCase {
    /// A message that starts its turn, as the runner writes it: the
    /// user.message, then turn.started with the same turnId.
    private func turn(_ seq: Int, _ id: String, _ text: String, reply: String) -> [Event] {
        [
            E.event(seq, "user.message", ["text": text, "images": []], turn: id),
            E.event(seq + 1, "turn.started", ["turnId": id], turn: id),
            E.event(seq + 2, "assistant.text", ["itemId": "m\(seq)", "text": reply], turn: id),
            E.done(seq + 3, turn: id),
        ]
    }

    private func rewound(_ seq: Int, from: Int, undone: [String] = [], failed: [[String: Any]] = []) -> Event {
        E.event(seq, "thread.rewound", ["fromSeq": from, "toSeq": seq - 1, "files": ["undone": undone, "failed": failed, "how": "checkpoint"]], turn: nil)
    }

    private func edited(_ seq: Int, _ id: String, _ text: String, editOf: Int) -> Event {
        E.event(seq, "user.message", ["text": text, "images": [], "editOf": editOf], turn: id)
    }

    func testDecodesRewindAndEditOf() {
        let event = rewound(9, from: 5, undone: ["/a/b.ts"], failed: [["path": "/a/c.ts", "reason": "it changed since"]])
        guard case .threadRewound(let rewind) = event.payload else { return XCTFail("\(event.payload)") }
        XCTAssertEqual(rewind.range, 5...8)
        XCTAssertEqual(rewind.undone, ["/a/b.ts"])
        XCTAssertEqual(rewind.failed, [ThreadRewind.FailedFile(path: "/a/c.ts", reason: "it changed since")])
        XCTAssertEqual(rewind.how, "checkpoint")
        XCTAssertEqual(rewind.summary, "Edited a message, so the thread carries on from there. Undid changes to 1 file. Couldn't undo c.ts (it changed since).")
        guard case .userMessage(_, _, _, _, let editOf) = edited(10, "t3", "x", editOf: 5).payload else { return XCTFail() }
        XCTAssertEqual(editOf, 5)
    }

    func testCutEventsMakeNoRows() {
        let events = turn(1, "t1", "One", reply: "First") + turn(5, "t2", "Two", reply: "Second")
            + [rewound(9, from: 5), edited(10, "t3", "Two, better", editOf: 5)]
        let model = TranscriptModel(events: events)
        XCTAssertEqual(model.items.map(\.id), ["u:1", "a:m1", "f:t1", "rw:9", "u:10"])
        XCTAssertTrue(model.isHidden(6))
        XCTAssertFalse(model.isHidden(9))
        guard case .note(let note) = model.item(id: "rw:9")?.content else { return XCTFail() }
        XCTAssertEqual(note, "Edited a message, so the thread carries on from there.")
    }

    /// Live: the rewind arrives after the rows it cuts are showing. The
    /// table reloads, and what came after it goes on as usual.
    func testLiveRewindRemovesShownRows() {
        var model = TranscriptModel(events: turn(1, "t1", "One", reply: "First") + turn(5, "t2", "Two", reply: "Second"))
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "a:m1", "f:t1", "u:5", "a:m5", "f:t2"])
        let change = model.apply([rewound(9, from: 5, undone: ["/x.ts", "/y.ts"])])
        XCTAssertEqual(change.removed, IndexSet(integersIn: 0..<6))
        XCTAssertEqual(change.inserted, IndexSet(integersIn: 0..<model.rows.count))
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "a:m1", "f:t1", "rw:9"])
        _ = model.apply([edited(10, "t3", "Two, better", editOf: 5), E.event(11, "turn.started", ["turnId": "t3"], turn: "t3")])
        XCTAssertEqual(model.rows.map(\.id).prefix(5), ["u:1", "a:m1", "f:t1", "rw:9", "u:10"])
    }

    /// Paging: the newest page holds the marker, and the older page with
    /// the start of the cut range comes later. Its cut events stay hidden.
    func testOlderPageKeepsCutEventsHidden() {
        let all = turn(1, "t1", "One", reply: "First") + turn(5, "t2", "Two", reply: "Second") + turn(9, "t3", "Three", reply: "Third")
            + [rewound(13, from: 5), edited(14, "t4", "Two again", editOf: 5)]
        var model = TranscriptModel(events: Array(all.filter { $0.seq >= 7 }))
        XCTAssertEqual(model.items.map(\.id), ["rw:13", "u:14"])
        model.prepend(olderEvents: all.filter { $0.seq < 7 })
        XCTAssertEqual(model.items.map(\.id), ["u:1", "a:m1", "f:t1", "rw:13", "u:14"])
    }

    /// A second edit further back cuts over the first edit's marker too.
    func testLaterEditCutsAcrossAnEarlierOne() {
        let events = turn(1, "t1", "One", reply: "First") + turn(5, "t2", "Two", reply: "Second")
            + [rewound(9, from: 5), edited(10, "t3", "Two, better", editOf: 5), E.event(11, "turn.started", ["turnId": "t3"], turn: "t3"), E.done(12, turn: "t3")]
            + [rewound(13, from: 1), edited(14, "t4", "One, better", editOf: 1)]
        let model = TranscriptModel(events: events)
        XCTAssertEqual(model.items.map(\.id), ["rw:13", "u:14"])
        XCTAssertEqual(model.hidden, [1...12, 5...8])
    }

    func testOnlyMikesTurnStartingMessagesAreEditable() {
        let events: [Event] = [
            E.event(1, "user.message", ["text": "Start", "images": []], turn: "t1"),
            E.event(2, "turn.started", ["turnId": "t1"], turn: "t1"),
            // Sent into the running turn.
            E.event(3, "user.message", ["text": "Also this", "images": []], turn: "t1"),
            E.done(4, turn: "t1"),
            E.event(5, "user.message", ["text": "Runner restarted", "images": [], "origin": "runner"], turn: "t2"),
            E.event(6, "turn.started", ["turnId": "t2"], turn: "t2"),
            E.done(7, turn: "t2"),
            E.event(8, "user.message", ["text": "From the phone", "images": [], "origin": "phone"], turn: "t3"),
            E.event(9, "turn.started", ["turnId": "t3"], turn: "t3"),
            E.done(10, turn: "t3"),
            E.event(11, "user.message", ["text": "[Sent by the agent in the thread \"Other\" (ab12cd34)]\nHello", "images": []], turn: "t4"),
            E.event(12, "turn.started", ["turnId": "t4"], turn: "t4"),
            E.done(13, turn: "t4"),
            E.event(14, "user.message", ["text": "Scheduled", "images": [], "origin": "schedule"], turn: "t5"),
            E.event(15, "turn.started", ["turnId": "t5"], turn: "t5"),
            E.done(16, turn: "t5"),
            E.event(17, "user.message", ["text": "No turn id", "images": []], turn: nil),
        ]
        let model = TranscriptModel(events: events)
        let editable = model.items.compactMap { row -> Int? in
            guard case .user(let message) = row.content, message.editable else { return nil }
            return row.seq
        }
        XCTAssertEqual(editable, [1, 8])
    }
}
