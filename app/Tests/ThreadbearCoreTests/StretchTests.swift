import XCTest
@testable import ThreadbearCore

/// A finished stretch: Mike's message, the turn it started and the
/// runner's turns after it (the app restarted, a hook ran, a resume) show
/// as one line of work and one reply (Mike, 29 Oct: two summaries with
/// the restart notes between them, and he couldn't tell which to read).
final class StretchTests: XCTestCase {
    static func runner(_ seq: Int, _ text: String, turn: String) -> Event {
        E.event(seq, "user.message", ["text": text, "images": [], "origin": "runner"], turn: turn)
    }

    static func mike(_ seq: Int, _ text: String, turn: String, origin: String? = nil) -> Event {
        var fields: [String: Any] = ["text": text, "images": []]
        if let origin { fields["origin"] = origin }
        return E.event(seq, "user.message", fields, turn: turn)
    }

    static func note(_ seq: Int, _ text: String) -> Event {
        E.event(seq, "system.note", ["text": text], turn: nil)
    }

    static func summary(_ seq: Int, _ item: String, _ text: String, turn: String) -> Event {
        WorkLinksTests.summary(seq, item, text, turn: turn)
    }

    /// Mike's message, a turn that merges and waits for the app, the
    /// restart note, and the runner's turn that checks it.
    static let restartCheck: [Event] = [
        mike(1, "Say Archived", turn: "t1"),
        note(2, "Put in Threadbear by the librarian."),
        E.call(3, "c1", input: ["command": "./check.sh --app"]).withTurn("t1"), E.result(4, "c1").withTurn("t1"),
        WorkGroupTests.edit(5, "c2", path: "/r/Sections.swift").withTurn("t1"), E.result(6, "c2").withTurn("t1"),
        summary(7, "e1.summary", "- Merged; I'll check it after the restart.", turn: "t1"),
        E.done(8, turn: "t1"),
        note(9, "Threadbear app restarted: 3929d8e to c95c95a"),
        runner(10, "The Threadbear app has restarted onto c95c95a.", turn: "t2"),
        E.call(11, "c3", input: ["command": "cat build.json"]).withTurn("t2"), E.result(12, "c3").withTurn("t2"),
        summary(13, "e2.summary", "- Renamed it; [checks pass](work:./check.sh --app); it's live.", turn: "t2"),
        E.done(14, turn: "t2"),
    ]

    func testTheRunnersTurnJoinsTheTurnBeforeIt() {
        let model = TranscriptModel(events: Self.restartCheck)
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "g:n:2", "a:e2.summary", "f:t2"])
        guard case .group(let group)? = model.row(id: "g:n:2")?.content else { return XCTFail("a group") }
        XCTAssertEqual(group.memberIds, ["n:2", "t:c1", "t:c2", "a:e1.summary", "n:9", "u:10", "t:c3"],
                       "the earlier summary, the notes and the runner's message fold into the work")
        XCTAssertEqual(group.summary, "Worked for 8s", "both turns' time")
        guard case .footer(let done)? = model.row(id: "f:t2")?.content else { return XCTFail("a footer") }
        XCTAssertEqual(done.durationMs, 8400)
        XCTAssertEqual(done.costUsd ?? 0, 0.24, accuracy: 0.0001)
        XCTAssertNil(model.row(id: "cf:t2"), "a summarized stretch has no changes card")
    }

    /// A background job ended after the agent had replied, and the CLI woke
    /// it on its own: no message from anyone, so nothing replaced the reply
    /// (1 Nov 2026, thread 9bc89060, where a timed-out wait put "still waiting
    /// on you" in place of a picture he'd asked for).
    static func final(_ seq: Int, _ item: String, _ text: String, turn: String) -> Event {
        E.event(seq, "assistant.text", ["itemId": item, "text": text, "final": true], turn: turn)
    }

    static func text(_ seq: Int, _ item: String, _ words: String, turn: String) -> Event {
        E.event(seq, "assistant.text", ["itemId": item, "text": words], turn: turn)
    }

    static func endTurn(_ seq: Int, _ id: String, turn: String) -> [Event] {
        [E.call(seq, id, name: "mcp__threadbear__end_turn", input: ["needs": "you"]).withTurn(turn),
         E.result(seq + 1, id, text: "Noted: this thread will wait in Needs you.").withTurn(turn)]
    }

    func testAWakeUpAfterAReplyLeavesTheReplyOnShow() {
        let first: [Event] = [
            Self.mike(1, "Draw a bear", turn: "t1"),
            E.call(2, "c1", input: ["command": "swift draw.swift"]).withTurn("t1"), E.result(3, "c1").withTurn("t1"),
        ] + Self.endTurn(4, "e1", turn: "t1") + [
            Self.final(6, "m1", "Here's a test bear.", turn: "t1"),
            E.done(7, turn: "t1"),
        ]
        // As it happened: the wake-up wrote a line, was sent back for end_turn
        // and wrote another. And as it goes now: the line is that turn's reply.
        let wrote: [Event] = first + [
            E.event(8, "turn.started", [:], turn: "t2"),
            E.event(9, "system.note", ["text": "Background command stopped"], turn: "t2"),
            Self.text(10, "m2", "That wait hit its limit, which changes nothing.", turn: "t2"),
        ] + Self.endTurn(11, "e2", turn: "t2")
        let twice = wrote + [Self.final(13, "m3", "Still waiting on you.", turn: "t2"), E.done(14, turn: "t2")]
        var rows = TranscriptModel(events: twice).rows.map(\.id)
        XCTAssertTrue(rows.contains("a:m1"), "the real reply stays: \(rows)")
        XCTAssertTrue(rows.contains("a:m3"), "\(rows)")
        XCTAssertFalse(rows.contains("a:m2"), "\(rows)")
        rows = TranscriptModel(events: wrote + [E.done(13, turn: "t2")]).rows.map(\.id)
        XCTAssertTrue(rows.contains("a:m1"), "\(rows)")
        XCTAssertTrue(rows.contains("a:m2"), "\(rows)")
    }

    /// The runner's own turns take the last summary's place, as their
    /// end_turn is told to cover the stretch. A wake-up isn't one of them.
    func testAWakeUpsSummaryDoesntTakeTheReplysPlace() {
        let events: [Event] = [
            Self.mike(1, "Fix it", turn: "t1"),
            E.call(2, "c1", input: ["command": "make"]).withTurn("t1"), E.result(3, "c1").withTurn("t1"),
            Self.summary(4, "e1.summary", "- Fixed it, and here's what was wrong.", turn: "t1"),
            E.done(5, turn: "t1"),
            E.event(6, "turn.started", [:], turn: "t2"),
            E.event(7, "system.note", ["text": "Background command stopped"], turn: "t2"),
            Self.summary(8, "e2.summary", "- Nothing changed.", turn: "t2"),
            E.done(9, turn: "t2"),
        ]
        let rows = TranscriptModel(events: events).rows.map(\.id)
        XCTAssertTrue(rows.contains("a:e1.summary"), "\(rows)")
        XCTAssertTrue(rows.contains("a:e2.summary"), "\(rows)")
    }

    /// Each event as it comes: the first turn shows as it did when it
    /// finished until the runner's turn is over, then the two become one.
    func testLiveTheStretchJoinsUpOnceTheRunnersTurnEnds() {
        let events = Self.restartCheck
        var model = TranscriptModel(events: Array(events.prefix(6)))
        var table = model.rows.map(\.id)
        for event in events.dropFirst(6) {
            WorkGroupTests.replay(model.apply([event]), onto: &table, model: model)
            XCTAssertEqual(model.rows.map(\.id), TranscriptModel(events: Array(model.events)).rows.map(\.id), "after seq \(event.seq)")
            if event.seq == 12 {
                XCTAssertEqual(model.rows.map(\.id), ["u:1", "g:n:2", "a:e1.summary", "f:t1", "u:10", "t:c3"],
                               "while the runner's turn runs, the first turn shows as it did once it finished")
            }
        }
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "g:n:2", "a:e2.summary", "f:t2"])
    }

    func testMikesNextMessageOrAScheduleStartsAStretchOfItsOwn() {
        for origin in [nil, "phone", "schedule"] as [String?] {
            let model = TranscriptModel(events: [
                Self.mike(1, "Go", turn: "t1"), E.call(2, "c1"), E.result(3, "c1"), Self.summary(4, "e1.summary", "- One.", turn: "t1"), E.done(5),
                Self.mike(6, "And again", turn: "t2", origin: origin),
                E.call(7, "c2").withTurn("t2"), E.result(8, "c2").withTurn("t2"), Self.summary(9, "e2.summary", "- Two.", turn: "t2"), E.done(10, turn: "t2"),
            ])
            XCTAssertEqual(model.rows.map(\.id), ["u:1", "g:t:c1", "a:e1.summary", "f:t1", "u:6", "g:t:c2", "a:e2.summary", "f:t2"], "origin \(origin ?? "nil")")
        }
    }

    /// One Mike sent into the running turn went into that turn: it isn't
    /// the start of a new stretch.
    func testAMessageSentIntoARunningTurnStaysInIt() {
        let model = TranscriptModel(events: [
            Self.mike(1, "Go", turn: "t1"), E.call(2, "c1"), E.result(3, "c1"),
            Self.mike(4, "Also this", turn: "t1"), E.call(5, "c2"), E.result(6, "c2"),
            Self.summary(7, "e1.summary", "- Both.", turn: "t1"), E.done(8),
        ])
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "g:t:c1", "u:4", "a:e1.summary", "f:t1"])
    }

    /// A runner's turn that ended on a line, not a summary, keeps that line
    /// under the summary before it rather than folding it away.
    func testARunnersTurnThatEndsOnALineKeepsIt() {
        let model = TranscriptModel(events: [
            Self.mike(1, "Go", turn: "t1"), E.call(2, "c1"), E.result(3, "c1"), Self.summary(4, "e1.summary", "- Done.", turn: "t1"), E.done(5),
            Self.runner(6, "[Threadbear hook] Typecheck passed", turn: "t2"),
            E.event(7, "assistant.text", ["itemId": "m2", "text": "Hook passed."], turn: "t2"), E.done(8, turn: "t2"),
        ])
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "g:t:c1", "a:e1.summary", "a:m2", "f:t2"])
    }

    /// The runner's turn's summary covers the stretch, so its work links
    /// can quote a step from the turn before.
    func testAWorkLinkCanPointIntoTheTurnBefore() {
        let model = TranscriptModel(events: Self.restartCheck)
        XCTAssertEqual(model.workStep("./check.sh --app", turn: "t2")?.rowId, "t:c1")
        XCTAssertEqual(model.workStep("./check.sh --app", turn: "t2")?.groupId, "g:n:2")
        XCTAssertEqual(model.workStep("cat build.json", turn: "t2")?.rowId, "t:c3", "its own steps first")
    }
}
