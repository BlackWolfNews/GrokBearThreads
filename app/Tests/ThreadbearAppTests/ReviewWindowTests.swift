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
    func testItOpensOnTheFirstAndStepsThroughEveryShotToAllOfThem() {
        let (session, host, window) = make()
        defer { window.close() }
        XCTAssertEqual(session.mode, .single, "a walkthrough, one at a time")
        XCTAssertEqual(at(session), ["A", "0"])
        XCTAssertFalse(session.canStepBack, "nothing before the first")
        click("Next (\u{2192})", in: host, window)
        XCTAssertEqual(at(session), ["A", "1"], "A's own shots come first")
        click("Next (\u{2192})", in: host, window)
        click("Next (\u{2192})", in: host, window)
        XCTAssertEqual(at(session), ["B", "0"])
        click("Next (\u{2192})", in: host, window)
        XCTAssertEqual(at(session), ["B", "1"])
        click("Next (\u{2192})", in: host, window)
        click("Next (\u{2192})", in: host, window)
        XCTAssertEqual(at(session), ["Today", "0"], "a reference is a step too")
        click("Next (\u{2192})", in: host, window)
        click("See them all and choose (\u{2192})", in: host, window)
        XCTAssertEqual(session.mode, .all, "it ends on all of them, to choose")
        XCTAssertFalse(session.canStepForward)
        click("Back to the last one (\u{2190})", in: host, window)
        XCTAssertEqual(at(session), ["Today", "1"])
        click("Previous (\u{2190})", in: host, window)
        click("Previous (\u{2190})", in: host, window)
        XCTAssertEqual(at(session), ["C", "0"])
        click("Previous (\u{2190})", in: host, window)
        XCTAssertEqual(at(session), ["B", "1"], "back into B's last shot")
        click("Previous (\u{2190})", in: host, window)
        click("Previous (\u{2190})", in: host, window)
        XCTAssertEqual(at(session), ["A", "2"])
    }

    func testUpAndDownJumpBetweenOptionsPastTheirShots() {
        let (session, _, window) = make()
        defer { window.close() }
        session.browse(1)
        session.jump(1)
        XCTAssertEqual(at(session), ["B", "0"])
        session.jump(-1)
        XCTAssertEqual(at(session), ["A", "0"])
        session.jump(1); session.jump(1); session.jump(1)
        session.jump(1)
        XCTAssertEqual(session.mode, .all, "down from the last is all of them")
    }

    func testAMarkOrAShotGoesStraightToIt() {
        let (session, host, window) = make()
        defer { window.close() }
        click("C. Option C", in: host, window)
        XCTAssertEqual(at(session), ["C", "0"])
        click("A. Option A, Mid-drag", in: host, window)
        XCTAssertEqual(at(session), ["A", "1"], "a mark under the stage")
        click("A. Option A, Detail", in: host, window)
        XCTAssertEqual(at(session), ["A", "2"])
        click("See them all and choose (Esc)", in: host, window)
        XCTAssertEqual(session.mode, .all)
    }

    func testClickingAnyRowInTheRailShowsItReferencesToo() {
        let (session, host, window) = make()
        defer { window.close() }
        click("Show Today", in: host, window)
        XCTAssertEqual(at(session), ["Today", "0"], "a reference row used to do nothing")
        XCTAssertTrue(session.draft.pickedIds.isEmpty, "showing isn't picking")
        session.showAll()
        pump()
        click("Show B", in: host, window)
        XCTAssertEqual(at(session), ["B", "0"], "from all of them too")
    }

    func testSeveralCanBePickedAndStayInTheirOrder() {
        let (session, host, window) = make()
        defer { window.close() }
        click("Pick C", in: host, window)
        click("Pick A", in: host, window)
        XCTAssertEqual(session.draft.pickedIds, ["A", "C"])
        XCTAssertEqual(session.sendLabel, "Send A + C")
        XCTAssertEqual(at(session), ["A", "0"], "picking doesn't move the stage")
        click("Unpick C", in: host, window)
        XCTAssertEqual(session.draft.pickedIds, ["A"])
        XCTAssertNil(anchor("Pick Today", in: host), "a reference can't be picked")
    }

    func testNoneTakesThePicksAwayAndAPickTakesNoneAway() {
        let (session, host, window) = make()
        defer { window.close() }
        click("Pick B", in: host, window)
        click("None of them will do", in: host, window)
        XCTAssertTrue(session.draft.none)
        XCTAssertTrue(session.draft.pickedIds.isEmpty)
        XCTAssertEqual(session.sendLabel, "Send none of them")
        XCTAssertTrue(session.canSubmit)
        click("Pick B", in: host, window)
        XCTAssertFalse(session.draft.none)
    }

    func testOneReplyBoxAndSendSaysWhatItWillSend() {
        let (session, _, window) = make()
        defer { window.close() }
        XCTAssertFalse(session.canSubmit)
        XCTAssertEqual(session.sendLabel, "Send")
        session.setReply("Can you explain what these are for?")
        XCTAssertEqual(session.sendLabel, "Send reply")
        XCTAssertTrue(session.canSubmit, "words alone are an answer")
        session.pick("C")
        XCTAssertEqual(session.sendLabel, "Send C")
    }

    func testTheStageSaysWhichShotAndOffersTheLiveOne() {
        let (session, host, window) = make()
        defer { window.close() }
        XCTAssertNotNil(anchor("Try A running live: http://localhost:5190/a", in: host))
        click("C. Option C", in: host, window)
        XCTAssertNil(anchor("Try A running live: http://localhost:5190/a", in: host))
        XCTAssertEqual(session.focusedShot?.image.path, "/tmp/C.png", "one image is one shot")
    }

    func testTodayCanBeFlickedToByItsButtonOrHoldingSpace() {
        let (session, host, window) = make(native: true)
        defer { window.close() }
        session.enlarge(0, shot: 1)
        pump()
        click("Flick to Today: click, or hold Space", in: host, window)
        XCTAssertEqual(session.shownOption?.id, "Today")
        XCTAssertEqual(session.shownShot?.image.path, "/tmp/today2.png", "today's shot of the same name")
        XCTAssertEqual(at(session), ["A", "1"], "flicking isn't moving")
        click("Back to A (or let go of Space)", in: host, window)
        XCTAssertEqual(session.shownOption?.id, "A")
        func space(_ type: NSEvent.EventType) {
            window.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                              context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!)
            pump()
        }
        space(.keyDown)
        XCTAssertTrue(session.peeking)
        space(.keyUp)
        XCTAssertFalse(session.peeking)
        session.enlarge(1, shot: 1)
        XCTAssertEqual(session.peeking, false)
        session.peeking = true
        XCTAssertEqual(session.shownShot?.image.path, "/tmp/today.png", "no shot of that name: today's first")
        session.browse(1)
        XCTAssertFalse(session.peeking, "moving turns it off")
        session.enlarge(3)
        pump()
        XCTAssertNil(anchor("Flick to Today: click, or hold Space", in: host), "nothing to flick to from today itself")
    }

    func testClickingAnImageEnlargesItAndAgainGoesBack() {
        let (session, host, window) = make()
        defer { window.close() }
        session.showAll()
        pump()
        click("C: click to enlarge", in: host, window)
        XCTAssertEqual(session.mode, .single)
        XCTAssertEqual(at(session), ["C", "0"])
        click("C: click to see them all", in: host, window)
        XCTAssertEqual(session.mode, .all)
    }

    func testASentReviewHasNothingToPress() async {
        var answered = review()
        answered.status = "answered"
        answered.response = ReviewDraft(pickedIds: ["A", "C"], notes: ["C": "Fainter"], reply: "Both")
        let (session, host, window) = make(answered)
        defer { window.close() }
        XCTAssertEqual(session.mode, .all, "nothing left to step towards")
        XCTAssertNil(anchor("Pick B", in: host))
        XCTAssertNil(anchor("Unpick C", in: host))
        XCTAssertNil(anchor("None of them will do", in: host))
        XCTAssertEqual(noteBoxes(in: host), 0, "the reply is shown as text, not a box that can't be typed in")
    }

    private func review() -> DesignReview {
        func image(_ name: String) -> ImageRef { ImageRef(path: "/tmp/\(name).png", mediaType: "image/png") }
        var options = ["A", "B", "C"].map {
            ReviewOption(id: $0, title: "Option \($0)", note: "Why \($0)", image: image($0))
        }
        // A has three shots and runs live; B has two, untitled.
        options[0].shots = [ReviewShot(title: "Overview", image: image("A")), ReviewShot(title: "Mid-drag", image: image("A2")), ReviewShot(title: "Detail", image: image("A3"))]
        options[0].url = "http://localhost:5190/a"
        options[1].shots = [ReviewShot(image: image("B")), ReviewShot(image: image("B2"))]
        // A reference: to look at, not to pick.
        options.append(ReviewOption(id: "Today", title: "Today", reference: true, image: image("today"),
                                    shots: [ReviewShot(title: "Overview", image: image("today")), ReviewShot(title: "Mid-drag", image: image("today2"))]))
        return DesignReview(id: "review", title: "Rail", options: options)
    }

    /// The option on show and its shot.
    private func at(_ session: ReviewSession) -> [String] {
        [session.focusedOption?.id ?? "", String(session.shot)]
    }

    private func make(_ given: DesignReview? = nil, native: Bool = false) -> (ReviewSession, NSView, NSWindow) {
        let review = given ?? review()
        let service = ReviewService(load: { review }, save: { _, _ in review }, respond: { _, _ in review }, cancel: { _ in review })
        let session = ReviewSession(threadId: "thread", review: review, service: service,
                                    defaults: UserDefaults(suiteName: "ReviewWindowTests.\(UUID().uuidString)")!, autosave: false)
        let host = NSHostingView(rootView: ReviewWindow(session: session, back: {}, close: {}))
        // The review's own window class where its keys matter.
        let frame = NSRect(x: 0, y: 0, width: 1100, height: 760)
        let window: NSWindow
        if native {
            let reviewWindow = ReviewNativeWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            reviewWindow.reviewSession = session
            window = reviewWindow
        } else {
            window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        }
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
