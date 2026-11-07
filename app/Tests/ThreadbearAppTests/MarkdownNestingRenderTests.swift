import AppKit
import XCTest
@testable import Threadbear

/// Deeply nested quotes and lists are drawn as words rather than run the
/// transcript's worker threads out of stack (MarkdownRenderer.maxNesting;
/// Daybreak, 7 Nov 2026).
final class MarkdownNestingRenderTests: XCTestCase {
    /// Renders on a thread with a worker's 512 KB stack, as
    /// `concurrentPerform` in RowRenderer does.
    private func renderOnSmallStack(_ text: String) -> NSAttributedString? {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: NSAttributedString?
        let thread = Thread {
            result = MarkdownRenderer.render(text).string
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        return done.wait(timeout: .now() + 20) == .success ? result : nil
    }

    func testDeepQuotesAndListsAreWords() throws {
        for text in [String(repeating: ">", count: 7_999) + "x",
                     String(repeating: "- ", count: 4_000) + "x",
                     (0..<1_000).map { String(repeating: "  ", count: $0) + "- x" }.joined(separator: "\n"),
                     // Emphasis nests one level for each pair: drawn on a
                     // thread with room for them, or as words past the most.
                     String(repeating: "*a ", count: 3_000) + String(repeating: "a* ", count: 3_000) + "x",
                     String(repeating: "*a ", count: 6_000) + String(repeating: "a* ", count: 6_000) + "x"] {
            let start = clock()
            let rendered = try XCTUnwrap(renderOnSmallStack(text))
            XCTAssertLessThan(Double(clock() - start) / Double(CLOCKS_PER_SEC), 2)
            XCTAssertTrue(rendered.string.hasSuffix("x"))
        }
    }

    func testOrdinaryNestingIsStillMarkdown() throws {
        let rendered = try XCTUnwrap(renderOnSmallStack("> a\n> - b\n>   - c"))
        XCTAssertFalse(rendered.string.contains(">"))
        XCTAssertTrue(rendered.string.contains("•"))
    }
}
