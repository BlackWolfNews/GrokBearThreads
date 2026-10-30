import AppKit
import XCTest
@testable import Threadbear
@testable import ThreadbearCore

/// The heights the renderer measures off screen must be the heights the
/// text views lay out, or the last line of a reply gets clipped.
@MainActor
final class TranscriptLayoutTests: XCTestCase {
    static let reply = """
    Here is how the upload pipeline fits together, step by step.

    ## Reading the file

    The app reads the file in **64 KB chunks** so memory stays flat even for large videos. Each chunk is hashed as it goes, which means the final checksum is ready the moment the last byte is read.

    ```swift
    for try await chunk in reader.chunks(of: 65_536) {
        hasher.update(data: chunk)
    }
    ```

    - Retries use exponential backoff starting at 250 ms.
    - A failed chunk is re-sent on its own, not the whole file.
    - Progress is reported per chunk.

    Then the server confirms the checksum and `UploadStore` keeps the state.
    """

    func testMeasuredHeightMatchesTheTextView() {
        for text in [Self.reply, Self.reply + "\n\n- One more\n- And another", "```\ncode first\n```\n\nThen text.", Self.table, Self.table + "\n\nAfter the table."] {
            let rendered = MarkdownRenderer.render(text)
            let measured = TextMeasurer().measure(rendered.string, width: 700)
            let view = TranscriptTextView()
            view.show(rendered.string, width: 700)
            XCTAssertEqual(view.usedHeight, measured.height, "for \(text.prefix(20))")
        }
    }

    static let table = """
    | Case | Before | After |
    | --- | --- | --- |
    | Quit at 60% of 1 GB | 1 GB re-sent | 400 MB re-sent, and a long note that has to wrap inside its own column rather than under the first one |
    | Network drop | Restart | |
    """

    /// Each cell is its own paragraph in a grid: a long cell wraps inside
    /// its column, and the empty last cell still has its place.
    func testATableCellWrapsInsideItsColumn() {
        let rendered = MarkdownRenderer.render(Self.table).string
        let storage = NSTextStorage(attributedString: rendered)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let note = (rendered.string as NSString).range(of: "400 MB")
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: note.location, length: rendered.length - note.location - 30), actualCharacterRange: nil)
        var lefts = Set<CGFloat>()
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, range, _ in
            if NSLocationInRange(note.location, range) || range.location > note.location { lefts.insert(used.minX) }
        }
        XCTAssertGreaterThan(lefts.min() ?? 0, 100, "the third column's lines all start in the third column")
        let blocks = (rendered.attribute(.paragraphStyle, at: rendered.length - 1, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks
        XCTAssertEqual((blocks?.first as? NSTextTableBlock)?.startingColumn, 2, "the empty last cell is still a cell")
    }

    /// A tall reply draws through a slice whose bounds start part way down
    /// the text. Its text must still start at the view's (0, 0), or the
    /// slice draws the wrong part of the reply.
    func testASlicedReplyKeepsItsTextOriginWhenTheTextIsReplaced() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 800, height: 20_000))
        scroll.documentView = document
        let text = TranscriptTextView()
        document.addSubview(text)
        let long = MarkdownRenderer.render(Array(repeating: Self.reply, count: 12).joined(separator: "\n\n")).string
        text.show(long, width: 700)
        let height = TextMeasurer().measure(long, width: 700).height
        text.place(NSRect(x: 10, y: 0, width: 700, height: height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: height - 600))
        text.updateSlice()
        XCTAssertGreaterThan(text.bounds.minY, 0, "drawn through a slice")
        text.replaceTail(from: 0, with: long)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        XCTAssertEqual(text.textContainerOrigin, .zero)
    }

    /// A failed tool's output stays ordinary text; only the lines that say
    /// what went wrong are red.
    func testFailedOutputMarksOnlyItsErrorLines() {
        let tool = ToolItem(itemId: "c1", call: ToolCall(itemId: "c1", name: "Bash", kind: .command, title: "Build", input: .object(["command": .string("make")])),
                            result: ToolResult(itemId: "c1", ok: false, text: "Building...\nstep 2\nerror: no identity\nfatal: stopped\ndone"))
        let body = RowRenderer.toolBody(tool)
        let string = body.string as NSString
        func colour(of text: String) -> NSColor? {
            body.attribute(.foregroundColor, at: string.range(of: text).location, effectiveRange: nil) as? NSColor
        }
        XCTAssertTrue(body.string.hasSuffix("Building...\nstep 2\nerror: no identity\nfatal: stopped\ndone"))
        XCTAssertEqual(colour(of: "Building"), Theme.quietText)
        XCTAssertEqual(colour(of: "step 2"), Theme.quietText)
        XCTAssertEqual(colour(of: "error: no"), Theme.failed)
        XCTAssertEqual(colour(of: "fatal:"), Theme.failed)
        XCTAssertEqual(colour(of: "done"), Theme.quietText)
    }

    /// Tool input fields put their values in one column after a tab.
    func testFieldsLineUpAfterATab() {
        let text = RowRenderer.fieldsText([.init(key: "owner", value: "mike"), .init(key: "pullNumber", value: "48")])
        XCTAssertEqual(text.string, "owner:\tmike\npullNumber:\t48")
        let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.tabStops.first?.location, style?.headIndent, "wrapped values hang under the value column")
    }

    /// An open card draws each ask the way the agent would have written it
    /// in its message: one paragraph, the why at the body size and colour,
    /// numbered when there are several, its buttons in under the text.
    func testAnAsksWhyIsMessageTextInOneParagraph() {
        let card = AsksCard(seq: 1, asks: [
            Ask(action: "Walk away with your phone", why: "I picked the cutoff, so tell me if it locked.", options: ["It locked", "It didn't"]),
            Ask(action: "Pair the 15 Pro Max when it's back", why: "Only paired phones count, `~/notes.md` says which."),
        ])
        let text = RowRenderer.asksText(card)
        let string = text.string as NSString
        XCTAssertTrue(text.string.contains("1.\tWalk away with your phone. I picked the cutoff, so tell me if it locked."), text.string)
        XCTAssertTrue(text.string.contains("2.\tPair the 15 Pro Max when it's back. Only paired phones count, ~/notes.md says which."), text.string)
        let why = string.range(of: "I picked").location
        XCTAssertEqual((text.attribute(.font, at: why, effectiveRange: nil) as? NSFont)?.pointSize, Theme.bodyFont.pointSize)
        XCTAssertEqual(text.attribute(.foregroundColor, at: why, effectiveRange: nil) as? NSColor, NSColor.labelColor)
        XCTAssertEqual((text.attribute(.font, at: why, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold), false)
        // Wrapped lines and the buttons sit in line with the text, past the number.
        let paragraph = text.attribute(.paragraphStyle, at: why, effectiveRange: nil) as? NSParagraphStyle
        // A button's spaces are no-break ones, so its title stays in one piece.
        let button = text.attribute(.paragraphStyle, at: string.range(of: "It\u{00A0}locked").location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertGreaterThan(paragraph?.headIndent ?? 0, 0)
        XCTAssertEqual(button?.firstLineHeadIndent, paragraph?.headIndent)
        // One ask: no number.
        let one = RowRenderer.asksText(AsksCard(seq: 2, asks: [Ask(action: "Merge #48?", why: "Checks pass.")])).string
        XCTAssertTrue(one.contains("\nMerge #48? Checks pass."), one)
        // No asks: the done card, Done with Archive on the same line.
        let done = RowRenderer.asksText(AsksCard(seq: 3, asks: []))
        XCTAssertTrue(done.string.contains("Done\t"), done.string)
        XCTAssertFalse(done.string.contains("\n"), "one line: \(done.string)")
        let archive = (done.string as NSString).range(of: "Archive")
        XCTAssertEqual(done.attribute(.tbAction, at: archive.location, effectiveRange: nil) as? String, "archive")
        // Suggested follow-ups: under "Or carry on", each a whole-row click
        // target that sends it; gone once it's closed.
        let next = RowRenderer.asksText(AsksCard(seq: 4, asks: [], next: ["Show Bruce pictures", "Start Bruce threads"]))
        let nextString = next.string as NSString
        let suggestion = nextString.range(of: "Show Bruce pictures")
        XCTAssertNotEqual(suggestion.location, NSNotFound, next.string)
        XCTAssertEqual(next.attribute(.tbAction, at: suggestion.location, effectiveRange: nil) as? String, "next:0")
        var row = NSRange()
        XCTAssertEqual(next.attribute(.tbRow, at: suggestion.location, effectiveRange: &row) as? String, "next:0")
        XCTAssertEqual(row, suggestion, "the row is just its own words")
        let heading = nextString.range(of: "Or carry on").location
        XCTAssertLessThan(nextString.range(of: "Archive").location, heading)
        XCTAssertLessThan(heading, suggestion.location)
        // A row, not a button, so a long one wraps, short of "Send ↑".
        XCTAssertNil(next.attribute(.tbButton, at: suggestion.location, effectiveRange: nil))
        let style = next.attribute(.paragraphStyle, at: suggestion.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertLessThan(style?.tailIndent ?? 0, 0)
        let start = nextString.range(of: "Start Bruce threads").location
        XCTAssertEqual(next.attribute(.tbRow, at: start, effectiveRange: nil) as? String, "next:1")
        XCTAssertFalse(done.string.contains("carry on"), done.string)
        let closed = RowRenderer.asksText(AsksCard(seq: 4, asks: [], isOpen: false, next: ["Show Bruce pictures"]))
        XCTAssertFalse(closed.string.contains("Bruce"), closed.string)
    }
}

private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}
