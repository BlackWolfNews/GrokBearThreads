import XCTest
@testable import ThreadbareCore

final class TranscriptModelTests: XCTestCase {
    func testBasicTurnBecomesRows() {
        let model = TranscriptModel(events: [
            E.event(1, "turn.started", ["turnId": "t1"]),
            E.user(2, "Fix the test"),
            E.event(3, "reasoning", ["itemId": "r1", "text": "Looking at it"]),
            E.call(4, "c1", title: "npm test"),
            E.result(5, "c1", text: "1 failing"),
            E.text(6, "m1", "Fixed it."),
            E.done(7),
        ])
        XCTAssertEqual(model.rows.map(\.kind), [.user, .reasoning, .tool, .assistant, .footer])
        XCTAssertEqual(model.rows.map(\.id), ["u:2", "r:r1", "t:c1", "a:m1", "f:t1"])
        guard case .tool(let tool) = model.rows[2].content else { return XCTFail() }
        XCTAssertEqual(tool.result?.text, "1 failing")
        XCTAssertEqual(model.firstSeq, 1)
        XCTAssertEqual(model.lastSeq, 7)
    }

    func testEmptyReasoningAndEmptyTextMakeNoRows() {
        let model = TranscriptModel(events: [
            E.event(1, "reasoning", ["itemId": "r1", "text": "  "]),
            E.text(2, "m1", ""),
        ])
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testDeltasStreamThenPersistedTextReplaces() {
        var model = TranscriptModel(events: [E.user(1, "Hi")])
        var change = model.apply([E.delta(1, "m1", "Hel")])
        XCTAssertEqual(change.inserted, [1])
        change = model.apply([E.delta(1, "m1", "lo")])
        XCTAssertEqual(change.updated, [1])
        XCTAssertEqual(model.rows[1].content, .assistant(TextItem(itemId: "m1", text: "Hello", isStreaming: true)))
        let version = model.rows[1].version
        change = model.apply([E.text(2, "m1", "Hello!")])
        XCTAssertEqual(change.updated, [1])
        XCTAssertEqual(model.rows[1].content, .assistant(TextItem(itemId: "m1", text: "Hello!", isStreaming: false)))
        XCTAssertGreaterThan(model.rows[1].version, version)
    }

    func testDuplicateAndOldEventsAreIgnoredAndGapsFlagged() {
        var model = TranscriptModel(events: [E.user(1, "a"), E.text(2, "m1", "b")])
        XCTAssertTrue(model.apply([E.text(2, "m1", "b")]).isEmpty)
        let change = model.apply([E.text(5, "m2", "later")])
        XCTAssertTrue(change.gapDetected)
    }

    func testToolResultImagesGetARowAfterTheirTool() {
        var model = TranscriptModel(events: [E.call(1, "c1", name: "Read", kind: "read", title: "Read a.png"), E.call(2, "c2")])
        let change = model.apply([E.result(3, "c1", images: [["path": "/tmp/a.png", "mediaType": "image/png"]])])
        XCTAssertEqual(model.rows.map(\.id), ["t:c1", "i:c1", "t:c2"])
        XCTAssertEqual(change.inserted, [1])
        XCTAssertEqual(change.updated, [0])
        XCTAssertEqual(model.indexOf(id: "t:c2"), 2)
    }

    func testEditCallsBecomeDiffRows() {
        var model = TranscriptModel(events: [
            E.call(1, "c1", name: "Edit", kind: "edit", title: "Edit a.swift", input: ["file_path": "/a.swift", "old_string": "let a = 1", "new_string": "let a = 2"]),
        ])
        XCTAssertEqual(model.rows.first?.kind, .diff)
        guard case .tool(let tool) = model.rows[0].content else { return XCTFail() }
        XCTAssertEqual(tool.effectiveDiff?.hunks.first?.lines, ["-let a = 1", "+let a = 2"])
        _ = model.apply([E.event(2, "edit.diff", ["itemId": "c1", "path": "/a.swift", "hunks": [
            ["oldStart": 10, "oldLines": 1, "newStart": 10, "newLines": 1, "lines": ["-let a = 1", "+let a = 3"]],
        ]])])
        guard case .tool(let updated) = model.rows[0].content else { return XCTFail() }
        XCTAssertEqual(updated.effectiveDiff?.hunks.first?.oldStart, 10)
    }

    func testApprovalAndQuestionResolution() {
        var model = TranscriptModel(events: [
            E.event(1, "approval.requested", ["approvalId": "ap1", "name": "Bash", "title": "rm -rf build", "input": [:], "options": ["allow", "deny"]]),
            E.event(2, "question.requested", ["approvalId": "q1", "questions": [["question": "Which?", "multiSelect": false, "options": [["label": "A"]]]]]),
        ])
        XCTAssertEqual(model.rows.map(\.kind), [.approval, .question])
        let change = model.apply([
            E.event(3, "approval.resolved", ["approvalId": "ap1", "decision": "deny"]),
            E.event(4, "approval.resolved", ["approvalId": "q1", "decision": "answered"]),
        ])
        XCTAssertEqual(change.updated, [0, 1])
        guard case .approval(let approval) = model.rows[0].content, case .question(let question) = model.rows[1].content else { return XCTFail() }
        XCTAssertEqual(approval.resolution?.decision, .deny)
        XCTAssertEqual(question.resolution?.decision, .answered)
    }

    func testPlanUpdatesOneRowPerTurn() {
        var model = TranscriptModel(events: [E.event(1, "plan.updated", ["entries": [["text": "A", "status": "pending"]]])])
        let change = model.apply([E.event(2, "plan.updated", ["entries": [["text": "A", "status": "completed"]]])])
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(change.updated, [0])
        XCTAssertEqual(model.rows[0].content, .plan([PlanEntry(text: "A", status: .completed)]))
    }

    func testTurnCompletedStopsStreaming() {
        var model = TranscriptModel(events: [E.user(1, "Hi")])
        _ = model.apply([E.delta(1, "m1", "Partial")])
        let change = model.apply([E.event(2, "turn.completed", ["turnId": "t1", "outcome": "interrupted", "durationMs": 100])])
        XCTAssertEqual(change.inserted, [2])
        XCTAssertEqual(change.updated, [1])
        XCTAssertEqual(model.rows[1].content, .assistant(TextItem(itemId: "m1", text: "Partial", isStreaming: false)))
    }

    func testToolOutputDeltaThenResult() {
        var model = TranscriptModel(events: [E.call(1, "c1")])
        _ = model.apply([E.event(1, "tool.output.delta", ["itemId": "c1", "text": "line 1\n"])])
        guard case .tool(let live) = model.rows[0].content else { return XCTFail() }
        XCTAssertEqual(live.liveOutput, "line 1\n")
        _ = model.apply([E.result(2, "c1", text: "all done")])
        guard case .tool(let finished) = model.rows[0].content else { return XCTFail() }
        XCTAssertEqual(finished.liveOutput, "")
        XCTAssertEqual(finished.result?.text, "all done")
    }

    func testPrependOlderPageKeepsIdsAndMergesSplitToolCalls() {
        // The newer page starts with a result whose call is on the older page.
        var model = TranscriptModel(events: [E.result(5, "c1", text: "ok"), E.text(6, "m1", "Done")])
        XCTAssertEqual(model.rows.map(\.id), ["t:c1", "a:m1"])
        let added = model.prepend(olderEvents: [E.user(3, "Run it"), E.call(4, "c1", title: "make")])
        XCTAssertEqual(model.rows.map(\.id), ["u:3", "t:c1", "a:m1"])
        XCTAssertEqual(added.added, 1)
        XCTAssertEqual(added.changedIds, ["t:c1"])
        guard case .tool(let tool) = model.rows[1].content else { return XCTFail() }
        XCTAssertEqual(tool.title, "make")
        XCTAssertEqual(tool.result?.text, "ok")
        XCTAssertEqual(model.firstSeq, 3)
        XCTAssertTrue(model.hasOlderEvents)
    }

    func testPrependKeepsVersionsOfUnchangedRows() {
        var model = TranscriptModel(events: [E.user(5, "b"), E.text(6, "m1", "reply")])
        let before = model.rows.map(\.version)
        let result = model.prepend(olderEvents: [E.user(4, "a")])
        XCTAssertEqual(result, PrependResult(added: 1, changedIds: []))
        XCTAssertEqual(Array(model.rows.dropFirst().map(\.version)), before)
    }

    func testTrimKeepsTheNewestEventsAndStreamingText() {
        var events: [Event] = []
        var seq = 0
        for turn in 0..<10 {
            seq += 1; events.append(E.user(seq, "question \(turn)"))
            seq += 1; events.append(E.call(seq, "c\(turn)"))
            seq += 1; events.append(E.result(seq, "c\(turn)"))
            seq += 1; events.append(E.text(seq, "m\(turn)", "answer \(turn)"))
        }
        var model = TranscriptModel(events: events)
        _ = model.apply([E.delta(seq, "live", "still typing")])
        let lastRowVersion = model.rows.first { $0.id == "a:m9" }!.version
        model.trim(keepingLast: 6)
        XCTAssertEqual(model.events.count, 6)
        XCTAssertEqual(model.firstSeq, seq - 5)
        XCTAssertEqual(model.lastSeq, seq)
        XCTAssertTrue(model.hasOlderEvents)
        XCTAssertNil(model.row(id: "u:1"))
        XCTAssertEqual(model.row(id: "a:m9")?.version, lastRowVersion, "unchanged rows keep their version")
        guard case .assistant(let live)? = model.rows.last?.content else { return XCTFail("streaming row lost") }
        XCTAssertEqual(live.text, "still typing")
        // Paging back in restores the rows.
        let added = model.prepend(olderEvents: Array(events.prefix(events.count - 6)))
        XCTAssertGreaterThan(added.added, 0)
        XCTAssertNotNil(model.row(id: "u:1"))
        XCTAssertEqual(model.events.count, events.count)
    }

    func testVersionsAreUniqueAcrossModels() {
        let a = TranscriptModel(events: [E.user(1, "x")])
        let b = TranscriptModel(events: [E.user(1, "x")])
        XCTAssertNotEqual(a.rows[0].version, b.rows[0].version)
    }

    func testPrependKeepsStreamingText() {
        var model = TranscriptModel(events: [E.user(5, "b")])
        _ = model.apply([E.delta(5, "m1", "streaming")])
        model.prepend(olderEvents: [E.user(4, "a")])
        XCTAssertEqual(model.rows.map(\.id), ["u:4", "u:5", "a:m1"])
        XCTAssertEqual(model.rows[2].content, .assistant(TextItem(itemId: "m1", text: "streaming", isStreaming: true)))
    }

    func testInProgressFromEventsPage() {
        var model = TranscriptModel()
        model.load(events: [E.user(1, "Hi")], inProgress: [EventsPage.InProgress(itemId: "m1", type: "assistant.text", text: "Half")])
        XCTAssertEqual(model.rows.last?.content, .assistant(TextItem(itemId: "m1", text: "Half", isStreaming: true)))
    }

    // Histories with an earlier turn.completed: replaying it used to end
    // whatever was streaming now, so the live row vanished.
    func testLoadMidTurnKeepsInProgressTextAfterEarlierTurns() {
        var model = TranscriptModel()
        model.load(events: [E.user(1, "Hi"), E.text(2, "m0", "Hello"), E.done(3), E.user(4, "More")],
                   inProgress: [EventsPage.InProgress(itemId: "live", type: "assistant.text", text: "Half way")])
        XCTAssertEqual(model.rows.last?.content, .assistant(TextItem(itemId: "live", text: "Half way", isStreaming: true)))
    }

    func testPrependDuringAReplyKeepsTheLiveText() {
        var model = TranscriptModel(events: [E.done(5, turn: "t0"), E.user(6, "Next")])
        _ = model.apply([E.delta(6, "live", "Streaming")])
        model.prepend(olderEvents: [E.user(3, "First"), E.done(4, turn: "tA")])
        XCTAssertEqual(model.row(id: "a:live")?.content, .assistant(TextItem(itemId: "live", text: "Streaming", isStreaming: true)))
        _ = model.apply([E.delta(6, "live", " more")])
        XCTAssertEqual(model.row(id: "a:live")?.content, .assistant(TextItem(itemId: "live", text: "Streaming more", isStreaming: true)))
    }

    func testTrimDuringAReplyKeepsTheLiveText() {
        var model = TranscriptModel(events: [E.user(1, "a"), E.done(2, turn: "t0"), E.user(3, "b"), E.done(4, turn: "t1"), E.user(5, "c")])
        _ = model.apply([E.delta(5, "live", "Still going")])
        model.trim(keepingLast: 2)
        XCTAssertEqual(model.row(id: "a:live")?.content, .assistant(TextItem(itemId: "live", text: "Still going", isStreaming: true)))
    }

    func testRebuildDropsStreamingTextOnceItsPersisted() {
        var model = TranscriptModel(events: [E.user(5, "b")])
        _ = model.apply([E.delta(5, "m1", "Hel")])
        _ = model.apply([E.text(6, "m1", "Hello"), E.done(7)])
        model.prepend(olderEvents: [E.user(4, "a")])
        XCTAssertEqual(model.rows.filter { $0.id == "a:m1" }.count, 1)
        XCTAssertEqual(model.row(id: "a:m1")?.content, .assistant(TextItem(itemId: "m1", text: "Hello", isStreaming: false)))
    }

    func testPrependWithAMovedRowSaysTheOrderChanged() {
        // Parallel tool calls: both calls on the older page, the second
        // result first on the newer page, then the first result. After the
        // merge t:c1 sits above t:c2, the old first row.
        var model = TranscriptModel(events: [E.result(5, "c2"), E.result(6, "c1"), E.text(7, "m1", "Done")])
        XCTAssertEqual(model.rows.map(\.id), ["t:c2", "t:c1", "a:m1"])
        let result = model.prepend(olderEvents: [E.user(2, "Go"), E.call(3, "c1"), E.call(4, "c2")])
        XCTAssertEqual(model.rows.map(\.id), ["u:2", "t:c1", "t:c2", "a:m1"])
        XCTAssertEqual(result.added, 2)
        XCTAssertFalse(result.keepsOrder, "t:c1 moved above the old first row")
    }

    func testPrependWithAnOlderRowBelowTheOldFirstRowSaysTheOrderChanged() {
        // The newer page starts with c1's result; between the call and the
        // result the older page has some text, which lands below t:c1.
        var model = TranscriptModel(events: [E.result(6, "c1"), E.text(7, "m1", "Done")])
        let result = model.prepend(olderEvents: [E.call(4, "c1"), E.text(5, "m0", "Running it")])
        XCTAssertEqual(model.rows.map(\.id), ["t:c1", "a:m0", "a:m1"])
        XCTAssertFalse(result.keepsOrder)
    }

    func testPrependWithTheCallLastOnTheOlderPageKeepsOrder() {
        var model = TranscriptModel(events: [E.result(5, "c1"), E.text(6, "m1", "Done")])
        let result = model.prepend(olderEvents: [E.user(3, "Run it"), E.call(4, "c1")])
        XCTAssertTrue(result.keepsOrder)
        XCTAssertEqual(result.added, 1)
    }

    func testUnknownEventsAreIgnored() {
        var model = TranscriptModel(events: [E.user(1, "a")])
        let change = model.apply([E.event(2, "brand.new", ["x": 1])])
        XCTAssertTrue(change.isEmpty)
        XCTAssertEqual(model.lastSeq, 2)
    }
}

final class ThreadFeedTests: XCTestCase {
    func testInOrderEventsFlush() {
        var feed = ThreadFeed(model: TranscriptModel(events: [E.user(1, "a")]))
        XCTAssertEqual(feed.receive(E.text(2, "m1", "b")), .scheduleFlush)
        XCTAssertEqual(feed.receive(E.delta(2, "m2", "c")), .scheduleFlush)
        let change = feed.flush()
        XCTAssertEqual(change.inserted, [1, 2])
        XCTAssertFalse(feed.hasPending)
    }

    func testGapAsksForCatchUpThenFills() {
        var feed = ThreadFeed(model: TranscriptModel(events: [E.user(1, "a")]))
        XCTAssertEqual(feed.receive(E.text(4, "m3", "d")), .needsCatchUp(afterSeq: 1))
        XCTAssertEqual(feed.receive(E.text(5, "m4", "e")), .none) // already catching up
        XCTAssertEqual(feed.catchUp([E.text(2, "m1", "b"), E.text(3, "m2", "c")]), .scheduleFlush)
        _ = feed.flush()
        XCTAssertEqual(feed.model.rows.map(\.id), ["u:1", "a:m1", "a:m2", "a:m3", "a:m4"])
        XCTAssertEqual(feed.acceptedSeq, 5)
    }

    func testSubscribeReplayRacingPushes() {
        var feed = ThreadFeed(model: TranscriptModel(events: [E.user(1, "a")]))
        feed.beginSubscribe()
        // A push for seq 3 lands before the subscribe reply with 2 and 3.
        XCTAssertEqual(feed.receive(E.text(3, "m2", "c")), .none)
        XCTAssertEqual(feed.catchUp([E.text(2, "m1", "b"), E.text(3, "m2", "c")]), .scheduleFlush)
        _ = feed.flush()
        XCTAssertEqual(feed.model.rows.map(\.id), ["u:1", "a:m1", "a:m2"])
    }

    func testStillGappedAfterCatchUpAsksAgain() {
        var feed = ThreadFeed(model: TranscriptModel(events: [E.user(1, "a")]))
        _ = feed.receive(E.text(10, "m9", "z"))
        XCTAssertEqual(feed.catchUp([E.text(2, "m1", "b")]), .needsCatchUp(afterSeq: 2))
    }

    /// The runner sent seq 2 in a shape this app can't read. It used to be
    /// dropped, so every catch-up came back without it and the thread froze
    /// (21,000 fetches in 4 s in the review). Now it decodes as .unknown and
    /// the feed moves on.
    func testAnUnreadableEventDoesNotStallTheFeed() {
        var feed = ThreadFeed(model: TranscriptModel(events: [E.user(1, "a")]))
        let broken = E.event(2, "edit.diff", ["itemId": "c1", "hunks": "not an array"])
        XCTAssertEqual(feed.receive(broken), .scheduleFlush)
        XCTAssertEqual(feed.receive(E.text(3, "m1", "after")), .scheduleFlush)
        _ = feed.flush()
        XCTAssertEqual(feed.acceptedSeq, 3)
        XCTAssertEqual(feed.model.rows.map(\.id), ["u:1", "a:m1"])
    }

    /// If the runner really doesn't have a seq, give up on it after a few
    /// fruitless catch-ups instead of fetching forever.
    func testAHoleTheRunnerCantFillIsSkippedAfterAFewTries() {
        var feed = ThreadFeed(model: TranscriptModel(events: [E.user(1, "a")]))
        XCTAssertEqual(feed.receive(E.text(3, "m1", "after the hole")), .needsCatchUp(afterSeq: 1))
        for _ in 1..<ThreadFeed.maxStalledCatchUps {
            XCTAssertEqual(feed.catchUp([E.text(3, "m1", "after the hole")]), .needsCatchUp(afterSeq: 1))
        }
        XCTAssertEqual(feed.catchUp([E.text(3, "m1", "after the hole")]), .scheduleFlush)
        _ = feed.flush()
        XCTAssertEqual(feed.acceptedSeq, 3)
        XCTAssertEqual(feed.model.rows.last?.id, "a:m1")
        XCTAssertFalse(feed.isCatchingUp)
    }

    /// Opening a thread mid-reply: `threads.events` gave "Hel", then the
    /// runner streamed "lo wor" before the subscription started (so those
    /// deltas never reached the app), then "ld" after. The subscribe reply's
    /// in-progress text fills the hole; before, the row read "Helld".
    func testSubscribeInProgressFillsDeltasMissedBeforeTheSubscription() {
        var model = TranscriptModel()
        model.load(events: [E.user(1, "Hi")], inProgress: [.init(itemId: "m1", type: "assistant.text", text: "Hel")])
        var feed = ThreadFeed(model: model)
        feed.beginSubscribe()
        // Pushed after the runner registered the subscription, but handled
        // before the subscribe reply.
        XCTAssertEqual(feed.receive(E.delta(1, "m1", "ld")), .none)
        let action = feed.finishSubscribe([], inProgress: [.init(itemId: "m1", type: "assistant.text", text: "Hello wor")])
        XCTAssertEqual(action, .scheduleFlush)
        _ = feed.flush()
        XCTAssertEqual(feed.model.rows.last?.content, .assistant(TextItem(itemId: "m1", text: "Hello world", isStreaming: true)))
        // Later deltas carry on from there, and the persisted text replaces it.
        _ = feed.receive(E.delta(1, "m1", "!"))
        _ = feed.flush()
        XCTAssertEqual(feed.model.rows.last?.content, .assistant(TextItem(itemId: "m1", text: "Hello world!", isStreaming: true)))
        _ = feed.receive(E.text(2, "m1", "Hello world!"))
        _ = feed.flush()
        XCTAssertEqual(feed.model.rows.map(\.id), ["u:1", "a:m1"])
        XCTAssertEqual(feed.model.rows.last?.content, .assistant(TextItem(itemId: "m1", text: "Hello world!")))
    }

    /// Reasoning streams the same way, and an item that started streaming
    /// only after `threads.events` gets its row from the subscribe reply.
    func testSubscribeInProgressAddsReasoningThatStartedSinceTheLoad() {
        var feed = ThreadFeed(model: TranscriptModel(events: [E.user(1, "Hi")]))
        feed.beginSubscribe()
        _ = feed.finishSubscribe([], inProgress: [.init(itemId: "r1", type: "reasoning", text: "Thinking it over")])
        _ = feed.flush()
        XCTAssertEqual(feed.model.rows.last?.content, .reasoning(TextItem(itemId: "r1", text: "Thinking it over", isStreaming: true)))
    }

    /// The replay already has the finished text: the in-progress list
    /// wouldn't name it, but if it did, the persisted text wins.
    func testInProgressNeverOverwritesPersistedText() {
        var feed = ThreadFeed(model: TranscriptModel(events: [E.user(1, "Hi")]))
        feed.beginSubscribe()
        _ = feed.finishSubscribe([E.text(2, "m1", "Done.")], inProgress: [.init(itemId: "m1", type: "assistant.text", text: "Do")])
        _ = feed.flush()
        XCTAssertEqual(feed.model.rows.last?.content, .assistant(TextItem(itemId: "m1", text: "Done.")))
    }

    func testAFailedCatchUpIsNotAStall() {
        var feed = ThreadFeed(model: TranscriptModel(events: [E.user(1, "a")]))
        _ = feed.receive(E.text(3, "m1", "x"))
        feed.catchUpFailed()
        XCTAssertEqual(feed.stalledCatchUps, 0)
        XCTAssertFalse(feed.isCatchingUp)
        // The reconnect's subscribe replay fills it.
        feed.beginSubscribe()
        XCTAssertEqual(feed.catchUp([E.text(2, "m0", "y"), E.text(3, "m1", "x")]), .scheduleFlush)
        XCTAssertEqual(feed.acceptedSeq, 3)
    }
}
