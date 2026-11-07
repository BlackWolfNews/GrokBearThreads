import AppKit
import XCTest
@testable import Threadbear
@testable import ThreadbearCore

/// Editing a text file in the pane (TextFileController): line numbers
/// while editing, ⌘S writes straight away rather than after the pause, and
/// a save never writes over a change on disk it hasn't heard about yet.
@MainActor
final class TextFileEditingTests: XCTestCase {
    private var file: URL!

    override func setUp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("text-editing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("hello.ts")
        try "let a = 1;\n".write(to: file, atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    private func onDisk() -> String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }

    private func editor(editing: Bool) -> (TextFileController, NSWindow) {
        let controller = TextFileController(url: file)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.scroll
        controller.start(editing: editing, dark: false)
        window.makeFirstResponder(controller.textView)
        return (controller, window)
    }

    /// Files open read only, as before; the pencil brings the numbers.
    func testLineNumbersOnlyWhileEditing() {
        let (controller, window) = editor(editing: false)
        defer { controller.stop(); window.close() }
        XCTAssertFalse(controller.textView.isEditable)
        XCTAssertFalse(controller.scroll.rulersVisible)
        controller.setEditing(true)
        XCTAssertTrue(controller.textView.isEditable)
        XCTAssertTrue(controller.scroll.rulersVisible)
        controller.setEditing(false)
        XCTAssertFalse(controller.scroll.rulersVisible)
    }

    /// Opened again while it was being edited: it takes typing straight away.
    func testReopenedWhileEditingTakesTyping() {
        let (controller, window) = editor(editing: true)
        defer { controller.stop(); window.close() }
        XCTAssertTrue(controller.textView.isEditable)
        XCTAssertTrue(controller.scroll.rulersVisible)
    }

    func testCommandSSavesStraightAway() throws {
        let (controller, window) = editor(editing: true)
        defer { controller.stop(); window.close() }
        controller.insertAtEnd("let b = 2;\n")
        XCTAssertEqual(onDisk(), "let a = 1;\n", "not yet: the pause hasn't passed")
        let commandS = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil, characters: "s",
                                                      charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
        XCTAssertTrue(window.performKeyEquivalent(with: commandS))
        XCTAssertEqual(onDisk(), "let a = 1;\nlet b = 2;\n")
    }

    /// ⌘S over a file that's only being read is left for the menus.
    func testCommandSWhileReadingDoesNothing() throws {
        let (controller, window) = editor(editing: false)
        defer { controller.stop(); window.close() }
        let commandS = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil, characters: "s",
                                                      charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
        XCTAssertFalse(controller.textView.performKeyEquivalent(with: commandS))
    }

    /// An agent rewrites the file just before a save: it isn't written
    /// over, and the conflict bar asks. Keep mine then writes it.
    func testAnOutsideChangeIsntWrittenOver() throws {
        let (controller, window) = editor(editing: true)
        defer { controller.stop(); window.close() }
        controller.insertAtEnd("// mine\n")
        try "let a = 99;\n".write(to: file, atomically: false, encoding: .utf8)
        controller.saveNow()
        XCTAssertEqual(onDisk(), "let a = 99;\n")
        XCTAssertEqual(controller.conflict, "let a = 99;\n", "the bar asks")
        controller.keepMine()
        XCTAssertNil(controller.conflict)
        XCTAssertEqual(onDisk(), "let a = 1;\n// mine\n")
    }

    /// The save as you type still lands by itself.
    func testTypingIsStillSavedAfterThePause() {
        let (controller, window) = editor(editing: true)
        defer { controller.stop(); window.close() }
        controller.insertAtEnd("let c = 3;\n")
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertEqual(onDisk(), "let a = 1;\nlet c = 3;\n")
    }
}
