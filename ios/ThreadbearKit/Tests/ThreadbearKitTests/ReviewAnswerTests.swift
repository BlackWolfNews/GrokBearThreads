import Testing
@testable import ThreadbearKit

@Suite struct ReviewAnswerTests {
    static let id = "74d1e391-cbc6-4b23-bd6b-cfed7cb79488"

    @Test func aPickShowsTheOptionNotTheId() {
        let answer = ReviewAnswer.parse("Review: End of turn: summary + what's next (\(Self.id))\n\nPicked A. A: summary is the agent's last message.")
        #expect(answer?.title == "End of turn: summary + what's next")
        #expect(answer?.lines == [.init(label: "End of turn: summary + what's next", text: "Picked A: summary is the agent's last message")])
    }

    @Test func notesKeepTheirParagraphsAndBrackets() {
        let text = "Review: Picker (\(Self.id))\n\nPicked B. One picker.\n\nNotes on A (Auto (smart)): Too clever.\n\nSecond thought.\n\nNotes on B (One picker): Ship it"
        #expect(ReviewAnswer.parse(text)?.lines == [
            .init(label: "Picker", text: "Picked B: One picker"),
            .init(label: "Notes on A: Auto (smart)", text: "Too clever.\n\nSecond thought."),
            .init(label: "Notes on B: One picker", text: "Ship it"),
        ])
    }

    @Test func onlyNotesPutTheTitleOverTheFirst() {
        let answer = ReviewAnswer.parse("Review: Picker (\(Self.id))\n\nNotes on D (Moving): Keep this")
        #expect(answer?.lines == [.init(label: "Picker\nNotes on D: Moving", text: "Keep this")])
    }

    @Test func otherMessagesAreLeftAlone() {
        #expect(ReviewAnswer.parse("Review: this PR please") == nil)
        #expect(ReviewAnswer.parse("Review: Picker (not-a-uuid)\n\nPicked A. Thing.") == nil)
        #expect(ReviewAnswer.parse("Review: Picker (\(Self.id))") == nil)
        #expect(ReviewAnswer.parse("Review: Picker (\(Self.id))\n\nSomething else entirely") == nil)
    }
}
