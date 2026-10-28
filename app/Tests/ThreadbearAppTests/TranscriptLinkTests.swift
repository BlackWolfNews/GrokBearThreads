import AppKit
import XCTest
@testable import Threadbear

@MainActor
final class TranscriptLinkTests: XCTestCase {
    private func link(_ markdown: String) throws -> URL {
        let text = MarkdownRenderer.render(markdown).string
        return try XCTUnwrap(text.attribute(.link, at: 0, effectiveRange: nil) as? URL)
    }

    func testAbsoluteHTMLAndOrdinaryFilesAreFileURLs() throws {
        let path = "/Users/m5-mike/dev/me/threadbear/docs/options-review-design/index.html"
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

    func testBareURLsAreLinked() throws {
        let text = MarkdownRenderer.render("The preview is running again at http://localhost:5176, so refresh it.").string
        let start = (text.string as NSString).range(of: "http://").location
        var range = NSRange()
        let url = try XCTUnwrap(text.attribute(.link, at: start, effectiveRange: &range) as? URL)
        XCTAssertEqual(url, URL(string: "http://localhost:5176"))
        XCTAssertEqual((text.string as NSString).substring(with: range), "http://localhost:5176")
        let underscored = MarkdownRenderer.render("See https://example.com/a_b_c/page for more").string
        let at = (underscored.string as NSString).range(of: "https").location
        XCTAssertEqual(underscored.attribute(.link, at: at, effectiveRange: nil) as? URL, URL(string: "https://example.com/a_b_c/page"))
        let code = MarkdownRenderer.render("Open `https://example.com` now").string
        let codeAt = (code.string as NSString).range(of: "https").location
        XCTAssertEqual(code.attribute(.link, at: codeAt, effectiveRange: nil) as? URL, URL(string: "https://example.com"))
    }

    func testWordsAndCodeBlocksAreNotLinked() {
        let text = MarkdownRenderer.render("Read CLAUDE.md and example.com first").string
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in XCTAssertNil(value) }
        let block = MarkdownRenderer.render("```\ncurl https://example.com\n```").string
        block.enumerateAttribute(.link, in: NSRange(location: 0, length: block.length)) { value, _, _ in XCTAssertNil(value) }
    }

    func testMarkdownLinkKeepsItsDestination() throws {
        let url = try link("[https://shown.example](https://real.example)")
        XCTAssertEqual(url, URL(string: "https://real.example"))
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
