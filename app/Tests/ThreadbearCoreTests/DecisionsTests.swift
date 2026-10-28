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

    func testDecodesLinksAndWhatTheyOpen() throws {
        let json = #"{"action":"a","links":[{"title":"Open login","url":"https://hf.co/login"},{"title":"Notes","url":"~/notes.md"},{"title":"bad"}]}"#
        let ask = try JSONDecoder().decode(Ask.self, from: Data(json.utf8))
        XCTAssertEqual(ask.links, [AskLink(title: "Open login", url: "https://hf.co/login"), AskLink(title: "Notes", url: "~/notes.md")])
        XCTAssertEqual(ask.links[0].target?.absoluteString, "https://hf.co/login")
        XCTAssertEqual(ask.links[1].target?.path, NSHomeDirectory() + "/notes.md")
        XCTAssertNil(AskLink(title: "x", url: "javascript:alert(1)").target)
    }

    /// Numbered as on the card, question then answer, unpicked ones left
    /// out with the others keeping their numbers, then his own words.
    func testMessage() {
        let text = Decisions.message(asks: [merge, signIn, events], picks: [0: 1, 1: 0], extra: "  Also bump the version.  ")
        XCTAssertEqual(text, """
        1. Merge #52 to prod, or test locally first?
           Test locally first

        2. Sign in to PostHog in Chrome
           done

        Also bump the version.
        """)
        XCTAssertEqual(Decisions.message(asks: [merge], picks: [0: 0]), "Merge #52 to prod, or test locally first?\nMerge")
        XCTAssertEqual(Decisions.message(asks: [events], picks: [:], extra: "just this"), "just this")
        // A pick that isn't one of its choices doesn't count.
        XCTAssertEqual(Decisions.message(asks: [events], picks: [0: 0]), "")
        XCTAssertEqual(Decisions.answers(asks: [merge, events], picks: [0: 0, 1: 2]).map(\.answer), [AskAnswer(action: merge.action, answer: "Merge")])
    }

    /// The bubble finds his own words after the answers, or shows the text
    /// as it is when it doesn't start with them.
    func testExtraAfterTheAnswers() {
        let asks = [merge, signIn, events]
        let answers = Decisions.answers(asks: asks, picks: [0: 0, 1: 0]).map(\.answer)
        let text = Decisions.message(asks: asks, picks: [0: 0, 1: 0], extra: "Also this.\n\nAnd that.")
        XCTAssertEqual(Decisions.extra(in: text, answers: answers), "Also this.\n\nAnd that.")
        XCTAssertEqual(Decisions.extra(in: Decisions.message(asks: [merge], picks: [0: 1]), answers: [AskAnswer(action: merge.action, answer: "Test locally first")]), "")
        XCTAssertNil(Decisions.extra(in: "something else", answers: answers))
        XCTAssertNil(Decisions.extra(in: text, answers: []))
    }

    /// "Something else": what he wrote answers that ask, with his line
    /// breaks kept, and nothing is left over as extra.
    func testSomethingElseTakesWhatHeWrote() {
        let picks = [0: 0, 2: Decisions.ownAnswer]
        let text = Decisions.message(asks: [merge, signIn, events], picks: picks, extra: " Signups\nand searches ")
        XCTAssertEqual(text, """
        1. Merge #52 to prod, or test locally first?
           Merge

        3. Which events matter most?
           Signups
           and searches
        """)
        let answers = Decisions.answers(asks: [merge, signIn, events], picks: picks, written: "Signups\nand searches").map(\.answer)
        XCTAssertEqual(answers.last, AskAnswer(action: events.action, answer: "Signups\nand searches"))
        XCTAssertEqual(Decisions.extra(in: text, answers: answers), "")
        // Nothing written: that ask isn't answered.
        XCTAssertEqual(Decisions.message(asks: [merge, events], picks: [1: Decisions.ownAnswer]), "")
        XCTAssertEqual(Decisions.message(asks: [events], picks: [0: Decisions.ownAnswer], extra: "Signups"), "Which events matter most?\nSignups")
    }
}
