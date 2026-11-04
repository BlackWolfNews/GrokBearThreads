import AppKit
import XCTest
@testable import Threadbear

/// Copying from a thread carries HTML, as Slack only keeps links from that.
@MainActor
final class TranscriptCopyTests: XCTestCase {
    private func copy(_ markdown: String) -> NSPasteboard {
        let view = TranscriptTextView()
        view.textStorage?.setAttributedString(MarkdownRenderer.render(markdown).string)
        view.setSelectedRange(NSRange(location: 0, length: view.textStorage?.length ?? 0))
        let board = NSPasteboard(name: NSPasteboard.Name("threadbear-test-\(UUID().uuidString)"))
        board.clearContents()
        XCTAssertTrue(view.writeSelection(to: board, types: view.writablePasteboardTypes))
        return board
    }

    func testACopiedLinkPastesAsALink() throws {
        let board = copy("> 7 shorts (I split a few): [Fireside Chat shorts](https://www.dropbox.com/scl/fo/abc?rlkey=x&dl=0)\n>\n> Let me know what you think!")
        let html = try XCTUnwrap(board.string(forType: .html))
        XCTAssertTrue(html.contains("<a href=\"https://www.dropbox.com/scl/fo/abc?rlkey=x&amp;dl=0\">Fireside Chat shorts</a>"), html)
        XCTAssertTrue(html.contains("(I split a few): "), html)
        // No theme colours or fonts, so it can't paste as white text.
        XCTAssertFalse(html.contains("color"), html)
        XCTAssertEqual(board.string(forType: .string)?.contains("Fireside Chat shorts"), true)
    }

    func testBoldCodeAndLocalLinks() throws {
        let html = try XCTUnwrap(copy("**Heads:** run `tb land` and see [notes](/tmp/notes.txt) <now>").string(forType: .html))
        XCTAssertTrue(html.contains("<b>Heads:</b>"), html)
        XCTAssertTrue(html.contains("<code>tb land</code>"), html)
        // A path on this Mac would be a dead link anywhere else.
        XCTAssertFalse(html.contains("file:"), html)
        XCTAssertTrue(html.contains("notes"), html)
    }
}
