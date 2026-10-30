import AppKit
import SwiftUI
import XCTest
@testable import Threadbear
import ThreadbearCore

@MainActor
final class ReviewStripTests: XCTestCase {
    /// In 2-up and single, a click on a thumbnail in the strip did nothing
    /// (Mike, 29 Oct). The first fix only checked AppKit's hitTest skipped
    /// the thumbnail, and the click still never reached its Button (Mike,
    /// 30 Oct), so this clicks each one with real mouse events and checks
    /// the image changes.
    func testClickingAThumbnailInTheStripShowsIt() {
        for mode in [ReviewMode.single, .pair] {
            let (session, host, window) = make(mode)
            defer { window.close() }
            for (index, id) in [(2, "C"), (3, "D"), (1, "B")] {
                guard let point = thumbnail(id, in: host) else {
                    return XCTFail("no thumbnail for \(id) in \(mode)")
                }
                click(point, in: window)
                XCTAssertTrue(session.visibleIndices.contains(index), "clicking \(id)'s thumbnail in \(mode) shows it")
                if mode == .single { XCTAssertEqual(session.left, index) }
                if mode == .pair { XCTAssertEqual(session.right, index, "in 2-up it goes on the right") }
            }
        }
    }

    private func make(_ mode: ReviewMode) -> (ReviewSession, NSView, NSWindow) {
        let options = ["A", "B", "C", "D"].map {
            ReviewOption(id: $0, title: $0, image: ImageRef(path: "/tmp/\($0).png", mediaType: "image/png"))
        }
        let review = DesignReview(id: "review", title: "Strip", options: options)
        let service = ReviewService(load: { review }, save: { _, _ in review }, respond: { _, _ in review }, cancel: { _ in review })
        let session = ReviewSession(threadId: "thread", review: review, service: service,
                                    defaults: UserDefaults(suiteName: "ReviewStripTests.\(UUID().uuidString)")!, autosave: false)
        session.mode = mode
        let host = NSHostingView(rootView: ReviewWindow(session: session, inPanel: true, back: {}, close: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // SwiftUI's Buttons ignore clicks in a window that was never
        // ordered in, so it's ordered in off screen, out of Mike's way.
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        window.makeKey()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return (session, host, window)
    }

    /// The middle of an option's thumbnail in the strip, in window
    /// coordinates. Its button's tip anchor sits behind it, the same size.
    private func thumbnail(_ id: String, in host: NSView) -> NSPoint? {
        func anchors(_ view: NSView) -> [TipAnchorView] {
            view.subviews.flatMap { ($0 as? TipAnchorView).map { [$0] } ?? anchors($0) }
        }
        guard let anchor = anchors(host).first(where: { $0.text == id && $0.bounds.height < 60 }) else { return nil }
        return anchor.convert(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: nil)
    }

    /// A press and release, sent through the window as a real click is.
    private func click(_ point: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                           pressure: type == .leftMouseDown ? 1 : 0)!
            window.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
}
