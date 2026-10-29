import AppKit
import XCTest
@testable import Threadbear

/// What a drag out of the app puts on the pasteboard (FileDrag): a file
/// as the file, so X's upload box in Chrome takes the clip itself.
@MainActor
final class FileDragTests: XCTestCase {
    private func dragged(_ url: URL) throws -> NSPasteboard {
        let writer = try XCTUnwrap(FileDrag.writer(for: url))
        let board = NSPasteboard(name: .init("FileDragTests-\(UUID().uuidString)"))
        board.clearContents()
        XCTAssertTrue(board.writeObjects([writer]))
        addTeardownBlock { board.releaseGlobally() }
        return board
    }

    func testAFileGoesAsItsFileURL() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let clip = folder.appendingPathComponent("plugboard B.mp4")
        try Data([0]).write(to: clip)

        let board = try dragged(clip)
        let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(files?.map(\.path), [clip.path])
    }

    /// A page's ?query is for its own script, not part of the file.
    func testAFileLinksQueryIsLeftOff() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let page = folder.appendingPathComponent("grow.html")
        try Data("<p>hi</p>".utf8).write(to: page)

        let board = try dragged(try XCTUnwrap(URL(string: page.absoluteString + "?clean&s=45")))
        let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(files?.map(\.path), [page.path])
        XCTAssertNil(files?.first?.query)
    }

    func testAMissingFileHasNothingToDrag() {
        XCTAssertNil(FileDrag.writer(for: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).mp4")))
    }

    func testAWebLinkGoesAsItsAddress() throws {
        let board = try dragged(try XCTUnwrap(URL(string: "https://github.com/mikecann/plugboard")))
        XCTAssertEqual(board.string(forType: .URL), "https://github.com/mikecann/plugboard")
        XCTAssertEqual(board.string(forType: .string), "https://github.com/mikecann/plugboard")
    }

    // MARK: Press or drag

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// The press as the queue hands it back: posting moves an event's
    /// location (the window isn't on screen), so the press goes through
    /// the same trip as the moves after it.
    private func press(at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        NSApp.postEvent(mouse(.leftMouseDown, at: point, in: window), atStart: false)
        return try XCTUnwrap(window.nextEvent(matching: [.leftMouseDown], until: Date(), inMode: .eventTracking, dequeue: true))
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        return window
    }

    /// Let go without moving far: a click, with the mouse-up left for the
    /// view's own mouseDown, so a link still opens.
    func testAPressLetGoIsAClickAndKeepsItsMouseUp() throws {
        let window = window()
        let down = try press(at: NSPoint(x: 50, y: 50), in: window)
        NSApp.postEvent(mouse(.leftMouseDragged, at: NSPoint(x: 51, y: 51), in: window), atStart: false)
        NSApp.postEvent(mouse(.leftMouseUp, at: NSPoint(x: 51, y: 51), in: window), atStart: false)
        XCTAssertFalse(FileDrag.isDrag(from: down))
        let left = window.nextEvent(matching: [.leftMouseUp], until: Date(), inMode: .eventTracking, dequeue: true)
        XCTAssertEqual(left?.type, .leftMouseUp)
    }

    func testMovingFarEnoughIsADrag() throws {
        let window = window()
        let down = try press(at: NSPoint(x: 50, y: 50), in: window)
        NSApp.postEvent(mouse(.leftMouseDragged, at: NSPoint(x: 51, y: 50), in: window), atStart: false)
        NSApp.postEvent(mouse(.leftMouseDragged, at: NSPoint(x: 58, y: 50), in: window), atStart: false)
        XCTAssertTrue(FileDrag.isDrag(from: down))
        // Clear the queue for the next test.
        while NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) != nil {}
    }
}
