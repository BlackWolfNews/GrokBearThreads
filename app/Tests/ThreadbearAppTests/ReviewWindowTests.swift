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
    func testItOpensOnTheFirstAndStepsThroughToAllOfThem() {
        let (session, host, window) = make()
        defer { window.close() }
        XCTAssertEqual(session.mode, .single, "a walkthrough, one at a time")
        XCTAssertEqual(session.visibleIndices, [0])
        XCTAssertFalse(session.canStepBack, "nothing before the first")
        click("Next (\u{2192})", in: host, window)
        click("Next (\u{2192})", in: host, window)
        XCTAssertEqual(session.visibleIndices, [2])
        click("Next (\u{2192})", in: host, window)
        XCTAssertEqual(session.visibleIndices, [3], "a reference is a step too")
        click("See them all and choose (\u{2192})", in: host, window)
        XCTAssertEqual(session.mode, .all, "it ends on all of them, to choose")
        XCTAssertFalse(session.canStepForward)
        click("Back to the last one (\u{2190})", in: host, window)
        XCTAssertEqual(session.visibleIndices, [3])
        click("Previous (\u{2190})", in: host, window)
        XCTAssertEqual(session.visibleIndices, [2])
    }

    func testAMarkUnderTheImageGoesStraightToItsStep() {
        let (session, host, window) = make()
        defer { window.close() }
        click("C. Option C", in: host, window)
        XCTAssertEqual(session.visibleIndices, [2])
        click("See them all and choose (Esc)", in: host, window)
        XCTAssertEqual(session.mode, .all)
    }

    func testClickingAnyRowInTheRailShowsItReferencesToo() {
        let (session, host, window) = make()
        defer { window.close() }
        click("Show A2", in: host, window)
        XCTAssertEqual(session.visibleIndices, [3], "a reference row used to do nothing")
        XCTAssertNil(session.draft.pickedId, "showing isn't picking")
        session.showAll()
        pump()
        click("Show B", in: host, window)
        XCTAssertEqual(session.visibleIndices, [1], "from all of them too")
    }

    func testTheOneOnShowHasItsNoteBoxOut() {
        let (session, host, window) = make()
        defer { window.close() }
        XCTAssertEqual(noteBoxes(in: host), 1, "a thought about the first is just typing")
        click("Next (\u{2192})", in: host, window)
        XCTAssertEqual(noteBoxes(in: host), 1, "the empty box moves along")
        session.setNote("Too busy", for: "B")
        pump()
        click("Next (\u{2192})", in: host, window)
        XCTAssertEqual(noteBoxes(in: host), 2, "B keeps its note on show")
        session.showAll()
        pump()
        XCTAssertEqual(noteBoxes(in: host), 1, "only the noted one when they're all up")
    }

    func testThePickCircleInTheRailPicksAndShowsIt() {
        let (session, host, window) = make()
        defer { window.close() }
        click("Pick C", in: host, window)
        XCTAssertEqual(session.draft.pickedId, "C")
        XCTAssertEqual(session.visibleIndices, [2])
        XCTAssertEqual(noteBoxes(in: host), 1)
        click("Pick B", in: host, window)
        XCTAssertEqual(session.draft.pickedId, "B")
        XCTAssertEqual(noteBoxes(in: host), 1, "the empty box moves with the pick")
        click("Unpick B", in: host, window)
        XCTAssertNil(session.draft.pickedId)
        XCTAssertNil(anchor("Pick A2", in: host), "a reference can't be picked")
    }

    func testPickingOnTheChoosingStepStaysOnIt() {
        let (session, host, window) = make()
        defer { window.close() }
        session.showAll()
        pump()
        XCTAssertEqual(noteBoxes(in: host), 0)
        click("Pick C", in: host, window)
        XCTAssertEqual(session.mode, .all)
        XCTAssertEqual(noteBoxes(in: host), 1, "adding detail to a pick takes no extra step")
        session.setNote("Fainter", for: "C")
        pump()
        click("Pick B", in: host, window)
        XCTAssertEqual(noteBoxes(in: host), 2, "the note on C stays on show, and B gets a box")
    }

    func testAChoiceThatIsntPickedCanStillGetANote() {
        let (session, host, window) = make()
        defer { window.close() }
        session.showAll()
        pump()
        click("Add a note on B", in: host, window)
        XCTAssertEqual(noteBoxes(in: host), 1)
        XCTAssertNil(session.draft.pickedId, "a note isn't a pick")
    }

    func testClickingAnImageEnlargesItAndAgainGoesBack() {
        let (session, host, window) = make()
        defer { window.close() }
        session.showAll()
        pump()
        click("C: click to enlarge", in: host, window)
        XCTAssertEqual(session.mode, .single)
        XCTAssertEqual(session.visibleIndices, [2])
        click("C: click to see them all", in: host, window)
        XCTAssertEqual(session.mode, .all)
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
        let (session, host, window) = make(answered)
        defer { window.close() }
        XCTAssertEqual(session.mode, .all, "nothing left to step towards")
        XCTAssertNil(anchor("Pick A", in: host))
        XCTAssertNil(anchor("Unpick C", in: host))
        XCTAssertNil(anchor("Add a note on B", in: host))
        XCTAssertEqual(noteBoxes(in: host), 0, "the note is shown as text, not a box that can't be typed in")
    }

    private func review() -> DesignReview {
        var options = ["A", "B", "C"].map {
            ReviewOption(id: $0, title: "Option \($0)", note: "Why \($0)", image: ImageRef(path: "/tmp/\($0).png", mediaType: "image/png"))
        }
        // A reference: to look at, not to pick.
        options.append(ReviewOption(id: "A2", title: "A's table", reference: true, image: ImageRef(path: "/tmp/A2.png", mediaType: "image/png")))
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
