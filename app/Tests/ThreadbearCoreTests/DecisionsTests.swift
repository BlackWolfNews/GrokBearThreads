import XCTest
@testable import ThreadbearCore

/// docs/protocol.md, "Needs you", Answering: stepping through the open
/// card's asks and the one message that answers them.
final class DecisionsTests: XCTestCase {
    private let merge = Ask(action: "Merge #52 to prod, or test locally first?", why: "Preview is green.", options: ["Merge", "Test locally first"], suggested: 0)
    private let signIn = Ask(action: "Sign in to PostHog in Chrome", reply: "done")
    private let events = Ask(action: "Which events matter most?")

    func testDecodesOptionsAndDropsAPickThatIsNotOne() throws {
        let json = #"{"action":"a","why":"w","options":["x","y"],"suggested":1}"#
        let ask = try JSONDecoder().decode(Ask.self, from: Data(json.utf8))
        XCTAssertEqual(ask.options, ["x", "y"])
        XCTAssertEqual(ask.suggested, 1)
        XCTAssertEqual(ask.why, "w")
        let bad = try JSONDecoder().decode(Ask.self, from: Data(#"{"action":"a","options":["x"],"suggested":3}"#.utf8))
        XCTAssertNil(bad.suggested)
        let plain = try JSONDecoder().decode(Ask.self, from: Data(#"{"action":"a"}"#.utf8))
        XCTAssertEqual(plain.options, [])
    }

    /// A plain ask offers its reply words; one with neither has only his own.
    func testChoices() {
        XCTAssertEqual(Decisions.choices(for: merge), ["Merge", "Test locally first"])
        XCTAssertEqual(Decisions.choices(for: signIn), ["done"])
        XCTAssertEqual(Decisions.choices(for: events), [])
    }

    /// An ask with neither still gets the word it asks for as a button.
    func testChoicesFromTheAsksOwnWords() {
        XCTAssertEqual(Decisions.choices(for: Ask(action: "Say go for Short 2 (Thomas on AI being dumb), or name another")), ["Go"])
        XCTAssertEqual(Decisions.choices(for: Ask(action: "Have a look, then reply \"export\" and I'll upload it")), ["export"])
        XCTAssertEqual(Decisions.choices(for: Ask(action: "Reply “ship it” for the plan")), ["ship it"])
        XCTAssertEqual(Decisions.choices(for: Ask(action: "Say whether $1 a day is right")), [])
        XCTAssertEqual(Decisions.choices(for: Ask(action: "Paste your key, then say \"key set\"", options: ["Done"])), ["Done"])
    }

    func testAnswerText() {
        XCTAssertNil(Decisions.answerText(nil, ask: merge))
        XCTAssertNil(Decisions.answerText(DecisionAnswer(text: "  "), ask: merge))
        XCTAssertEqual(Decisions.answerText(DecisionAnswer(choice: 1), ask: merge), "Test locally first")
        XCTAssertEqual(Decisions.answerText(DecisionAnswer(choice: 0, text: "check the preview"), ask: merge), "Merge. check the preview")
        XCTAssertEqual(Decisions.answerText(DecisionAnswer(text: "Neither, revert it"), ask: merge), "Neither, revert it")
        XCTAssertEqual(Decisions.answerText(DecisionAnswer(choice: 0, later: true), ask: merge), "Later, leave this one open")
    }

    /// Numbered as on the card, question then answer, the agent's pick for
    /// one he left alone, skipped ones with no pick left out
    /// with the others keeping their numbers, then anything else he wrote.
    func testMessage() {
        let text = Decisions.message(
            asks: [merge, signIn, events],
            answers: [2: DecisionAnswer(text: "Signups\nand searches")],
            extra: "  Also bump the version.  "
        )
        XCTAssertEqual(text, """
        1. Merge #52 to prod, or test locally first?
           Merge

        3. Which events matter most?
           Signups
           and searches

        Also bump the version.
        """)
        XCTAssertEqual(Decisions.message(asks: [events], answers: [:], extra: "just this"), "just this")
        XCTAssertEqual(Decisions.message(asks: [events], answers: [:]), "")
        // Changing a pick, or saying Later, beats the suggestion.
        XCTAssertEqual(Decisions.message(asks: [merge], answers: [0: DecisionAnswer(later: true)]), "Merge #52 to prod, or test locally first?\nLater, leave this one open")
        XCTAssertEqual(Decisions.answer(0, asks: [merge], answers: [:]), DecisionAnswer(choice: 0))
        XCTAssertNil(Decisions.answer(1, asks: [merge, events], answers: [:]))
        // The composer's own send takes only what he answered.
        XCTAssertEqual(Decisions.message(asks: [merge, events], answers: [1: DecisionAnswer(text: "signups")], extra: "and this", withSuggestions: false),
                       "2. Which events matter most?\n   signups\n\nand this")
    }
}
