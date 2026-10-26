import AppKit
import XCTest
@testable import Threadbare
@testable import ThreadbareCore

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
        for text in [Self.reply, Self.reply + "\n\n- One more\n- And another", "```\ncode first\n```\n\nThen text."] {
            let rendered = MarkdownRenderer.render(text)
            let measured = TextMeasurer().measure(rendered.string, width: 700)
            let view = TranscriptTextView()
            view.show(rendered.string, width: 700)
            XCTAssertEqual(view.usedHeight, measured.height, "for \(text.prefix(20))")
        }
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
}

private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}
