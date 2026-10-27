import AppKit
import XCTest
@testable import Threadbear
@testable import ThreadbearCore

@MainActor
final class ThreadChipsTests: XCTestCase {
    /// The renderer marks id-shaped words in text and inline code, not in
    /// code blocks or links; only the ones naming a thread become chips.
    func testMarksIdsAndResolvesOnlyRealThreads() {
        let text = """
        Busy: `85735a8f` and 1d827b8c, not `d1ecf9c` or [deadbeef](https://example.com).

        ```
        tb send 85735a8f
        ```
        """
        let string = MarkdownRenderer.render(text).string
        var marked: [String] = []
        string.enumerateAttribute(.tbThreadRef, in: NSRange(location: 0, length: string.length)) { value, _, _ in
            if let word = value as? String { marked.append(word) }
        }
        XCTAssertEqual(marked, ["85735a8f", "1d827b8c"])

        ThreadChips.update(["85735a8f-1111-4222-8333-444455556666"])
        defer { ThreadChips.update(AppModel.shared.threads.keys) }
        XCTAssertEqual(ThreadChips.chips(in: string).map(\.threadId), ["85735a8f-1111-4222-8333-444455556666"])
    }
}
