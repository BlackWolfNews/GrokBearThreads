import XCTest
@testable import ThreadbearCore

final class SpokenTextTests: XCTestCase {
    func testMarkdownIsReadAsWords() {
        let reply = """
        ## Dinner tonight

        Try **lemon pasta**. It takes [20 minutes](https://example.com/recipe).

        - Boil the `pasta`
        - Zest a lemon
        """
        XCTAssertEqual(SpokenText.plain(reply), "Dinner tonight. Try lemon pasta. It takes 20 minutes. Boil the pasta. Zest a lemon.")
    }

    func testCodeAndTablesAreLeftForTheScreen() {
        let reply = """
        Here it is:

        ```swift
        let x = 1
        let y = 2
        ```

        | a | b |
        |---|---|
        | 1 | 2 |

        Done.
        """
        XCTAssertEqual(SpokenText.sentences(reply), ["Here it is: " + SpokenText.codeLine, SpokenText.tableLine, "Done."])
    }

    func testBareLinksAreNotSpelledOut() {
        XCTAssertEqual(SpokenText.plain("See https://threadbear.mikecann.app/docs for more"), "See a link for more.")
    }

    func testSentencesSplitAtStops() {
        XCTAssertEqual(SpokenText.sentences("One. Two? Three! Version 1.5 is out."), ["One.", "Two?", "Three!", "Version 1.5 is out."])
    }

    func testLongSentencesAreCut() {
        let long = Array(repeating: "word", count: 80).joined(separator: " ")
        let parts = SpokenText.sentences(long, maxLength: 60)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 60 })
        XCTAssertEqual(parts.joined(separator: " "), long + ".")
    }

    func testNothingToSay() {
        XCTAssertEqual(SpokenText.sentences("  \n---\n"), [])
    }
}

final class VoiceCatalogTests: XCTestCase {
    func testEmilyAndMikeComeFirst() {
        XCTAssertEqual(VoiceCatalog.voices.prefix(2).map(\.name), ["Emily", "Mike"])
        XCTAssertEqual(VoiceCatalog.voice("mike").engineVoice, "michael")
        XCTAssertEqual(VoiceCatalog.voice("nobody"), VoiceCatalog.defaultVoice)
        XCTAssertEqual(Set(VoiceCatalog.voices.map(\.id)).count, VoiceCatalog.voices.count)
    }

    func testSpeeds() {
        XCTAssertEqual(VoiceCatalog.speedTitle(1), "1x")
        XCTAssertEqual(VoiceCatalog.speedTitle(1.25), "1.25x")
        XCTAssertEqual(VoiceCatalog.speed(nil), 1)
        XCTAssertEqual(VoiceCatalog.speed(1.3), 1.25)
        XCTAssertEqual(VoiceCatalog.speed(9), 2)
    }

    func testLanguageFallsBackToEnglish() {
        XCTAssertEqual(VoiceCatalog.language("klingon").id, "english")
        XCTAssertEqual(VoiceCatalog.language("french").locale, "fr-FR")
    }
}

final class UtteranceTrackerTests: XCTestCase {
    typealias R = UtteranceTracker.Result

    func testSendsAfterAPause() {
        var t = UtteranceTracker(pause: 1)
        XCTAssertTrue(t.add(R(text: "what should", start: 0, end: 1, isFinal: false), now: 10))
        t.add(R(text: "what should I cook", start: 0, end: 1.6, isFinal: false), now: 10.5)
        XCTAssertEqual(t.pending, "what should I cook")
        XCTAssertNil(t.take(now: 11.2))
        XCTAssertEqual(t.take(now: 11.6), "what should I cook")
        XCTAssertNil(t.take(now: 20))
    }

    func testFinalReplacesTheGuessItCovers() {
        var t = UtteranceTracker(pause: 1)
        t.add(R(text: "what should I cook", start: 0, end: 1.6, isFinal: false), now: 0)
        t.add(R(text: "What should I cook?", start: 0, end: 1.6, isFinal: true), now: 0.2)
        t.add(R(text: "tonight", start: 1.8, end: 2.3, isFinal: false), now: 0.4)
        XCTAssertEqual(t.pending, "What should I cook? tonight")
    }

    func testLateFinalForSentAudioIsDropped() {
        var t = UtteranceTracker(pause: 1)
        t.add(R(text: "hello there", start: 0, end: 1, isFinal: false), now: 0)
        XCTAssertEqual(t.take(now: 1.5), "hello there")
        // The recogniser finalises the same stretch after it went.
        XCTAssertFalse(t.add(R(text: "Hello there.", start: 0, end: 1, isFinal: true), now: 1.7))
        XCTAssertFalse(t.hasWords)
        // What he says next still counts.
        XCTAssertTrue(t.add(R(text: "and more", start: 1.2, end: 2, isFinal: false), now: 1.8))
        XCTAssertEqual(t.pending, "and more")
    }

    func testSilenceAloneSendsNothing() {
        var t = UtteranceTracker(pause: 1)
        XCTAssertFalse(t.add(R(text: " ", start: 0, end: 1, isFinal: true), now: 0))
        XCTAssertNil(t.take(now: 5))
        XCTAssertNil(t.flush())
    }
}

final class SpokenAnswerTests: XCTestCase {
    let all: [ApprovalOption] = [.allow, .allowAlways, .deny]

    func testYes() {
        for said in ["Yes.", "yeah go ahead", "Go ahead, please.", "Sure", "OK, do it!", "yes thank you", "Um, yes."] {
            XCTAssertEqual(SpokenAnswer.decision(said, options: all), .allow, said)
        }
    }

    func testNo() {
        for said in ["No.", "Nope", "Don't do that.", "no thanks", "Cancel"] {
            XCTAssertEqual(SpokenAnswer.decision(said, options: all), .deny, said)
        }
    }

    func testAlways() {
        XCTAssertEqual(SpokenAnswer.decision("Always allow it", options: all), .allowAlways)
        // No always on this card: not taken as a plain yes either.
        XCTAssertNil(SpokenAnswer.decision("always allow", options: [.allow, .deny]))
    }

    func testAnythingMoreIsAMessage() {
        for said in ["No, use the other folder instead", "yes but only for the tests folder", "what does that command do", "thank you", ""] {
            XCTAssertNil(SpokenAnswer.decision(said, options: all), said)
        }
    }
}

/// A spoken yes can let a tool run, so it goes only to the card he heard.
final class SpokenApprovalsTests: XCTestCase {
    private func card(_ id: String, title: String = "Run the tests", name: String = "Bash", options: [ApprovalOption] = [.allow, .allowAlways, .deny]) -> ApprovalRequest {
        ApprovalRequest(approvalId: id, name: name, title: title, options: options)
    }

    func testNothingWaitingIsAMessage() {
        var a = SpokenApprovals()
        XCTAssertEqual(a.take("yes"), .message)
    }

    func testAYesAnswersTheCardReadOut() {
        var a = SpokenApprovals()
        let first = card("a")
        a.requested(first)
        a.readOut(first)
        XCTAssertEqual(a.take("yes"), .answer(first, .allow))
        XCTAssertTrue(a.open.isEmpty)
        XCTAssertEqual(a.take("yes"), .message, "answered once, and that's it")
    }

    func testBeforeItIsReadOutAYesAnswersNothing() {
        var a = SpokenApprovals()
        let first = card("a")
        a.requested(first)
        XCTAssertEqual(a.take("yes"), .readAgain(first))
        XCTAssertEqual(a.open, [first], "still waiting")
    }

    /// The one the review found: a new card just before he speaks.
    func testANewCardJustBeforeHeSpeaksDoesNotTakeHisYes() {
        var a = SpokenApprovals()
        let first = card("a"), second = card("b", title: "Delete everything")
        a.requested(first)
        a.readOut(first)
        a.requested(second)
        XCTAssertEqual(a.take("yes"), .readAgain(second))
        XCTAssertEqual(a.open, [first, second], "neither was answered")
    }

    func testAnOlderCardFinishingItsReadOutDoesNotBindOverANewerOne() {
        var a = SpokenApprovals()
        let first = card("a"), second = card("b")
        a.requested(first)
        a.requested(second)
        a.readOut(first)
        XCTAssertNil(a.heard)
        XCTAssertEqual(a.take("yes"), .readAgain(second))
        a.readOut(second)
        XCTAssertEqual(a.take("yes"), .answer(second, .allow))
        // Then the older one, once it has been read in turn.
        XCTAssertEqual(a.take("yes"), .readAgain(first))
        a.readOut(first)
        XCTAssertEqual(a.take("no"), .answer(first, .deny))
    }

    func testAGoneCardIsNotAnswered() {
        var a = SpokenApprovals()
        let first = card("a")
        a.requested(first)
        a.readOut(first)
        a.resolved("a")
        XCTAssertEqual(a.take("yes"), .message)
    }

    func testAChangedCardMustBeHeardAgain() {
        var a = SpokenApprovals()
        let first = card("a", title: "Run the tests"), changed = card("a", title: "Delete everything")
        a.requested(first)
        a.readOut(first)
        a.requested(changed)
        XCTAssertEqual(a.take("yes"), .readAgain(changed))
        // The first wording's read-out finishing late doesn't count for it.
        a.readOut(first)
        XCTAssertEqual(a.take("yes"), .readAgain(changed))
        a.readOut(changed)
        XCTAssertEqual(a.take("yes"), .answer(changed, .allow))
    }

    func testAlwaysOnlyWhereTheCardOffersIt() {
        var a = SpokenApprovals()
        let first = card("a", options: [.allow, .deny])
        a.requested(first)
        a.readOut(first)
        XCTAssertEqual(a.take("always allow"), .readAgain(first), "not a plain yes, and read out again")
        a.readOut(first)
        XCTAssertEqual(a.take("yes"), .answer(first, .allow))
    }

    func testLongerWordsAreAMessage() {
        var a = SpokenApprovals()
        let first = card("a")
        a.requested(first)
        a.readOut(first)
        XCTAssertEqual(a.take("no, use the other folder"), .message)
        XCTAssertEqual(a.heard, first, "still the card he heard")
    }

    func testAnotherMacsRequestAndAPlanAreLeftToTheScreen() {
        for name in [StartRequest.cardName, "ExitPlanMode"] {
            var a = SpokenApprovals()
            let first = card("a", name: name)
            a.requested(first)
            a.readOut(first)
            XCTAssertNil(a.heard, name)
            XCTAssertEqual(a.take("yes"), .onScreen(first), name)
            XCTAssertEqual(a.open, [first], name)
        }
    }

    func testClearForgetsAll() {
        var a = SpokenApprovals()
        let first = card("a")
        a.requested(first)
        a.readOut(first)
        a.clear()
        XCTAssertEqual(a.take("yes"), .message)
    }
}
