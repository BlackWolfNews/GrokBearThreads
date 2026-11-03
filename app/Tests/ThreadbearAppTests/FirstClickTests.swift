import AppKit
import WebKit
import XCTest
@testable import Threadbear

/// Clicks count while Threadbear isn't the app in front (FirstClick.swift):
/// macOS asks the view under the pointer, so every kind of view a click can
/// land on has to say yes. Walking the views a row is made of catches a new
/// plain `NSButton()` or text view that would quietly swallow it again.
@MainActor
final class FirstClickTests: XCTestCase {
    /// Every view in a tree a press could land on. A scroll view's own
    /// parts pass a press to what they show, or are its scroller (a control);
    /// tip anchors and right-click catchers are never hit (hitTest is nil).
    private func clickable(in view: NSView) -> [NSView] {
        let passes = view is NSScrollView || view is NSClipView || view is TipAnchorView || view is RightClickView
        let mine = passes ? [] : [view]
        return mine + view.subviews.flatMap(clickable(in:))
    }

    private func assertAllTakeTheFirstClick(_ root: NSView, file: StaticString = #filePath, line: UInt = #line) {
        let views = clickable(in: root)
        XCTAssertFalse(views.isEmpty, "nothing clickable found in \(type(of: root))", file: file, line: line)
        for view in views {
            XCTAssertTrue(view.acceptsFirstMouse(for: nil), "\(type(of: view)) swallows the click that brings the window forward", file: file, line: line)
        }
    }

    func testTranscriptRowsTakeTheFirstClick() {
        assertAllTakeTheFirstClick(TextRowCell())
        assertAllTakeTheFirstClick(HeaderRowCell())
        assertAllTakeTheFirstClick(GroupRowCell())
        assertAllTakeTheFirstClick(ChangesRowCell())
    }

    func testAnAskAnswerBoxTakesTheFirstClick() {
        assertAllTakeTheFirstClick(AskAnswerBox())
    }

    func testTheTextViewsTakeTheFirstClick() {
        XCTAssertTrue(ComposerTextView().acceptsFirstMouse(for: nil))
        XCTAssertTrue(FileTextView().acceptsFirstMouse(for: nil))
        XCTAssertTrue(FilePreviewView().acceptsFirstMouse(for: nil))
    }

    func testAPanelsWebViewTakesTheFirstClick() {
        XCTAssertTrue(FirstClickWebView().acceptsFirstMouse(for: nil))
        // The panels' views come from makeView, which has to use it.
        let source = try? String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Threadbear/Views/PanelsView.swift"), encoding: .utf8)
        XCTAssertEqual(source?.contains("= WKWebView("), false)
    }
}
