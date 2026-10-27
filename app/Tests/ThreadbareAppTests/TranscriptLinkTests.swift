import AppKit
import XCTest
@testable import Threadbare

@MainActor
final class TranscriptLinkTests: XCTestCase {
    private func link(_ markdown: String) throws -> URL {
        let text = MarkdownRenderer.render(markdown).string
        return try XCTUnwrap(text.attribute(.link, at: 0, effectiveRange: nil) as? URL)
    }

    func testAbsoluteHTMLAndOrdinaryFilesAreFileURLs() throws {
        let path = "/Users/m5-mike/dev/me/threadbare/docs/options-review-design/index.html"
        let html = try link("[Open both mockups and the recommendation](\(path))")
        XCTAssertTrue(html.isFileURL)
        XCTAssertEqual(html.path, path)
        let text = try link("[Notes](/tmp/notes.txt)")
        XCTAssertTrue(text.isFileURL)
        XCTAssertEqual(text.path, "/tmp/notes.txt")
    }

    func testSpacesAndPercentEscapesAreDecodedOnce() throws {
        for destination in ["/tmp/Review Files/index.html", "/tmp/Review%20Files/index.html"] {
            let url = try link("[Review](<\(destination)>)")
            XCTAssertTrue(url.isFileURL)
            XCTAssertEqual(url.path, "/tmp/Review Files/index.html")
        }
        XCTAssertEqual(try link("[Review](/tmp/100%25%20done.html)").path, "/tmp/100% done.html")
        let escaped = try link("[Notes](/tmp/literal%2520name.txt)")
        XCTAssertEqual(escaped.path, "/tmp/literal%20name.txt")
    }

    func testHTMLFragmentAndExistingURLsArePreserved() throws {
        let html = try link("[Section](/tmp/review.html#recommendation)")
        XCTAssertTrue(html.isFileURL)
        XCTAssertEqual(html.path, "/tmp/review.html")
        XCTAssertEqual(html.fragment, "recommendation")
        for destination in ["https://example.com/a%20b?q=hello#section", "file:///tmp/Review%20Files/index.html"] {
            XCTAssertEqual(try link("[Open](\(destination))"), URL(string: destination))
        }
    }

    func testLocalImageFallbackIsAlsoAFileLink() throws {
        let url = try link("![Preview](/tmp/preview.png)")
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(url.path, "/tmp/preview.png")
    }

    func testColonSuffixIsNotTreatedAsAnEditorLineNumber() throws {
        // There is no editor/line dispatch in the transcript. Colons can
        // belong to a real filename, so the URL conversion preserves them.
        let url = try link("[Source](/tmp/source.swift:12)")
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(url.path, "/tmp/source.swift:12")
    }

    func testTextViewOpensLocalFileThroughWorkspace() throws {
        let text = MarkdownRenderer.render("[Review](</tmp/Review Files/index.html>)").string
        let view = TranscriptTextView()
        view.show(text, width: 500)
        var opened: URL?
        view.openFileLink = { opened = $0; return true }
        let value = try XCTUnwrap(view.textStorage?.attribute(.link, at: 0, effectiveRange: nil))
        view.clicked(onLink: value, at: 0)
        let clicked = try XCTUnwrap(opened)
        XCTAssertTrue(clicked.isFileURL)
        XCTAssertEqual(clicked.path, "/tmp/Review Files/index.html")
    }

    func testHTTPSKeepsAppKitClickHandling() throws {
        let view = TranscriptTextView()
        let delegate = LinkDelegate()
        view.delegate = delegate
        view.openFileLink = { _ in XCTFail("HTTPS must keep AppKit's normal handling"); return false }
        let url = try XCTUnwrap(URL(string: "https://example.com/path#section"))
        view.clicked(onLink: url, at: 0)
        XCTAssertEqual(delegate.clicked, url)
    }
}

private final class LinkDelegate: NSObject, NSTextViewDelegate {
    var clicked: URL?

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        clicked = link as? URL
        return true // Observe AppKit's click without launching another app in a unit test.
    }
}
