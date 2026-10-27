import AppKit
import XCTest
@testable import Threadbare

/// The main window opens where it was left: its frame is saved as it moves
/// and put back on the next window.
@MainActor
final class MainWindowFrameTests: XCTestCase {
    private let frameName = "test-main-\(UUID().uuidString)"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(frameName)")
        UserDefaults.standard.removeObject(forKey: MainWindowFrame.key(frameName))
        super.tearDown()
    }

    private func window(at frame: NSRect) -> NSWindow {
        let w = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        return w
    }

    func testAMovedWindowOpensThereNextTime() throws {
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let first = window(at: NSRect(x: screen.minX + 40, y: screen.minY + 40, width: 800, height: 500))
        first.orderBack(nil)
        defer { first.close() }
        MainWindowFrame.track(first, name: frameName)
        let moved = NSRect(x: screen.minX + 120, y: screen.minY + 90, width: 900, height: 560)
        first.setFrame(moved, display: false)
        XCTAssertNotNil(UserDefaults.standard.string(forKey: MainWindowFrame.key(frameName)), "saved as it moved")

        // A new launch's window, placed somewhere else by default.
        // On screen, as the app's window is by the time it's tracked.
        let second = window(at: NSRect(x: screen.minX, y: screen.minY, width: 700, height: 400))
        second.orderBack(nil)
        defer { second.close() }
        MainWindowFrame.track(second, name: frameName)
        XCTAssertEqual(second.frame, moved)
    }

    func testNothingSavedLeavesTheWindowAlone() throws {
        let w = window(at: NSRect(x: 10, y: 10, width: 700, height: 400))
        let frame = w.frame
        MainWindowFrame.track(w, name: frameName)
        XCTAssertEqual(w.frame, frame)
    }

    func testAFrameOnADisplayThatsGoneIsIgnored() {
        let laptop = NSRect(x: 0, y: 0, width: 1512, height: 950)
        let external = NSRect(x: -2560, y: -269, width: 2560, height: 1415)
        XCTAssertTrue(MainWindowFrame.onScreen(NSRect(x: -2000, y: 100, width: 1200, height: 800), screens: [laptop, external]))
        XCTAssertFalse(MainWindowFrame.onScreen(NSRect(x: -2000, y: 100, width: 1200, height: 800), screens: [laptop]), "external unplugged")
        XCTAssertFalse(MainWindowFrame.onScreen(NSRect(x: 1400, y: 100, width: 1200, height: 800), screens: [laptop]), "mostly off the edge")
    }
}
