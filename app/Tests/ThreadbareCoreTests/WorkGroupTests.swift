import XCTest
@testable import ThreadbareCore

/// Folding runs of work into group rows, the working line and the changed
/// files card.
final class WorkGroupTests: XCTestCase {
    // MARK: Helpers

    static func started(_ seq: Int, turn: String = "t1", ts: String = "2026-10-26T10:00:00.250Z") -> Event {
        E.event(seq, "turn.started", ["ts": ts], turn: turn)
    }

    static func reasoning(_ seq: Int, _ item: String, _ text: String = "Looking at it", turn: String = "t1") -> Event {
        E.event(seq, "reasoning", ["itemId": item, "text": text], turn: turn)
    }

    static func edit(_ seq: Int, _ item: String, path: String, old: String = "a", new: String = "b", name: String = "Edit") -> Event {
        E.call(seq, item, name: name, kind: name == "Write" ? "write" : "edit", title: "\(name) \(path)",
               input: name == "Write" ? ["file_path": path, "content": new] : ["file_path": path, "old_string": old, "new_string": new])
    }

    /// Plays a change onto a list of ids the way a table does (removals at
    /// old indices, then inserts at new ones) and checks it ends up as the
    /// model's rows, and that updates point at real rows.
    static func replay(_ change: TranscriptChange, onto table: inout [String], model: TranscriptModel, file: StaticString = #filePath, line: UInt = #line) {
        for index in change.removed.reversed() { table.remove(at: index) }
        for index in change.inserted { table.insert(model.rows[index].id, at: index) }
        XCTAssertEqual(table, model.rows.map(\.id), "replayed change", file: file, line: line)
        XCTAssertTrue(change.updated.allSatisfy { $0 < model.rows.count }, file: file, line: line)
        XCTAssertTrue(change.updated.intersection(change.inserted).isEmpty, file: file, line: line)
    }

    // MARK: Grouping rules

    func testARunOfOneIsShownAsItself() {
        let model = TranscriptModel(events: [E.user(1, "Go"), E.call(2, "c1"), E.result(3, "c1"), E.text(4, "m1", "Done"), E.done(5)])
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "t:c1", "a:m1", "f:t1"])
    }

    func testMessagesCardsPlansImagesAndErrorsEndARun() {
        let model = TranscriptModel(events: [
            E.user(1, "Go"),
            Self.reasoning(2, "r1"), E.call(3, "c1"), E.result(4, "c1"),
            E.text(5, "m1", "First look done."),
            E.call(6, "c2"), E.event(7, "plan.updated", ["entries": [["text": "A", "status": "pending"]]]),
            E.call(8, "c3"), E.call(9, "c4"), E.result(10, "c4", images: [["path": "/tmp/a.png", "mediaType": "image/png"]]),
            E.call(11, "c5"), E.event(12, "error", ["message": "Oops"]),
            E.call(13, "c6"), E.event(14, "system.note", ["text": "Compacted the conversation"]),
            E.event(15, "approval.requested", ["approvalId": "ap1", "name": "Bash", "title": "rm x", "input": [:], "options": ["allow"]]),
        ])
        XCTAssertEqual(model.rows.map(\.id), [
            "u:1", "g:r:r1", "a:m1", "t:c2", "p:7", "g:t:c3", "i:c4", "t:c5", "e:12", "g:t:c6", "ap:ap1",
        ])
        guard case .group(let group)? = model.row(id: "g:t:c6")?.content else { return XCTFail() }
        XCTAssertEqual(group.memberIds, ["t:c6", "n:14"], "system notes fold in with the work")
    }

    func testRunsDoNotCrossTurns() {
        let model = TranscriptModel(events: [
            E.call(1, "c1"), E.result(2, "c1"),
            E.call(3, "c2", title: "pwd").withTurn("t2"), E.call(4, "c3").withTurn("t2"),
        ])
        XCTAssertEqual(model.rows.map(\.id), ["t:c1", "g:t:c2"])
    }

    // MARK: Summaries

    func testSummaryCountsWorkInTheOrderItHappened() {
        let model = TranscriptModel(events: [
            E.call(1, "c1", name: "Read", kind: "read", title: "Read a", input: ["file_path": "/a.swift"]),
            E.call(2, "c2", name: "Read", kind: "read", title: "Read b", input: ["file_path": "/b.swift"]),
            E.call(3, "c3", name: "Read", kind: "read", title: "Read a again", input: ["file_path": "/a.swift"]),
            E.call(4, "c4", name: "Grep", kind: "search", title: "Search"),
            E.call(5, "c5", name: "Glob", kind: "search", title: "Find"),
            Self.edit(6, "c6", path: "/a.swift"),
            Self.edit(7, "c7", path: "/b.swift", name: "Write"),
            Self.edit(8, "c8", path: "/a.swift"),
            E.call(9, "c9", title: "npm test"), E.call(10, "c10", title: "npm run lint"),
            E.result(11, "c10", ok: false, text: "lint failed"),
            Self.reasoning(12, "r1"),
        ])
        guard case .group(let group)? = model.rows.first?.content else { return XCTFail() }
        XCTAssertEqual(group.summary, "Read 2 files, searched twice, edited 2 files, ran 2 commands")
        XCTAssertEqual(group.failedCount, 1)
        XCTAssertEqual(group.memberIds.count, 11)
    }

    func testSummaryWordsForOtherWork() {
        func summary(_ events: [Event]) -> String {
            guard case .group(let group)? = TranscriptModel(events: events).rows.first?.content else { return "" }
            return group.summary
        }
        XCTAssertEqual(summary([Self.reasoning(1, "r1"), Self.reasoning(2, "r2")]), "Thought")
        XCTAssertEqual(summary([E.call(1, "c1", name: "Task", kind: "task", title: "Explore"), Self.reasoning(2, "r1")]), "Ran an agent")
        XCTAssertEqual(summary([
            E.call(1, "c1", name: "WebFetch", kind: "web", title: "Fetch a"), E.call(2, "c2", name: "WebFetch", kind: "web", title: "Fetch b"),
            E.call(3, "c3", name: "WebSearch", kind: "web", title: "Search the web"),
        ]), "Fetched 2 pages, searched once")
        XCTAssertEqual(summary([
            E.call(1, "c1", name: "mcp__notion__search", kind: "mcp", title: "Notion"), E.call(2, "c2", name: "Mystery", kind: "other", title: "?"),
            E.call(3, "c3", title: "ls"),
        ]), "Used 2 tools, ran a command")
        XCTAssertEqual(summary([
            E.event(1, "system.note", ["text": "Resumed session"]), E.event(2, "system.note", ["text": "Compacted"]),
        ]), "Resumed session")
    }

    // MARK: Live updates

    /// The group keeps its id (the first item's) as it grows, so its
    /// expansion and cached height survive streaming; each step is a small
    /// change, never a reload.
    func testAGroupKeepsItsIdAsItGrows() {
        var model = TranscriptModel(events: [E.user(1, "Go"), Self.started(2)])
        var table = model.rows.map(\.id)
        XCTAssertEqual(table, ["u:1", "w:t1"])

        var change = model.apply([Self.reasoning(3, "r1")])
        Self.replay(change, onto: &table, model: model)
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "r:r1", "w:t1"])
        XCTAssertEqual(change.inserted, [1])

        // A second item turns the lone row into a group in its place.
        change = model.apply([E.call(4, "c1", title: "npm test", input: ["command": "npm test"])])
        Self.replay(change, onto: &table, model: model)
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "g:r:r1", "w:t1"])
        XCTAssertEqual(change.removed, [1])
        XCTAssertEqual(change.inserted, [1])
        XCTAssertEqual(change.updated, [], "the working line is left as it is")

        let version = model.rows[1].version
        change = model.apply([E.result(5, "c1"), E.call(6, "c2", name: "Read", kind: "read", title: "Read a.swift")])
        Self.replay(change, onto: &table, model: model)
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "g:r:r1", "w:t1"])
        XCTAssertEqual(change, TranscriptChange(updated: [1]))
        XCTAssertGreaterThan(model.rows[1].version, version)
        guard case .group(let group) = model.rows[1].content else { return XCTFail() }
        XCTAssertEqual(group.summary, "Ran a command, read a file")
        XCTAssertTrue(group.isLive)
        XCTAssertEqual(group.currentAction, "Read a.swift")

        // Text after it ends the run: the group is no longer the live one.
        change = model.apply([E.result(7, "c2"), E.delta(7, "m1", "Found")])
        Self.replay(change, onto: &table, model: model)
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "g:r:r1", "a:m1", "w:t1"])
        XCTAssertEqual(change.inserted, [2])
        XCTAssertEqual(change.updated, [1], "only the group, no longer live")
        guard case .group(let finished) = model.rows[1].content else { return XCTFail() }
        XCTAssertFalse(finished.isLive)
        XCTAssertNil(finished.currentAction)

        // Streaming text only touches its own row.
        change = model.apply([E.delta(7, "m1", " it.")])
        XCTAssertEqual(change, TranscriptChange(updated: [2]))
    }

    func testAClosedGroupIgnoresOutputFromItsTools() {
        var model = TranscriptModel(events: [Self.started(1), E.call(2, "c1"), E.result(3, "c1"), E.call(4, "c2", title: "npm test")])
        XCTAssertEqual(model.rows.map(\.id), ["g:t:c1", "w:t1"])
        let change = model.apply([E.event(4, "tool.output.delta", ["itemId": "c2", "text": "PASS a.test.ts\n"])])
        XCTAssertTrue(change.isEmpty, "nothing on screen changed")
        guard case .tool(let tool)? = model.item(id: "t:c2")?.content else { return XCTFail() }
        XCTAssertEqual(tool.liveOutput, "PASS a.test.ts\n")
    }

    func testOpeningAGroupInsertsItsItemsUnderIt() {
        var model = TranscriptModel(events: [
            E.user(1, "Go"), Self.reasoning(2, "r1"), E.call(3, "c1"), E.result(4, "c1"), E.text(5, "m1", "Done"),
        ])
        var table = model.rows.map(\.id)
        let version = model.rows[1].version
        var change = model.setExpanded("g:r:r1", true)
        Self.replay(change, onto: &table, model: model)
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "g:r:r1", "r:r1", "t:c1", "a:m1"])
        XCTAssertEqual(change.inserted, [2, 3])
        XCTAssertEqual(change.updated, [1], "the chevron turns")
        XCTAssertEqual(model.rows.filter(\.inGroup).map(\.id), ["r:r1", "t:c1"])
        XCTAssertNotEqual(model.rows[1].version, version)
        guard case .group(let group) = model.rows[1].content else { return XCTFail() }
        XCTAssertTrue(group.isExpanded)

        // A tool that finishes inside an open group updates its own row.
        change = model.apply([E.result(6, "c1", text: "changed")])
        XCTAssertTrue(change.updated.contains(3))
        XCTAssertTrue(change.inserted.isEmpty && change.removed.isEmpty)

        // Opening it again is nothing; closing takes its items out.
        XCTAssertTrue(model.setExpanded("g:r:r1", true).isEmpty)
        change = model.setExpanded("g:r:r1", false)
        Self.replay(change, onto: &table, model: model)
        XCTAssertEqual(change.removed, [2, 3])
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "g:r:r1", "a:m1"])
    }

    func testAnOpenGroupGainsNewItemsInPlace() {
        var model = TranscriptModel(events: [Self.started(1), E.call(2, "c1"), E.call(3, "c2")])
        _ = model.setExpanded("g:t:c1", true)
        var table = model.rows.map(\.id)
        let change = model.apply([E.call(4, "c3")])
        Self.replay(change, onto: &table, model: model)
        XCTAssertEqual(model.rows.map(\.id), ["g:t:c1", "t:c1", "t:c2", "t:c3", "w:t1"])
        XCTAssertEqual(change.inserted, [3])
        XCTAssertEqual(change.updated, [0])
    }

    func testOpenGroupsStayOpenWhenOlderEventsArePrepended() {
        var model = TranscriptModel(events: [E.user(5, "Go"), E.call(6, "c1"), E.call(7, "c2"), E.text(8, "m1", "Done")])
        _ = model.setExpanded("g:t:c1", true)
        let result = model.prepend(olderEvents: [E.user(3, "Earlier"), E.text(4, "m0", "Hi")])
        XCTAssertTrue(result.keepsOrder)
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(model.rows.map(\.id), ["u:3", "a:m0", "u:5", "g:t:c1", "t:c1", "t:c2", "a:m1"])
        XCTAssertEqual(result.changedIds, [], "the group's content and version are unchanged")
    }

    /// Whatever order events arrive in, applying them one at a time ends
    /// with the rows a fresh load makes, and every change replays exactly.
    func testIncrementalRowsMatchAFreshLoad() {
        let events: [Event] = [
            E.user(1, "Fix it"), Self.started(2), Self.reasoning(3, "r1"),
            E.call(4, "c1", name: "Grep", kind: "search", title: "Search"), E.result(5, "c1"),
            E.call(6, "c2", name: "Read", kind: "read", title: "Read a", input: ["file_path": "/a"]), E.result(7, "c2"),
            E.text(8, "m1", "Found it."),
            Self.edit(9, "c3", path: "/a"), E.result(10, "c3"),
            E.call(11, "c4", title: "Screenshot"), E.result(12, "c4", images: [["path": "/tmp/s.png", "mediaType": "image/png"]]),
            E.call(13, "c5", title: "npm test"), E.result(14, "c5"),
            E.event(15, "approval.requested", ["approvalId": "ap1", "name": "Bash", "title": "rm x", "input": [:], "options": ["allow"]]),
            E.event(16, "approval.resolved", ["approvalId": "ap1", "decision": "allow"]),
            E.call(17, "c6", title: "rm x"), E.result(18, "c6"),
            E.text(19, "m2", "All done."),
            E.done(20),
        ]
        for open in [false, true] {
            var model = TranscriptModel()
            var table: [String] = []
            for (step, event) in events.enumerated() {
                let change = model.apply([event])
                Self.replay(change, onto: &table, model: model)
                if open {
                    for row in model.rows where row.kind == .group && !model.isExpanded(row.id) {
                        Self.replay(model.setExpanded(row.id, true), onto: &table, model: model)
                    }
                }
                var fresh = TranscriptModel()
                fresh.load(events: Array(events.prefix(step + 1)))
                for key in model.expanded { _ = fresh.setExpanded(key, true) }
                XCTAssertEqual(model.rows.map(\.id), fresh.rows.map(\.id), "after event \(step + 1)")
                XCTAssertEqual(model.rows.map(\.content), fresh.rows.map(\.content), "after event \(step + 1)")
            }
        }
    }

    // MARK: Working line

    func testTheWorkingLineShowsWhileATurnRunsAndNotWhileItWaits() {
        var model = TranscriptModel(events: [E.user(1, "Go"), Self.started(2), E.call(3, "c1")])
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "t:c1", "w:t1"])
        guard case .working(let status)? = model.rows.last?.content else { return XCTFail() }
        XCTAssertEqual(status.turnId, "t1")
        XCTAssertEqual(status.startedAt, Date(timeIntervalSince1970: 1_793_008_800.25))
        var table = model.rows.map(\.id)

        var change = model.apply([E.event(4, "approval.requested", ["approvalId": "ap1", "name": "Bash", "title": "rm x", "input": [:], "options": ["allow"]])])
        Self.replay(change, onto: &table, model: model)
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "t:c1", "ap:ap1"], "waiting on Mike isn't working")

        change = model.apply([E.event(5, "approval.resolved", ["approvalId": "ap1", "decision": "allow"])])
        Self.replay(change, onto: &table, model: model)
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "t:c1", "ap:ap1", "w:t1"])

        change = model.apply([E.done(6)])
        Self.replay(change, onto: &table, model: model)
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "t:c1", "ap:ap1", "f:t1"])
        XCTAssertNil(model.openTurn)
    }

    /// The working line is the turn's one spinner wherever it sits, so it
    /// doesn't change (or re-render) as a live group above it comes, opens
    /// and finishes.
    func testTheWorkingLineKeepsItsVersionAsWorkComesAndGoes() {
        func working(_ model: TranscriptModel) -> TranscriptRow? { model.rows.last { $0.kind == .working } }
        var model = TranscriptModel(events: [E.user(1, "Go"), Self.started(2), E.call(3, "c1")])
        let version = working(model)?.version
        XCTAssertNotNil(version)
        _ = model.apply([E.call(4, "c2")])
        XCTAssertEqual(model.rows.map(\.id), ["u:1", "g:t:c1", "w:t1"])
        XCTAssertEqual(working(model)?.version, version, "under the live group")
        _ = model.setExpanded("g:t:c1", true)
        XCTAssertEqual(working(model)?.version, version, "under the open group")
        _ = model.apply([E.text(5, "m1", "Found it")])
        XCTAssertEqual(working(model)?.version, version, "under a reply")
    }

    func testATurnThatStartedOnAnOlderPageIsStillRunning() {
        let model = TranscriptModel(events: [E.call(600, "c1"), E.result(601, "c1")])
        XCTAssertEqual(model.openTurn, "t1")
        guard case .working(let status)? = model.rows.last?.content else { return XCTFail("no working line") }
        XCTAssertNil(status.startedAt, "the start is on a page we haven't loaded")

        // A page that starts with the turn's message would have had its start.
        let finished = TranscriptModel(events: [E.user(600, "Go"), E.call(601, "c1")])
        XCTAssertNil(finished.openTurn)
    }

    // MARK: Changed files card

    func testAChangedFilesCardComesBeforeTheFooter() {
        var model = TranscriptModel(events: [
            E.user(1, "Change things"), Self.started(2),
            Self.edit(3, "c1", path: "/repo/Sources/A.swift", old: "a\nb", new: "a\nc\nd"), E.result(4, "c1"),
            Self.edit(5, "c2", path: "/repo/README.md", new: "# Hi\n\nText\n", name: "Write"), E.result(6, "c2"),
            Self.edit(7, "c3", path: "/repo/Sources/A.swift", old: "d", new: "e"), E.result(8, "c3"),
            Self.edit(9, "c4", path: "/repo/Sources/B.swift"), E.result(10, "c4", ok: false, text: "old_string not found"),
            E.text(11, "m1", "Done."),
        ])
        XCTAssertNil(model.rows.first { $0.kind == .changes }, "no card until the turn ends")
        var table = model.rows.map(\.id)
        var change = model.apply([E.done(12)])
        Self.replay(change, onto: &table, model: model)
        XCTAssertEqual(Array(model.rows.map(\.id).suffix(3)), ["a:m1", "cf:t1", "f:t1"])
        guard case .changes(let card)? = model.row(id: "cf:t1")?.content else { return XCTFail() }
        XCTAssertEqual(card.title, "Edited 2 files")
        XCTAssertEqual(card.files.map(\.path), ["/repo/Sources/A.swift", "/repo/README.md"])
        XCTAssertEqual(card.files.map(\.added), [3, 3])
        XCTAssertEqual(card.files.map(\.removed), [2, 0])
        XCTAssertEqual(card.files[0].diffs.count, 2, "both edits to A.swift")
        XCTAssertEqual(card.files[0].name, "A.swift")
        XCTAssertEqual(card.files[0].folder, "repo/Sources")

        let version = model.row(id: "cf:t1")!.version
        change = model.setExpanded(ChangedFiles.expansionKey(turnId: "t1", path: "/repo/README.md"), true)
        XCTAssertEqual(change, TranscriptChange(updated: [model.indexOf(id: "cf:t1")!]))
        guard case .changes(let opened)? = model.row(id: "cf:t1")?.content else { return XCTFail() }
        XCTAssertEqual(opened.files.map(\.isExpanded), [false, true])
        XCTAssertNotEqual(model.row(id: "cf:t1")?.version, version)
    }

    /// A file opened in the card shows the first lines of its diff; "Show N
    /// more lines" opens the rest through its own key, and closing the file
    /// forgets that, so it opens short again.
    func testShowingAllOfAChangedFilesDiffRoundTrips() {
        var model = TranscriptModel(events: [
            E.user(1, "Write it"), Self.edit(2, "c1", path: "/repo/Long.swift", new: (1...40).map { "line \($0)" }.joined(separator: "\n"), name: "Write"),
            E.result(3, "c1"), E.done(4),
        ])
        func file() -> ChangedFile? {
            guard case .changes(let card)? = model.row(id: "cf:t1")?.content else { return nil }
            return card.files.first
        }
        let key = ChangedFiles.expansionKey(turnId: "t1", path: "/repo/Long.swift")
        let all = DiffPreview.allKey(key)
        XCTAssertEqual(all, "cf:t1|/repo/Long.swift|all")
        _ = model.setExpanded(key, true)
        XCTAssertEqual(file()?.isExpanded, true)
        XCTAssertEqual(file()?.showsAll, false)

        let version = model.row(id: "cf:t1")!.version
        let change = model.setExpanded(all, true)
        XCTAssertEqual(change, TranscriptChange(updated: [model.indexOf(id: "cf:t1")!]), "only the card changes")
        XCTAssertNotEqual(model.row(id: "cf:t1")?.version, version, "so its height is measured again")
        XCTAssertEqual(file()?.showsAll, true)
        XCTAssertTrue(model.isExpanded(all))

        _ = model.setExpanded(key, false)
        XCTAssertEqual(file()?.isExpanded, false)
        XCTAssertEqual(file()?.showsAll, false)
        XCTAssertFalse(model.isExpanded(all))
        _ = model.setExpanded(key, true)
        XCTAssertEqual(file()?.showsAll, false, "opens short again")
    }

    func testADiffIsOnlyShortenedWhenThatHidesEnough() {
        XCTAssertEqual(DiffPreview.shown(of: 5), 5)
        XCTAssertEqual(DiffPreview.shown(of: 15), 15, "not 12 and \"Show 3 more lines\"")
        XCTAssertEqual(DiffPreview.shown(of: 18), 18)
        XCTAssertEqual(DiffPreview.shown(of: 19), 12)
        XCTAssertEqual(DiffPreview.shown(of: 400), 12)
    }

    /// Tool rows keep their open state in the app's own set, by the same rule.
    func testDiffPreviewKeysInASet() {
        var open: Set<String> = []
        DiffPreview.set("t:c1", open: true, in: &open)
        DiffPreview.set(DiffPreview.allKey("t:c1"), open: true, in: &open)
        XCTAssertEqual(open, ["t:c1", "t:c1|all"])
        DiffPreview.set("t:c1", open: false, in: &open)
        XCTAssertEqual(open, [])
    }

    func testAThoughtIsSummedUpByItsFirstSentence() {
        XCTAssertEqual(WorkSummary.thought("Uploads are chunked already, so the missing piece is remembering which chunks the server confirmed. I should look at UploadTask first."),
                       "Uploads are chunked already, so the missing piece is remembering which chunks the server confirmed.")
        XCTAssertEqual(WorkSummary.thought("Hmm. Let me look at the logs first and then decide."), "Hmm. Let me look at the logs first and then decide.", "too short a sentence to stand alone")
        XCTAssertEqual(WorkSummary.thought("One long line with no full stop at all"), "One long line with no full stop at all")
        XCTAssertEqual(WorkSummary.thought("First line only.\nSecond line"), "First line only.")
        XCTAssertEqual(WorkSummary.thought(""), "")
    }

    /// A diff that lands after its turn finished updates the turn's card,
    /// and only the rows for that turn change.
    func testALateDiffUpdatesItsTurnsCard() {
        var model = TranscriptModel(events: [
            E.user(1, "Edit it"), Self.edit(2, "c1", path: "/a.swift"), E.result(3, "c1"), E.text(4, "m1", "Done"), E.done(5),
            E.user(6, "Thanks").withTurn("t2"), E.text(7, "m2", "Any time").withTurn("t2"), E.done(8, turn: "t2"),
        ])
        var table = model.rows.map(\.id)
        let after = model.rows.suffix(3).map(\.version)
        let change = model.apply([E.event(9, "edit.diff", ["itemId": "c1", "path": "/a.swift", "hunks": [
            ["oldStart": 40, "oldLines": 1, "newStart": 40, "newLines": 2, "lines": ["-a", "+b", "+c"]],
        ]])])
        Self.replay(change, onto: &table, model: model)
        XCTAssertEqual(change.updated, [1, 3], "the edit row and its turn's card")
        XCTAssertEqual(model.rows.suffix(3).map(\.version), after, "the next turn's rows are untouched")
        guard case .changes(let card)? = model.row(id: "cf:t1")?.content else { return XCTFail() }
        XCTAssertEqual(card.files.first?.added, 2)
    }

    /// Opening a group near the top of a long thread only touches that
    /// group's rows; everything after it keeps its version.
    func testOpeningAnEarlyGroupLeavesLaterRowsAlone() {
        var events: [Event] = []
        var seq = 0
        for turn in 0..<20 {
            let id = "t\(turn)"
            seq += 1; events.append(E.user(seq, "Go \(turn)").withTurn(id))
            seq += 1; events.append(E.call(seq, "a\(turn)").withTurn(id))
            seq += 1; events.append(E.call(seq, "b\(turn)").withTurn(id))
            seq += 1; events.append(E.text(seq, "m\(turn)", "Done").withTurn(id))
            seq += 1; events.append(E.done(seq, turn: id))
        }
        var model = TranscriptModel(events: events)
        var table = model.rows.map(\.id)
        let later = model.rows.dropFirst(4).map { "\($0.id)|\($0.version)" }
        let change = model.setExpanded("g:t:a0", true)
        Self.replay(change, onto: &table, model: model)
        XCTAssertEqual(change, TranscriptChange(inserted: [2, 3], updated: [1]))
        XCTAssertEqual(model.rows.dropFirst(6).map { "\($0.id)|\($0.version)" }, later)
        XCTAssertEqual(model.indexOf(id: "f:t19"), model.rows.count - 1, "rows after the group moved down in the index too")
    }

    func testATurnWithNoEditsHasNoCard() {
        let model = TranscriptModel(events: [E.user(1, "Hi"), E.call(2, "c1"), E.text(3, "m1", "Hello"), E.done(4)])
        XCTAssertNil(model.rows.first { $0.kind == .changes })
    }
}

extension Event {
    func withTurn(_ turn: String) -> Event {
        var copy = self
        copy.turnId = turn
        return copy
    }
}
