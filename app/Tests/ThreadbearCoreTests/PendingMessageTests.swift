import XCTest
@testable import ThreadbearCore

/// A message sent from the app shows at once, dimmed, and gives way to the
/// runner's own `user.message` for it.
final class PendingMessageTests: XCTestCase {
    private func history() -> TranscriptModel {
        TranscriptModel(events: [
            E.event(1, "turn.started", ["turnId": "t1"]),
            E.user(2, "yes"),
            E.text(3, "m1", "Done."),
            E.done(4),
        ])
    }

    func testAPendingMessageIsTheLastRowUntilItsUserMessageArrives() {
        var model = history()
        let pending = PendingMessage(id: "a", text: "Ship it", afterSeq: 4)
        var change = model.setPending([pending])
        XCTAssertEqual(change.inserted, [3])
        XCTAssertEqual(model.rows.map(\.id), ["u:2", "a:m1", "f:t1", "p:a"])
        guard case .user(let message) = model.rows[3].content else { return XCTFail() }
        XCTAssertEqual(message.text, "Ship it")
        XCTAssertEqual(message.pending, .sending)
        XCTAssertFalse(message.editable, "it isn't in the thread yet")
        XCTAssertTrue(model.items.allSatisfy { !$0.id.hasPrefix("p:") }, "only a row: copying the thread leaves it out")

        // The runner shows it: the real row takes its place in one change.
        change = model.apply([E.event(5, "turn.started", ["turnId": "t2"], turn: "t2"), E.event(6, "user.message", ["text": "Ship it", "images": []], turn: "t2")])
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertEqual(model.rows.map(\.id), ["u:2", "a:m1", "f:t1", "u:6", "w:t2"])
        XCTAssertTrue(change.removed.contains(3))
    }

    /// Under a running turn's working line, as a queued message waits for
    /// that turn; the runner queuing it turns its spinner into a clock.
    func testItSitsUnderTheWorkingLineAndShowsWhenQueued() {
        var model = TranscriptModel(events: [E.event(1, "turn.started", ["turnId": "t1"]), E.user(2, "Build it")])
        var pending = PendingMessage(id: "a", text: "And the docs", afterSeq: 2)
        _ = model.setPending([pending])
        XCTAssertEqual(model.rows.map(\.id), ["u:2", "w:t1", "p:a"])
        let version = model.rows[2].version
        pending.queued = true
        let change = model.setPending([pending])
        XCTAssertEqual(change.updated, [2])
        XCTAssertGreaterThan(model.rows[2].version, version)
        guard case .user(let message) = model.rows[2].content else { return XCTFail() }
        XCTAssertEqual(message.pending, .queued)
        XCTAssertTrue(model.setPending([pending]).isEmpty, "nothing changed")
    }

    /// The same words earlier in the thread aren't it, nor is a message the
    /// runner, a schedule, the phone or an edit sent.
    func testOnlyALaterMessageOfMikesFromTheAppCounts() {
        var model = history()
        _ = model.setPending([PendingMessage(id: "a", text: "yes", afterSeq: 4)])
        XCTAssertEqual(model.pending.count, 1, "the yes at seq 2 came before it")
        _ = model.apply([
            E.event(5, "user.message", ["text": "yes", "images": [], "origin": "runner"]),
            E.event(6, "user.message", ["text": "yes", "images": [], "origin": "phone"]),
            E.event(7, "user.message", ["text": "yes", "images": [], "editOf": 2]),
        ])
        XCTAssertEqual(model.pending.count, 1)
        _ = model.apply([E.user(8, "yes")])
        XCTAssertTrue(model.pending.isEmpty)
    }

    /// Two sends of the same words need two messages from the runner.
    func testEachUserMessageTakesOne() {
        var model = history()
        _ = model.setPending([PendingMessage(id: "a", text: "go", afterSeq: 4), PendingMessage(id: "b", text: "go", afterSeq: 4)])
        _ = model.apply([E.user(5, "go")])
        XCTAssertEqual(model.pending.map(\.id), ["b"])
        XCTAssertEqual(model.rows.last?.id, "p:b")
    }

    /// Pictures match by count: the runner copies them under new paths.
    func testPicturesMatchByCount() {
        var model = history()
        let image = ImageRef(path: "/tmp/inbox/a.png", mediaType: "image/png")
        _ = model.setPending([PendingMessage(id: "a", text: "", images: [image], afterSeq: 4)])
        guard case .user(let message) = model.rows.last?.content else { return XCTFail() }
        XCTAssertEqual(message.images, [image], "the picture shows while it's on its way")
        _ = model.apply([E.event(5, "user.message", ["text": "", "images": []])])
        XCTAssertEqual(model.pending.count, 1)
        _ = model.apply([E.event(6, "user.message", ["text": "", "images": [["path": "/media/a.png", "mediaType": "image/png"]]])])
        XCTAssertTrue(model.pending.isEmpty)
    }

    /// A reload (the thread opened again, a catch-up) that already holds
    /// the message drops it; one that doesn't keeps it.
    func testAReloadThatHoldsItDropsIt() {
        var model = history()
        _ = model.setPending([PendingMessage(id: "a", text: "Ship it", afterSeq: 4), PendingMessage(id: "b", text: "Later", afterSeq: 4)])
        model.load(events: [E.event(1, "turn.started", ["turnId": "t1"]), E.user(2, "yes"), E.done(4), E.user(5, "Ship it")])
        XCTAssertEqual(model.pending.map(\.id), ["b"])
        XCTAssertEqual(model.rows.last?.id, "p:b")
        // Set again from the app's side with both: the one shown stays out.
        _ = model.setPending([PendingMessage(id: "a", text: "Ship it", afterSeq: 4), PendingMessage(id: "b", text: "Later", afterSeq: 4)])
        XCTAssertEqual(model.pending.map(\.id), ["b"])
    }

    /// An edit drops the messages queued behind it on the runner, so the
    /// queued ones go here too; one still on its way stays.
    func testAnEditDropsQueuedOnes() {
        var model = history()
        _ = model.setPending([PendingMessage(id: "a", text: "queued", afterSeq: 4, queued: true), PendingMessage(id: "b", text: "sending", afterSeq: 4)])
        _ = model.apply([E.event(5, "thread.rewound", ["fromSeq": 2, "toSeq": 4, "files": ["undone": [], "failed": [], "how": "none"]], turn: nil)])
        XCTAssertEqual(model.pending.map(\.id), ["b"])
        XCTAssertEqual(model.rows.last?.id, "p:b")
    }

    func testClearingTakesTheRowsAway() {
        var model = history()
        _ = model.setPending([PendingMessage(id: "a", text: "Ship it", afterSeq: 4)])
        let change = model.setPending([])
        XCTAssertEqual(change.removed, [3])
        XCTAssertEqual(model.rows.map(\.id), ["u:2", "a:m1", "f:t1"])
    }

    /// Opening a group near the top doesn't touch the rows at the end.
    func testPendingRowsSurviveAnUpdateInPlace() {
        var model = TranscriptModel(events: [
            E.event(1, "turn.started", ["turnId": "t1"]),
            E.user(2, "Look"),
            E.call(3, "c1"), E.result(4, "c1"),
            E.call(5, "c2"), E.result(6, "c2"),
            E.text(7, "m1", "Looked."),
            E.done(8),
        ])
        _ = model.setPending([PendingMessage(id: "a", text: "Thanks", afterSeq: 8)])
        _ = model.setExpanded("g:t:c1", true)
        XCTAssertEqual(model.rows.last?.id, "p:a")
        _ = model.setExpanded("g:t:c1", false)
        XCTAssertEqual(model.rows.map(\.id), ["u:2", "g:t:c1", "a:m1", "f:t1", "p:a"])
    }
}
