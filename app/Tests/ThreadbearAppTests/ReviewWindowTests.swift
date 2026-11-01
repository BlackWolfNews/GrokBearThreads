import AppKit
import SwiftUI
import XCTest
@testable import Threadbear
import ThreadbearCore

/// Real mouse events through a real window: SwiftUI buttons over AppKit
/// views have swallowed clicks here before (Mike, 29 and 30 Oct), and a test
/// that only checked hit testing passed while the click did nothing.
@MainActor
final class ReviewWindowTests: XCTestCase {
    func testClickingAChoiceInTheRailPicksItAndOpensItsNoteBox() {
        let (session, host, window) = make()
        defer { window.close() }
        XCTAssertEqual(noteBoxes(in: host), 0, "no boxes until there's a reason for one")
        click("Pick C", in: host, window)
        XCTAssertEqual(session.draft.pickedId, "C")
        XCTAssertEqual(noteBoxes(in: host), 1, "adding detail to a pick takes no extra step")
        click("Pick B", in: host, window)
        XCTAssertEqual(session.draft.pickedId, "B")
        XCTAssertEqual(noteBoxes(in: host), 1, "the empty box moves with the pick")
        click("Unpick B", in: host, window)
        XCTAssertNil(session.draft.pickedId)
        XCTAssertEqual(noteBoxes(in: host), 0)
    }

    func testANoteKeepsItsBoxWhenThePickMoves() {
        let (session, host, window) = make()
        defer { window.close() }
        click("Pick C", in: host, window)
        session.setNote("Fainter", for: "C")
        pump()
        click("Pick B", in: host, window)
        XCTAssertEqual(noteBoxes(in: host), 2, "the note on C stays on show, and B gets a box")
    }

    func testAChoiceThatIsntPickedCanStillGetANote() {
        let (session, host, window) = make()
        defer { window.close() }
        click("Add a note on B", in: host, window)
        XCTAssertEqual(noteBoxes(in: host), 1)
        XCTAssertNil(session.draft.pickedId, "a note isn't a pick")
    }

    func testClickingAnImageEnlargesItAndAgainGoesBack() {
        let (session, host, window) = make()
        defer { window.close() }
        click("C: click to enlarge", in: host, window)
        XCTAssertEqual(session.mode, .single)
        XCTAssertEqual(session.visibleIndices, [2])
        click("C: click to see them all", in: host, window)
        XCTAssertEqual(session.mode, .all)
    }

    func testChoosingInTheRailWhileEnlargedShowsThatOne() {
        let (session, host, window) = make()
        defer { window.close() }
        session.enlarge(0)
        pump()
        click("Pick C", in: host, window)
        XCTAssertEqual(session.visibleIndices, [2])
    }

    func testSendSaysWhatItWillSend() {
        let (session, host, window) = make()
        defer { window.close() }
        XCTAssertFalse(session.canSubmit)
        XCTAssertEqual(session.sendLabel, "Send")
        session.setNote("Too busy", for: "A")
        XCTAssertEqual(session.sendLabel, "Send notes")
        click("Pick C", in: host, window)
        XCTAssertEqual(session.sendLabel, "Send C")
        XCTAssertTrue(session.canSubmit)
    }

    func testASentReviewHasNothingToPress() async {
        var answered = review()
        answered.status = "answered"
        answered.response = ReviewDraft(pickedId: "C", notes: ["C": "Fainter"])
        let (_, host, window) = make(answered)
        defer { window.close() }
        XCTAssertNil(anchor("Pick A", in: host))
        XCTAssertNil(anchor("Unpick C", in: host))
        XCTAssertNil(anchor("Add a note on B", in: host))
        XCTAssertEqual(noteBoxes(in: host), 0, "the note is shown as text, not a box that can't be typed in")
    }

    private func review() -> DesignReview {
        let options = ["A", "B", "C"].map {
            ReviewOption(id: $0, title: "Option \($0)", note: "Why \($0)", image: ImageRef(path: "/tmp/\($0).png", mediaType: "image/png"))
        }
        return DesignReview(id: "review", title: "Rail", options: options)
    }

    private func make(_ given: DesignReview? = nil) -> (ReviewSession, NSView, NSWindow) {
        let review = given ?? review()
        let service = ReviewService(load: { review }, save: { _, _ in review }, respond: { _, _ in review }, cancel: { _ in review })
        let session = ReviewSession(threadId: "thread", review: review, service: service,
                                    defaults: UserDefaults(suiteName: "ReviewWindowTests.\(UUID().uuidString)")!, autosave: false)
        let host = NSHostingView(rootView: ReviewWindow(session: session, back: {}, close: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // SwiftUI's Buttons ignore clicks in a window that was never
        // ordered in, so it's ordered in off screen, out of Mike's way.
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        window.makeKey()
        host.layoutSubtreeIfNeeded()
        pump()
        return (session, host, window)
    }

    private func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }

    private func noteBoxes(in host: NSView) -> Int {
        func boxes(_ view: NSView) -> Int {
            (view is NSTextView ? 1 : 0) + view.subviews.reduce(0) { $0 + boxes($1) }
        }
        return boxes(host)
    }

    /// Each control's tip anchor sits behind it, the same size.
    private func anchor(_ tip: String, in host: NSView) -> TipAnchorView? {
        func anchors(_ view: NSView) -> [TipAnchorView] {
            view.subviews.flatMap { ($0 as? TipAnchorView).map { [$0] } ?? anchors($0) }
        }
        return anchors(host).first { $0.text == tip }
    }

    /// A press and release, sent through the window as a real click is.
    private func click(_ tip: String, in host: NSView, _ window: NSWindow) {
        guard let anchor = anchor(tip, in: host) else { return XCTFail("nothing with the tip \(tip)") }
        let point = anchor.convert(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                           pressure: type == .leftMouseDown ? 1 : 0)!
            window.sendEvent(event)
        }
        pump()
    }
}
