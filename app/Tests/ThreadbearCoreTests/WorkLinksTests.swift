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

    /// Mike asked what option A and B meant; the turn did no work, only
    /// answered, and its bullets said "Explained the choice above" over a
    /// folded explanation (29 Oct 2026). The answer is the reply.
    func testAnAnswerWithNoStepsIsTheReplyOverItsSummary() {
        let model = TranscriptModel(events: [
            E.user(1, "Can you explain this a bit more?"),
            E.text(2, "m1", "Sure. It comes down to timing against proof. **Option A:** wait and post it with a short video. **Option B:** post text only, now."),
            E.call(3, "e1", name: "mcp__threadbear__end_turn", kind: "mcp", title: "end_turn"), E.result(4, "e1", text: "Noted"),
            Self.summary(5, "e1.summary", "- Explained the choice above"), E.done(6),
        ])
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "g:a:e1.summary", "a:m1", "f:t1"])
    }

    /// A Sentry triage turn's report came after its last step (and a pin),
    /// and folded away under bullets that never said what was broken
    /// (29 Oct 2026). Everything before the last step is the work.
    func testTheReportAfterTheLastStepIsTheReplyOverAShorterSummary() {
        let model = TranscriptModel(events: [
            E.user(1, "Triage this"),
            E.text(2, "m1", "Committing and opening the PR."),
            E.call(3, "c1", input: ["command": "git commit -qm fix"]), E.result(4, "c1"),
            E.call(5, "c2", name: "ToolSearch", kind: "search", title: "Find tools"), E.result(6, "c2"),
            E.call(7, "p1", name: "mcp__threadbear__pin", kind: "mcp", title: "Pin PR #2"), E.result(8, "p1"),
            E.text(9, "m2", "**What's broken:** every sync since 22 Oct has failed. **My recommendation:** the planner is wrong and the guard is right."),
            E.call(10, "e1", name: "mcp__threadbear__end_turn", kind: "mcp", title: "end_turn"), E.result(11, "e1", text: "Noted"),
            Self.summary(12, "e1.summary", "- PR #2 opened"), E.done(13),
        ])
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "g:a:m1", "a:m2", "f:t1"])
        guard case .group(let group) = model.rows[1].content else { return XCTFail("a group") }
        XCTAssertEqual(group.memberIds, ["a:m1", "t:c1", "t:c2", "t:p1", "a:e1.summary"])
    }

    /// A narration block is only the API's paraphrase of what the agent
    /// wrote, so it never beats the bullets, however long it is: one about
    /// a list of names for Paws showed instead of them (30 Oct 2026).
    func testANarrationParaphraseNeverBeatsTheSummary() {
        let model = TranscriptModel(events: [
            E.user(1, "More names?"),
            E.call(2, "c1", input: ["command": "which browsy clicky"]), E.result(3, "c1"),
            E.event(4, "assistant.text", ["itemId": "m1", "text": "I've checked these whimsical name pairs for clashes and recommend Browsy McBrowseface as the clearest fit, noting the old name is still in review.", "narration": true]),
            E.call(5, "e1", name: "mcp__threadbear__end_turn", kind: "mcp", title: "end_turn"), E.result(6, "e1", text: "Noted"),
            Self.summary(7, "e1.summary", "- Five name pairs\n- My pick: Browsy"), E.done(8),
        ])
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "g:t:c1", "a:e1.summary", "f:t1"])
    }

    /// Text after end_turn never takes the answer's place: an agent wrote
    /// its "What I need from you" there, and it showed instead of the
    /// explanation before it (29 Oct 2026).
    func testTextAfterEndTurnFoldsAndTheAnswerBeforeItStays() {
        let model = TranscriptModel(events: [
            E.user(1, "What can we do?"),
            E.call(2, "c1", input: ["command": "sed -n 1,80p needs.ts"]), E.result(3, "c1"),
            E.text(4, "m1", "Two fixes."),
            E.call(5, "e1", name: "mcp__threadbear__end_turn", kind: "mcp", title: "end_turn"), E.result(6, "e1", text: "Noted"),
            E.text(7, "m2", "**What I need from you**\n1. Pick one."), E.done(8),
        ])
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "g:t:c1", "a:m1", "f:t1"])
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

    func testAWorkLinkFindsACodexComputerUseStepByItsTitle() {
        // Codex names each computer-use step in the call's input; the row's
        // own title is just "cua_repl: js". A Paws thread's summary quoted
        // these two names and both links beeped (29 Oct 2026).
        let model = TranscriptModel(events: [
            E.user(1, "ready"),
            E.call(2, "c1", name: "mcp__cua_repl__js", kind: "mcp", title: "cua_repl: js",
                   input: ["code": "let app = await cua.getApp(\"com.google.Chrome\");", "timeout_ms": 60000, "title": "Reconnect to Chrome desktop"]),
            E.result(3, "c1"),
            E.call(4, "c2", name: "mcp__cua_repl__js", kind: "mcp", title: "cua_repl: js",
                   input: ["code": "await app.click(699); await app.getAXState();", "title": "Check Google verification request"]),
            E.result(5, "c2"),
            Self.summary(6, "e1.summary", "- [Chrome desktop control now works](work:Reconnect to Chrome desktop)."), E.done(7),
        ])
        XCTAssertEqual(model.workStep("Reconnect to Chrome desktop", turn: "t1")?.rowId, "t:c1")
        XCTAssertEqual(model.workStep("Check Google verification request", turn: "t1")?.rowId, "t:c2")
    }

    func testTheAgentDraftingItsLinksDoesNotTakeThemFromTheStep() {
        // Opus drafts its summary, links and all, in its thinking just before
        // end_turn, and at times in a message too, so they're the latest
        // mentions of the words. The link still means the step (29 Oct 2026).
        let link = "[The beep means no matching step](work:Read recent work-link clicks from the app's unified log)"
        let model = TranscriptModel(events: [
            E.user(1, "Why the beep?"),
            E.call(2, "c1", input: ["command": "/usr/bin/log show --last 2h", "description": "Read recent work-link clicks from the app's unified log"]),
            E.result(3, "c1", text: "work link: no step"),
            E.call(4, "c2", input: ["command": "tb events d8c829e8"]), E.result(5, "c2", text: "the slug regex drops accents"),
            E.event(6, "reasoning", ["itemId": "r1", "text": "First bullet: \(link). The slug regex drops accents."]),
            E.text(7, "m1", "- \(link)."),
            Self.summary(8, "e1.summary", "- \(link)."), E.done(9),
        ])
        XCTAssertEqual(model.workStep("Read recent work-link clicks from the app's unified log", turn: "t1")?.rowId, "t:c1")
        // A thought loses to a step's output as well...
        XCTAssertEqual(model.workStep("the slug regex drops accents", turn: "t1")?.rowId, "t:c2")
        // ...but still answers when nothing else mentions the words.
        XCTAssertEqual(model.workStep("First bullet", turn: "t1")?.rowId, "r:r1")
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
