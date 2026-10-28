import XCTest
@testable import ThreadbearCore

/// Explain's side conversation: what each turn sends to `threads.explain`.
final class ExplainTests: XCTestCase {
    func testFirstLookSendsTheSelectionAndMessage() {
        let session = ExplainSession(id: 1, selection: "  joining approval \n", message: "move joining approval onto the library")
        XCTAssertEqual(session.selection, "joining approval")
        XCTAssertTrue(session.isBusy, "the first explanation is asked for straight away")
        XCTAssertEqual(session.params(threadId: "t1", for: 0), .object([
            "threadId": .string("t1"), "selection": .string("joining approval"),
            "message": .string("move joining approval onto the library"),
        ]))
    }

    func testFollowUpsSendTheEarlierAnswers() {
        var session = ExplainSession(id: 1, selection: "the library", message: nil)
        XCTAssertNil(session.ask("which one?"), "not while the first answer is coming")
        session.turns[0].answer = "The state machines library."
        XCTAssertNil(session.ask("   "))
        let index = session.ask(" which repo? ")
        XCTAssertEqual(index, 1)
        XCTAssertEqual(session.params(threadId: "t1", for: 1), .object([
            "threadId": .string("t1"), "selection": .string("the library"),
            "earlier": .array([.object(["answer": .string("The state machines library.")])]),
            "question": .string("which repo?"),
        ]))
    }

    func testRetryOnlyAfterAFailure() {
        var session = ExplainSession(id: 1, selection: "x", message: nil)
        XCTAssertFalse(session.retry(0))
        session.turns[0].error = "No room"
        XCTAssertFalse(session.isBusy)
        XCTAssertTrue(session.retry(0))
        XCTAssertTrue(session.isBusy)
    }

    func testTitleIsShortAndOnOneLine() {
        XCTAssertEqual(ExplainSession(id: 1, selection: "joining approval", message: nil).title, "\u{201C}joining approval\u{201D}")
        let long = ExplainSession(id: 1, selection: String(repeating: "word ", count: 20) + "\nsecond line", message: nil).title
        XCTAssertTrue(long.hasSuffix("…\u{201D}"))
        XCTAssertFalse(long.contains("second"))
    }
}
