import Foundation
import Testing
@testable import ThreadbearKit

@Suite struct TurnsTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func m(_ seq: Int, _ role: PhoneMessage.Role, _ text: String, at: Double, origin: String? = nil, summary: Bool = false) -> PhoneMessage {
        PhoneMessage(seq: seq, role: role, text: text, origin: origin, toolKind: role == .tool ? "command" : nil, summary: summary, at: t0.addingTimeInterval(at))
    }

    @Test func aFinishedTurnFoldsItsWorkAndShowsTheSummary() {
        let messages = [
            m(1, .user, "Fix it", at: 0),
            m(2, .assistant, "Looking.", at: 5),
            m(3, .tool, "Run the tests", at: 10),
            m(4, .assistant, "Done.", at: 120),
            m(5, .tool, "threadbear: end_turn", at: 132),
            m(6, .assistant, "- Fixed it\n- Tests pass", at: 133, summary: true),
        ]
        let items = Turns.fold(messages, busy: false)
        #expect(items.count == 3)
        guard case let .worked(w) = items[1] else { Issue.record("expected the work folded"); return }
        #expect(w.title == "Worked for 2m 13s")
        guard case let .message(reply) = items[2] else { Issue.record("expected the reply"); return }
        #expect(reply.seq == 6)
        #expect(Set(items.map(\.id)).count == items.count)
    }

    @Test func aLongerMessageAfterTheLastStepBeatsTheBullets() {
        let messages = [
            m(1, .user, "Why?", at: 0),
            m(2, .tool, "Read x.ts", at: 1),
            m(3, .assistant, "Because the cache is keyed by folder, so two threads in one folder share a run and the second never starts its own.", at: 30),
            m(4, .tool, "threadbear: end_turn", at: 31),
            m(5, .assistant, "- Explained it", at: 31, summary: true),
        ]
        let items = Turns.fold(messages, busy: false)
        guard case let .message(reply) = items.last else { Issue.record("expected a reply"); return }
        #expect(reply.seq == 3)
    }

    @Test func theTurnStillRunningIsNotFoldedAndRunnerMessagesJoinTheTurnBefore() {
        let messages = [
            m(1, .user, "Go", at: 0),
            m(2, .tool, "Build", at: 1),
            m(3, .assistant, "Built.", at: 2),
            m(4, .user, "The app restarted", at: 3, origin: "runner"),
            m(5, .tool, "Check it", at: 4),
            m(6, .assistant, "Checked.", at: 9),
            m(7, .user, "Next", at: 20),
            m(8, .tool, "Run", at: 21),
        ]
        let items = Turns.fold(messages, busy: true)
        // Go, its work, its reply "Checked.", then the live turn as it comes.
        guard case let .worked(w) = items[1] else { Issue.record("expected the first turn folded"); return }
        #expect(w.title == "Worked for 9s")
        guard case let .message(reply) = items[2] else { Issue.record("expected its reply"); return }
        #expect(reply.seq == 6)
        guard case .message(let next) = items[3], next.seq == 7, case .tools = items[4] else { Issue.record("expected the live turn unfolded"); return }
        #expect(items.count == 5)
    }

    @Test func aQuickAnswerHasNothingToFold() {
        let items = Turns.fold([m(1, .user, "Hi", at: 0), m(2, .assistant, "Hello", at: 2)], busy: false)
        #expect(items.count == 2)
    }

    @Test func answersAreWrittenAsTheMacWritesThem() {
        let asks = [
            PhoneAsk(action: "Merge it?", why: "Tests pass.", options: ["Merge", "Not yet"]),
            PhoneAsk(action: "Add the key", why: "In Settings.", reply: "done"),
        ]
        #expect(asks[1].paragraph == "Add the key. In Settings.")
        #expect(AskAnswer.message(asks: asks, picks: [1: 0], extra: "thanks") == "2. Add the key\n   done\n\nthanks")
        #expect(AskAnswer.message(asks: [asks[0]], picks: [0: 1]) == "Merge it?\nNot yet")
        #expect(AskAnswer.answers(asks: asks, picks: [0: 5]).isEmpty)
    }

    @Test func threadRowsAndMessagesDecodeTheCard() throws {
        let row = #"""
        {"threadId":"t","runnerId":"r","title":"T","cwd":"/w","accountId":"a","provider":"claude","status":"idle","needsYou":true,"unread":true,"preview":"p","lastActivityAt":"2026-10-30T00:00:00.000Z","view":"inbox",
         "asks":[{"action":"Merge it?","why":"Tests pass.","options":["Merge","Not yet"],"suggested":0.0,"links":[{"title":"Open PR","url":"https://x"}]}],"asksSeq":12.0,"next":["Ship it"]}
        """#
        let thread = try JSONDecoder().decode(PhoneThread.self, from: Data(row.utf8))
        #expect(thread.asks?.first?.suggestedIndex == 0)
        #expect(thread.asksSeq == 12)
        #expect(thread.next == ["Ship it"])
        let msg = try JSONDecoder().decode(PhoneMessage.self, from: Data(#"{"seq":3.0,"role":"assistant","text":"- a","summary":true,"at":"2026-10-30T00:00:00.000Z"}"#.utf8))
        #expect(msg.summary)
    }
}
