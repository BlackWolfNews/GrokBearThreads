import AppKit
import XCTest
@testable import Threadbear
@testable import ThreadbearCore

/// ```slack, ```email and ```draft blocks in replies: a box with a header
/// (DraftBlockCell) and every line of the draft kept as its own line.
@MainActor
final class DraftBlockRenderTests: XCTestCase {
    private func header(_ text: NSAttributedString) -> (DraftBlockCell, NSRange)? {
        var found: (DraftBlockCell, NSRange)?
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, stop in
            if let cell = (value as? NSTextAttachment)?.attachmentCell as? DraftBlockCell { found = (cell, range); stop.pointee = true }
        }
        return found
    }

    func testASlackDraftKeepsItsLinesAndDrawsItsFormatting() throws {
        let text = MarkdownRenderer.render("Here's the post:\n\n```slack\n*Threadbear, 6 Nov*\n• one <https://x.dev|link>\n• two\n```\n\nPost it?").string
        let (cell, range) = try XCTUnwrap(header(text))
        XCTAssertEqual(cell.draft.kind, .slack)
        let string = text.string as NSString
        // One paragraph per line: the bullets don't run together.
        XCTAssertTrue(text.string.contains("Threadbear, 6 Nov\n• one link\n• two\n"), text.string)
        let bold = string.range(of: "Threadbear, 6 Nov")
        let font = try XCTUnwrap(text.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        let link = string.range(of: "link")
        XCTAssertEqual((text.attribute(.link, at: link.location, effectiveRange: nil) as? URL)?.absoluteString, "https://x.dev")
        // The box runs from the header to the last line, and no further.
        var box = NSRange()
        XCTAssertNotNil(text.attribute(.tbBlockBackground, at: range.location, longestEffectiveRange: &box, in: NSRange(location: 0, length: text.length)))
        XCTAssertTrue(NSLocationInRange(string.range(of: "• two").location, box))
        XCTAssertFalse(NSLocationInRange(string.range(of: "Post it?").location, box))
        XCTAssertEqual(text.attribute(.tbCopyText, at: range.location, effectiveRange: nil) as? String, "")
    }

    func testAnEmailDraftLinksBareAddressesAndKeepsBlankLines() throws {
        let text = MarkdownRenderer.render("```email\nHi Sam,\n\nSee https://x.dev/a for *this*.\n\nMike\n```").string
        XCTAssertNotNil(header(text))
        XCTAssertTrue(text.string.contains("Hi Sam,\n\nSee https://x.dev/a for *this*.\n\nMike"), text.string)
        let at = (text.string as NSString).range(of: "https://x.dev/a").location
        XCTAssertEqual((text.attribute(.link, at: at, effectiveRange: nil) as? URL)?.absoluteString, "https://x.dev/a")
    }

    func testAFenceStillStreamingInStaysCode() {
        XCTAssertNil(header(MarkdownRenderer.render("```slack\n• one\n• tw").string))
        XCTAssertNil(header(MarkdownRenderer.render("```text\n• one\n```").string))
        // Cross-lab review, 6 Nov: a closing line has to match the opening one.
        XCTAssertNil(header(MarkdownRenderer.render("```slack\nhello\n~~~").string))
        XCTAssertNil(header(MarkdownRenderer.render("````slack\nhello\n```").string))
        XCTAssertNotNil(header(MarkdownRenderer.render("````slack\nhello\n`````").string))
        // Code that only looks like a closing fence.
        XCTAssertNil(header(MarkdownRenderer.render("```slack\nhello\n> ```").string))
    }

    func testAQuotedOrCRLFDraftIsStillADraft() {
        XCTAssertNotNil(header(MarkdownRenderer.render("> ```slack\n> hello\n> ```").string))
        XCTAssertNotNil(header(MarkdownRenderer.render("Here:\r\n\r\n```slack\r\nhello\r\n```\r\n").string))
        XCTAssertNotNil(header(MarkdownRenderer.render("- ```slack\n  hello\n  ```").string))
        XCTAssertNotNil(header(MarkdownRenderer.render("```slack\none\u{2028}two\n```").string))
        XCTAssertNotNil(header(MarkdownRenderer.render("> - ```slack\n>   héllo\n>   ```").string))
        XCTAssertNotNil(header(MarkdownRenderer.render("  ```slack\n  hello\n```").string))
        XCTAssertNotNil(header(MarkdownRenderer.render("1. ```slack\n   hello\n   ```").string))
        XCTAssertNotNil(header(MarkdownRenderer.render(">```slack\n>hello\n>```").string))
        XCTAssertNotNil(header(MarkdownRenderer.render("- parent\n  - child\n\n    ```slack\n    hello\n    ```").string))
    }

    func testCopyPutsPlainTextAndHTMLOnTheClipboardAndSaysCopied() throws {
        let cell = DraftBlockCell(draft: DraftBlock(kind: .slack, source: "*Hi* <https://x.dev|there> \(UUID())"))
        let board = NSPasteboard(name: NSPasteboard.Name("DraftBlockRenderTests-\(UUID())"))
        XCTAssertFalse(cell.wasJustCopied())
        cell.copy(to: board)
        XCTAssertTrue(cell.wasJustCopied())
        XCTAssertFalse(cell.wasJustCopied(now: Date().addingTimeInterval(DraftBlockCell.copiedFor + 0.1)))
        XCTAssertTrue(try XCTUnwrap(board.string(forType: .string)).hasPrefix("*Hi* there (https://x.dev) "))
        XCTAssertTrue(try XCTUnwrap(board.string(forType: .html)).contains("<b>Hi</b> <a href=\"https://x.dev\">there</a>"))
        board.releaseGlobally()

        let frame = NSRect(x: 0, y: 0, width: 500, height: DraftBlockCell.height)
        let button = cell.button(in: frame)
        XCTAssertTrue(cell.isButton(at: NSPoint(x: button.midX, y: button.midY), in: frame))
        XCTAssertFalse(cell.isButton(at: NSPoint(x: 10, y: frame.midY), in: frame))
    }
}
