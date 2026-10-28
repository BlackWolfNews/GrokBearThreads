import XCTest
@testable import ThreadbearCore

final class SubagentTests: XCTestCase {
    private let base = ISO8601.parse("2026-10-27T10:00:00Z")!

    func testSubagentsDecodeToleratingUnknownStatusesAndFields() throws {
        let json = """
        {"id":"th1","title":"t","cwd":"/","accountId":"a","provider":"claude","permissionMode":"full","status":"running","live":true,"needsYou":false,
         "createdAt":"2026-10-26T10:00:00Z","updatedAt":"2026-10-26T10:00:00Z","lastActivityAt":"2026-10-26T10:00:00Z","preview":"","lastSeq":1,"lastSeenSeq":1,
         "subagents":[
          {"id":"a1","itemId":"toolu_1","description":"Review the runner","agentType":"general-purpose","status":"running","background":true,
           "activity":"Running npm test","toolUses":3,"startedAt":"2026-10-27T10:00:00Z","future":1},
          {"id":"a2","parentId":"a1","description":"Look around","status":"paused","background":false,"startedAt":"2026-10-27T10:01:00Z","endedAt":"2026-10-27T10:02:00Z"},
          {"description":"no id"},
          "junk"]}
        """
        let thread = try JSONDecoder().decode(ThreadSummary.self, from: Data(json.utf8))
        XCTAssertEqual(thread.subagents.map(\.id), ["a1", "a2"])
        XCTAssertEqual(thread.subagents[0].status, .running)
        XCTAssertEqual(thread.subagents[0].activity, "Running npm test")
        XCTAssertEqual(thread.subagents[0].toolUses, 3)
        XCTAssertTrue(thread.subagents[0].background)
        XCTAssertEqual(thread.subagents[1].status, .stopped, "a status the app doesn't know reads as stopped")
        XCTAssertEqual(thread.subagents[1].parentId, "a1")
        XCTAssertNotNil(thread.subagents[1].endedAt)
        let again = try JSONDecoder().decode(ThreadSummary.self, from: JSONEncoder().encode(thread))
        XCTAssertEqual(again.subagents, thread.subagents)
        // Absent means none.
        let none = try JSONDecoder().decode(ThreadSummary.self, from: Data(json.replacingOccurrences(of: "\"subagents\"", with: "\"other\"").utf8))
        XCTAssertEqual(none.subagents, [])
    }

    func testSubagentTranscriptDecodes() throws {
        let json = """
        {"subagent":{"id":"a1","description":"d","status":"completed","background":false,"startedAt":"2026-10-27T10:00:00Z"},
         "events":[{"seq":1,"ts":"","threadId":"th1","type":"user.message","text":"Brief","images":[]},
                   {"seq":2,"ts":"","threadId":"th1","type":"assistant.text","itemId":"m:0","text":"Done."}]}
        """
        let result = try JSONDecoder().decode(SubagentTranscript.self, from: Data(json.utf8))
        XCTAssertEqual(result.subagent?.status, .completed)
        XCTAssertEqual(result.events.map(\.seq), [1, 2])
        let bare = try JSONDecoder().decode(SubagentTranscript.self, from: Data(#"{"events":[]}"#.utf8))
        XCTAssertNil(bare.subagent)
    }

    private func agent(_ id: String, _ status: Subagent.Status = .running, parent: String? = nil, endedMinutesAgo: Double? = nil) -> Subagent {
        let now = base.addingTimeInterval(3600)
        return Subagent(id: id, parentId: parent, description: id, status: status, startedAt: base,
                        endedAt: endedMinutesAgo.map { now.addingTimeInterval(-$0 * 60) })
    }

    private var now: Date { base.addingTimeInterval(3600) }

    func testShowsRunningAndRecentlyFinishedOnly() {
        let thread = ThreadSummary(id: "t", title: "t", subagents: [
            agent("old", .completed, endedMinutesAgo: 30),
            agent("recent", .completed, endedMinutesAgo: 2),
            agent("live"),
            agent("failed", .failed, endedMinutesAgo: 9),
        ])
        let rows = SubagentRows.visible(thread, threadSelected: false, selectedSubagent: nil, now: now)
        XCTAssertEqual(rows.map(\.id), ["recent", "live", "failed"])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 0])
        // A selected one stays, however old.
        let selected = SubagentRows.visible(thread, threadSelected: false, selectedSubagent: "old", now: now)
        XCTAssertEqual(selected.map(\.id), ["old", "recent", "live", "failed"])
        // Under Inbox, finished ones go even when recent or the thread is selected.
        XCTAssertEqual(SubagentRows.visible(thread, threadSelected: true, selectedSubagent: nil, now: now, finishedShown: false).map(\.id), ["live"])
        XCTAssertEqual(SubagentRows.visible(thread, threadSelected: true, selectedSubagent: "old", now: now, finishedShown: false).map(\.id), ["old", "live"])
    }

    func testSelectedThreadShowsItsFinishedOnesUpToTheCap() {
        var list = (0..<15).map { agent("f\($0)", .completed, endedMinutesAgo: 60) }
        list.append(agent("live"))
        let thread = ThreadSummary(id: "t", title: "t", subagents: list)
        let rows = SubagentRows.visible(thread, threadSelected: true, selectedSubagent: nil, now: now)
        // The newest ten finished, plus the running one.
        XCTAssertEqual(rows.map(\.id), (5..<15).map { "f\($0)" } + ["live"])
        XCTAssertTrue(SubagentRows.visible(ThreadSummary(id: "x", title: "x"), threadSelected: true, selectedSubagent: nil, now: now).isEmpty)
    }

    func testNestedOnesSitUnderAShownParent() {
        let thread = ThreadSummary(id: "t", title: "t", subagents: [
            agent("p"),
            agent("other"),
            agent("child", parent: "p"),
            agent("grandchild", parent: "child"),
            agent("orphan", parent: "gone"),
            agent("underOld", parent: "old"),
            agent("old", .completed, endedMinutesAgo: 60),
        ])
        let rows = SubagentRows.visible(thread, threadSelected: false, selectedSubagent: nil, now: now)
        XCTAssertEqual(rows.map(\.id), ["p", "child", "grandchild", "other", "orphan", "underOld"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 0, 0, 0])
        // A parent loop still shows both, once each.
        let loop = ThreadSummary(id: "t", title: "t", subagents: [agent("a", parent: "b"), agent("b", parent: "a")])
        XCTAssertEqual(Set(SubagentRows.visible(loop, threadSelected: false, selectedSubagent: nil, now: now).map(\.id)), ["a", "b"])
    }

    func testALiveTurnWithNoTurnEventsMakesTheLastGroupLive() throws {
        let lines = [
            #"{"seq":1,"ts":"","threadId":"t","type":"user.message","text":"Brief","images":[]}"#,
            #"{"seq":2,"ts":"","threadId":"t","type":"tool.call","itemId":"a","name":"Bash","kind":"command","title":"ls","input":{}}"#,
            #"{"seq":3,"ts":"","threadId":"t","type":"tool.result","itemId":"a","ok":true,"text":"","truncated":false,"images":[]}"#,
            #"{"seq":4,"ts":"","threadId":"t","type":"tool.call","itemId":"b","name":"Bash","kind":"command","title":"npm test","input":{}}"#,
        ]
        let events = try lines.map { try JSONDecoder().decode(Event.self, from: Data($0.utf8)) }
        var model = TranscriptModel(events: events)
        func liveGroup() -> Bool? {
            for row in model.rows { if case .group(let group) = row.content { return group.isLive } }
            return nil
        }
        XCTAssertEqual(liveGroup(), false)
        XCTAssertFalse(model.rows.contains { $0.kind == .working })
        let change = model.setLiveTurn("", startedAt: base)
        XCTAssertFalse(change.isEmpty)
        XCTAssertEqual(liveGroup(), true)
        XCTAssertEqual(model.rows.last?.kind, .working)
        _ = model.setLiveTurn(nil)
        XCTAssertEqual(liveGroup(), false)
        XCTAssertFalse(model.rows.contains { $0.kind == .working })
    }

    func testRowWords() {
        var s = agent("a")
        XCTAssertEqual(SubagentRows.detail(s), "Starting")
        s.activity = "Running `npm test`"
        XCTAssertEqual(SubagentRows.detail(s), "Running npm test")
        s.status = .completed
        XCTAssertEqual(SubagentRows.detail(s), "Done")
        s.summary = "All **green**"
        XCTAssertEqual(SubagentRows.detail(s), "All green")
        s.status = .failed
        XCTAssertEqual(SubagentRows.detail(s), "Failed: All green")
        s.status = .stopped
        XCTAssertEqual(SubagentRows.detail(s), "Stopped")
        s.description = "  "
        s.agentType = "Explore"
        XCTAssertEqual(SubagentRows.title(s), "Explore sub-agent")
        s.endedAt = base.addingTimeInterval(125)
        XCTAssertEqual(SubagentRows.duration(s, now: now), "2m")
    }
}
