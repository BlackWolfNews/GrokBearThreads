import AppKit
import SwiftUI
import XCTest
@testable import Threadbear
import ThreadbearCore

@MainActor
final class ReviewStripTests: XCTestCase {
    /// SwiftUI's allowsHitTesting(false) doesn't stop an AppKit view taking
    /// a click, so in 2-up and single the strip's thumbnails took the click
    /// their Buttons were waiting for, and nothing happened (Mike, 29 Oct).
    func testAClickOnAThumbnailInTheStripReachesItsButton() {
        let options = ["A", "B", "C", "D"].map {
            ReviewOption(id: $0, title: $0, image: ImageRef(path: "/tmp/\($0).png", mediaType: "image/png"))
        }
        let review = DesignReview(id: "review", title: "Strip", options: options)
        let service = ReviewService(load: { review }, save: { _, _ in review }, respond: { _, _ in review }, cancel: { _ in review })
        let session = ReviewSession(threadId: "thread", review: review, service: service,
                                    defaults: UserDefaults(suiteName: "ReviewStripTests.\(UUID().uuidString)")!, autosave: false)
        session.mode = .single
        let host = NSHostingView(rootView: ReviewWindow(session: session, inPanel: true, back: {}, close: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let canvases = scrolls(in: host)
        let thumbnails = canvases.filter { $0.frame.height < 60 }
        XCTAssertEqual(thumbnails.count, 4, "one thumbnail in the strip for each option")
        for thumbnail in thumbnails {
            XCTAssertFalse(hit(thumbnail, in: host), "a thumbnail took the click meant for its button")
        }
        // The big canvas still scrolls and pans.
        let main = canvases.filter { $0.frame.height >= 60 }
        XCTAssertEqual(main.count, 1)
        XCTAssertTrue(main.allSatisfy { hit($0, in: host) })
    }

    private func scrolls(in view: NSView) -> [ReviewImageScroll] {
        view.subviews.flatMap { ($0 as? ReviewImageScroll).map { [$0] } ?? scrolls(in: $0) }
    }

    /// Whether a click in the middle of `view` lands on it, as AppKit
    /// routes a real one.
    private func hit(_ view: NSView, in host: NSView) -> Bool {
        let root = host.superview ?? host
        let centre = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: root)
        return root.hitTest(centre)?.isDescendant(of: view) == true
    }
}
