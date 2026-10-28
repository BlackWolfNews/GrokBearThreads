import AppKit
import XCTest
@testable import Threadbear

/// `.onRightClick` (the updates icon's popover) takes a right-click or a
/// Control-click on its own view, and leaves every other click alone.
@MainActor
final class RightClickTests: XCTestCase {
    private var window: NSWindow!
    private var view: RightClickView!

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        view = RightClickView(frame: NSRect(x: 10, y: 20, width: 32, height: 32))
        window.contentView?.addSubview(view)
    }

    private func click(_ type: NSEvent.EventType, at point: NSPoint, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func testARightClickOnTheViewIsTaken() {
        XCTAssertTrue(view.takes(click(.rightMouseDown, at: NSPoint(x: 26, y: 36)), in: window))
    }

    func testAControlClickCountsAsARightClick() {
        XCTAssertTrue(view.takes(click(.leftMouseDown, at: NSPoint(x: 26, y: 36), .control), in: window))
    }

    func testAPlainClickIsLeftForTheButton() {
        XCTAssertFalse(view.takes(click(.leftMouseDown, at: NSPoint(x: 26, y: 36)), in: window))
        XCTAssertFalse(view.takes(click(.leftMouseDown, at: NSPoint(x: 26, y: 36), .command), in: window))
    }

    func testARightClickElsewhereIsLeftAlone() {
        XCTAssertFalse(view.takes(click(.rightMouseDown, at: NSPoint(x: 100, y: 100)), in: window), "outside the view")
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        XCTAssertFalse(view.takes(click(.rightMouseDown, at: NSPoint(x: 26, y: 36)), in: other), "the same spot in another window")
        view.isHidden = true
        XCTAssertFalse(view.takes(click(.rightMouseDown, at: NSPoint(x: 26, y: 36)), in: window), "hidden")
    }

    func testItsNeverHitSoClicksReachTheViewInFront() {
        XCTAssertNil(view.hitTest(NSPoint(x: 26, y: 36)))
    }
}
