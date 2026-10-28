import AppKit
import BearDock
import SwiftUI
import XCTest
@testable import Threadbear

/// The transcript has one scroll view. Half dragging a panel drew a second
/// copy of it in the dock's ghost, which took the scroll view and left the
/// panel blank when the ghost went (Mike, 28 Oct).
@MainActor
final class TranscriptHostTests: XCTestCase {
    private func window(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }

    func testTheDragGhostLeavesTheTranscriptInItsPanel() {
        let controller = TranscriptController()
        let panel = NSHostingView(rootView: TranscriptView(session: nil, controller: controller))
        let main = window(panel)
        panel.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.scrollView.window === main)

        let ghost = NSHostingView(rootView: TranscriptView(session: nil, controller: controller).environment(\.isDockGhost, true))
        let floating = window(ghost)
        ghost.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.scrollView.window === main, "the ghost took the transcript")

        floating.contentView = nil
        XCTAssertTrue(controller.scrollView.window === main)
    }

    func testAPanelTakesBackATranscriptLeftOffScreen() {
        let controller = TranscriptController()
        let host = TranscriptHost(controller: controller, ghost: false)
        let main = window(host)
        // Whatever took it then went away.
        let elsewhere = NSView()
        elsewhere.addSubview(controller.scrollView)
        XCTAssertNil(controller.scrollView.window)

        host.claim()
        XCTAssertTrue(controller.scrollView.window === main)
        XCTAssertEqual(controller.scrollView.frame, host.bounds)
    }
}
