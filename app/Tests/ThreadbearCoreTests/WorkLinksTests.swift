import XCTest
@testable import ThreadbearCore

/// A turn's summary from end_turn, and its links back into the thread
/// (docs/protocol.md, "The summary", "Links into the thread").
final class WorkLinksTests: XCTestCase {
    static func summary(_ seq: Int, _ item: String, _ text: String, turn: String = "t1") -> Event {
        E.event(seq, "assistant.text", ["itemId": item, "text": text, "summary": true], turn: turn)
    }

    func testASummaryIsTheReplyAndTheTurnsOtherMessagesFoldIntoItsWork() {
        var model = TranscriptModel(events: [
            E.user(1, "Fix the slugs"),
            E.text(2, "m1", "Looking at the slug code."),
            E.call(3, "c1", input: ["command": "npm test", "description": "Run the tests"]), E.result(4, "c1"),
            E.text(5, "m2", "Fixed it; committing."),
        ])
        // Before the summary, the messages show as themselves.
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "a:m1", "t:c1", "a:m2"])
        _ = model.apply([Self.summary(6, "e1.summary", "- Fixed the slug bug.\n- [Tests pass](work:npm test)."), E.done(7)])
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "g:a:m1", "a:e1.summary", "f:t1"])
        guard case .group(let group) = model.rows[1].content else { return XCTFail("a group") }
        XCTAssertEqual(group.memberIds, ["a:m1", "t:c1", "a:m2"])
        // Loading the same events from scratch gives the same rows.
        XCTAssertEqual(TranscriptModel(events: model.events).rows.map(\.id), model.rows.map(\.id))
    }

    func testATurnWithoutASummaryKeepsItsMessages() {
        let model = TranscriptModel(events: [
            E.user(1, "Hi"), E.text(2, "m1", "Hello."), E.done(3),
            E.user(4, "Fix it"), E.event(5, "turn.started", [:], turn: "t2"), E.event(6, "assistant.text", ["itemId": "m2", "text": "On it."], turn: "t2"),
            Self.summary(7, "e2.summary", "- Fixed.", turn: "t2"),
        ])
        XCTAssertTrue(model.rows.contains { $0.id == "a:m1" }, "the first turn has no summary")
        XCTAssertFalse(model.rows.contains { $0.id == "a:m2" }, "the second does")
    }

    func testAWorkLinkFindsTheStepItQuotes() {
        let model = TranscriptModel(events: [
            E.user(1, "Fix the slugs"),
            E.call(2, "c1", input: ["command": "cat src/slug.js"]), E.result(3, "c1"),
            E.call(4, "c2", input: ["command": "sed -i '' 's/a/b/' package.json && npm test 2>&1 | tail -5", "description": "Fix import typo and rerun"]),
            E.result(5, "c2", text: "OpenAI error 401"),
            E.call(6, "c3", input: ["command": "git commit -qm 'Strip accents; npm test passes'"]), E.result(7, "c3"),
            E.text(8, "m1", "Found it: the car check restarts GPS every 5 s."),
            Self.summary(9, "e1.summary", "- Done."), E.done(10),
        ])
        // A command that starts with the words beats one that only mentions them.
        XCTAssertEqual(model.workStep("npm test", turn: "t1")?.rowId, "t:c2")
        XCTAssertEqual(model.workStep("Fix import typo and rerun", turn: "t1")?.rowId, "t:c2")
        XCTAssertEqual(model.workStep("OpenAI error 401", turn: "t1")?.rowId, "t:c2")
        XCTAssertEqual(model.workStep("restarts GPS every 5 s", turn: "t1")?.rowId, "a:m1")
        XCTAssertEqual(model.workStep("src/slug.js", turn: "t1")?.rowId, "t:c1")
        XCTAssertNil(model.workStep("nothing like it", turn: "t1"))
        XCTAssertNil(model.workStep("npm test", turn: "t9"))
        // The step is folded in the turn's group, which is what to open.
        XCTAssertEqual(model.workStep("npm test", turn: "t1")?.groupId, "g:t:c1")
    }

    func testLinksWithSpacesAreEscapedSoTheyParseAsLinks() {
        XCTAssertEqual(WorkLinks.escapeDestinations("[Tests pass](work:npm test) and [x](https://a.b/c d)"),
                       "[Tests pass](work:npm%20test) and [x](https://a.b/c d)")
        XCTAssertEqual(WorkLinks.escapeDestinations("[thread](thread:a1b2c3d4)"), "[thread](thread:a1b2c3d4)")
        XCTAssertEqual(WorkLinks.escapeDestinations("[done](work:npm%20test)"), "[done](work:npm%20test)")
        XCTAssertEqual(WorkLinks.quote(of: URL(string: "work:npm%20test")!), "npm test")
        XCTAssertEqual(WorkLinks.threadId(of: URL(string: "thread:a1b2c3d4")!), "a1b2c3d4")
        XCTAssertNil(WorkLinks.quote(of: URL(string: "https://example.com")!))
    }
}
