import XCTest
@testable import ThreadbearCore

/// docs/protocol.md, "Needs you": a finished turn's asks as a card, the
/// thread's summary fields, and how its sidebar row looks.
final class NeedsYouTests: XCTestCase {
    private func done(_ seq: Int, turn: String, needs: String? = nil, asks: [[String: Any]] = [], outcome: String = "completed") -> Event {
        var fields: [String: Any] = ["turnId": turn, "outcome": outcome, "durationMs": 1000]
        if let needs { fields["needs"] = needs }
        if !asks.isEmpty { fields["asks"] = asks }
        return E.event(seq, "turn.completed", fields, turn: turn)
    }

    private func card(_ model: TranscriptModel, _ id: String) -> AsksCard? {
        guard case .asks(let card)? = model.row(id: id)?.content else { return nil }
        return card
    }

    /// The open card is answered in the composer's place (DecisionPager),
    /// so the transcript keeps only the footer's needs, with no card row.
    func testATurnThatNeedsYouHasNoCardRowAndItsFooterSaysSo() {
        let model = TranscriptModel(events: [
            E.event(1, "turn.started", ["turnId": "t1"], turn: "t1"),
            E.text(2, "m1", "Built it."),
            done(3, turn: "t1", needs: "you", asks: [["action": "Paste the key", "where": "Settings", "reply": "done"], ["action": "Pick a budget"]]),
            E.event(4, "asks.ticked", ["asksSeq": 3, "ticked": [0]], turn: nil),
        ])
        XCTAssertFalse(model.rows.contains { $0.kind == .asks })
        guard case .footer(let footer)? = model.row(id: "f:t1")?.content else { return XCTFail() }
        XCTAssertEqual(footer.needs, "you")
    }

    func testOnlyACompletedTurnThatNeedsYouWithAsksGetsACard() {
        let model = TranscriptModel(events: [
            done(1, turn: "t1", needs: "you"),
            done(2, turn: "t2", needs: "you", asks: [["action": "x"]], outcome: "interrupted"),
            E.event(3, "asks.ticked", ["asksSeq": 99, "ticked": [0]], turn: nil),
        ])
        XCTAssertFalse(model.rows.contains { $0.kind == .asks })
    }

    func testSummaryDecodesNeedsAndAsks() throws {
        let json = #"{"id":"a","title":"T","needsYou":true,"needs":"you","asksSeq":12,"asks":[{"action":"Paste the key","where":"Settings","reply":"done","ticked":true},{"action":"Pick one"},{"bad":1}]}"#
        let thread = try JSONDecoder().decode(ThreadSummary.self, from: Data(json.utf8))
        XCTAssertEqual(thread.needs, "you")
        XCTAssertEqual(thread.asksSeq, 12)
        XCTAssertEqual(thread.asks, [Ask(action: "Paste the key", where_: "Settings", reply: "done", ticked: true), Ask(action: "Pick one")])
        XCTAssertEqual(thread.firstOpenAsk?.action, "Pick one")
        let again = try JSONDecoder().decode(ThreadSummary.self, from: JSONEncoder().encode(thread))
        XCTAssertEqual(again.asks, thread.asks)
        XCTAssertEqual(again.needs, "you")
        // An older runner sends none of it.
        let old = try JSONDecoder().decode(ThreadSummary.self, from: Data(#"{"id":"a","preview":"Last line"}"#.utf8))
        XCTAssertNil(old.needs)
        XCTAssertNil(old.firstOpenAsk)
    }

    func testADoneThreadIsUnreadWithATickNotNeedingYou() {
        var thread = ThreadSummary(id: "t", title: "t", status: .idle, needsYou: false, lastSeq: 9, lastSeenSeq: 4, needs: "nothing")
        XCTAssertEqual(ThreadRowLook(thread), ThreadRowLook(status: .time, unread: true, emphasised: true, done: true))
        XCTAssertEqual(ThreadSections.build([thread], now: Date()).inbox.map(\.id), ["t"])
        thread.lastSeenSeq = 9
        XCTAssertEqual(ThreadRowLook(thread), ThreadRowLook(status: .time, unread: false, emphasised: false))
    }
}
