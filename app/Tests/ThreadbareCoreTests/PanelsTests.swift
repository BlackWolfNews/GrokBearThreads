import XCTest
@testable import ThreadbareCore

final class PanelsTests: XCTestCase {
    func testSummaryDecodesPanelsAndSkipsBrokenOnes() throws {
        let json = """
        {"id":"th1","panels":[
          {"id":"convex.dashboard","title":"Convex","kind":"url","url":"https://dashboard.convex.dev/d/quick-fox-77","patch":"convex","note":"quick-fox-77 (dev)"},
          {"id":"xcode.simulator","title":"Simulator","kind":"image","patch":"xcode"},
          {"id":"future.thing","title":"Later","kind":"hologram","patch":"future","extra":1},
          {"title":"no id"}
        ]}
        """
        let thread = try JSONDecoder().decode(ThreadSummary.self, from: Data(json.utf8))
        XCTAssertEqual(thread.panels.map(\.id), ["convex.dashboard", "xcode.simulator", "future.thing"])
        XCTAssertEqual(thread.panels[0].kind, .url)
        XCTAssertEqual(thread.panels[0].pageURL?.host, "dashboard.convex.dev")
        XCTAssertEqual(thread.panels[1].kind, .image)
        XCTAssertNil(thread.panels[1].url)
        // An unknown kind is shown as a page, the one thing every panel can be.
        XCTAssertEqual(thread.panels[2].kind, .url)
        let again = try JSONDecoder().decode(ThreadSummary.self, from: JSONEncoder().encode(thread))
        XCTAssertEqual(again.panels, thread.panels)
        let none = try JSONDecoder().decode(ThreadSummary.self, from: Data(#"{"id":"x"}"#.utf8))
        XCTAssertEqual(none.panels, [])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(none), as: UTF8.self).contains("panels"))
    }

    func testActivePanelIsTheRememberedOneIfStillThereElseTheFirst() {
        let convex = Panel(id: "convex.dashboard", title: "Convex", url: "https://dashboard.convex.dev", patch: "convex")
        let sim = Panel(id: "xcode.simulator", title: "Simulator", kind: .image, patch: "xcode")
        XCTAssertEqual(PanelChoice.active(in: [convex, sim], remembered: nil), convex)
        XCTAssertEqual(PanelChoice.active(in: [convex, sim], remembered: "xcode.simulator"), sim)
        XCTAssertEqual(PanelChoice.active(in: [convex], remembered: "xcode.simulator"), convex)
        XCTAssertNil(PanelChoice.active(in: [], remembered: "xcode.simulator"))
    }

    func testPaneWidthStaysInsideTheColumn() {
        XCTAssertEqual(PanelChoice.clampedWidth(420, paneColumnWidth: 1000), 420)
        XCTAssertEqual(PanelChoice.clampedWidth(100, paneColumnWidth: 1000), PanelChoice.minWidth)
        XCTAssertEqual(PanelChoice.clampedWidth(900, paneColumnWidth: 1000), 640)
        // A tiny column: the pane keeps its minimum rather than vanishing.
        XCTAssertEqual(PanelChoice.clampedWidth(420, paneColumnWidth: 500), PanelChoice.minWidth)
    }
}

final class ActionsTests: XCTestCase {
    func testSummaryDecodesActionsAndPatches() throws {
        let json = """
        {"id":"th1","actions":[
          {"id":"reseed.reseed-dev-db","title":"Reseed dev DB","kind":"command","command":"npx convex run seed:reset","patch":"reseed","note":"Dev only"},
          {"id":"reseed.explain","title":"Explain","kind":"prompt","prompt":"Explain it","patch":"reseed"},
          {"title":"no id"}
        ],"patches":[{"id":"convex","source":"builtin"},{"id":"reseed","source":"project","file":"/p/.threadbear/patches/reseed.ts"},{"id":"bad","source":"project","file":"/p/x.ts","error":"nope"}]}
        """
        let thread = try JSONDecoder().decode(ThreadSummary.self, from: Data(json.utf8))
        XCTAssertEqual(thread.actions.map(\.id), ["reseed.reseed-dev-db", "reseed.explain"])
        XCTAssertEqual(thread.actions[0].kind, .command)
        XCTAssertEqual(thread.actions[0].command, "npx convex run seed:reset")
        XCTAssertEqual(thread.actions[1].kind, .prompt)
        XCTAssertEqual(thread.patches.map(\.source), ["builtin", "project", "project"])
        XCTAssertEqual(thread.patches[2].error, "nope")
        let hooked = try JSONDecoder().decode(ThreadSummary.self, from: Data(#"{"id":"h","hooks":[{"id":"c.typecheck","title":"Typecheck","on":"turn.end","command":"npx tsc","edited":"**/*.ts","tell":"failures","patch":"c"}]}"#.utf8))
        XCTAssertEqual(hooked.hooks.map(\.id), ["c.typecheck"])
        XCTAssertEqual(hooked.hooks[0].edited, "**/*.ts")
        let hookRun = ActionRun(actionId: "c.typecheck", title: "Typecheck", ok: true, trigger: "turn.end")
        XCTAssertEqual(hookRun.asToolCall.0.title, "Typecheck · after the turn")
        let again = try JSONDecoder().decode(ThreadSummary.self, from: JSONEncoder().encode(thread))
        XCTAssertEqual(again.actions, thread.actions)
        XCTAssertEqual(again.patches, thread.patches)
    }

    func testActionRunEventBecomesAToolRow() throws {
        let json = """
        {"seq":7,"ts":"2026-10-27T02:00:00Z","threadId":"th1","type":"action.run","actionId":"tools.typecheck","patch":"tools",
         "title":"Typecheck","command":"npx tsc --noEmit","ok":false,"exitCode":2,"text":"src/a.ts(1,1): error TS1\\n","truncated":false,"durationMs":1234}
        """
        let event = try JSONDecoder().decode(Event.self, from: Data(json.utf8))
        guard case .actionRun(let run) = event.payload else { return XCTFail("not an action run: \(event.payload)") }
        XCTAssertEqual(run.exitCode, 2)
        XCTAssertFalse(event.isTransient)
        var (call, result) = run.asToolCall
        call.itemId = run.itemId(seq: event.seq)
        result.itemId = call.itemId
        XCTAssertEqual(call.itemId, "action:7")
        XCTAssertEqual(call.title, "Typecheck failed (exit 2)")
        XCTAssertEqual(call.kind, .command)
        XCTAssertEqual(call.input["command"]?.stringValue, "npx tsc --noEmit")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(ToolPresentation.symbol(for: .command, name: "action"), "square.dashed")
        XCTAssertEqual(ToolPresentation.symbol(for: .command, name: "Bash"), "terminal")
        let model = TranscriptModel(events: [event])
        XCTAssertEqual(model.rows.map { $0.id }, ["t:action:7"])
        guard case .tool(let tool) = model.rows[0].content else { return XCTFail("not a tool row") }
        XCTAssertTrue(tool.failed)
        XCTAssertEqual(tool.title, "Typecheck failed (exit 2)")
    }
}
