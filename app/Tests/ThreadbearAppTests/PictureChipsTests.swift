import AppKit
import XCTest
@testable import Threadbear
@testable import ThreadbearCore

/// Pictures as chips among the composer's words (docs/protocol.md,
/// "Pictures in a message"; Mike, 1 Nov 2026).
@MainActor
final class PictureChipsTests: XCTestCase {
    let m = InlinePictures.markString
    let red = ImageRef(path: "/inbox/red.png", mediaType: "image/png")
    let blue = ImageRef(path: "/inbox/blue.png", mediaType: "image/png")

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    /// Kept for the test: a chip settles only in a box still in a window.
    private var windows: [NSWindow] = []

    private func composer() -> (NSWindow, ComposerTextView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let textView = ComposerTextField.makeTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 500, height: 200)
        window.contentView = textView
        windows.append(window)
        return (window, textView)
    }

    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    private func chips(_ textView: NSTextView) -> [PictureAttachment] {
        var found: [PictureAttachment] = []
        textView.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textView.textStorage?.length ?? 0)) { value, _, _ in
            if let chip = value as? PictureAttachment { found.append(chip) }
        }
        return found
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testADraftShowsItsMarksAsNumberedChipsAndReadsBack() {
        let (_, textView) = composer()
        let draft = Draft(text: "this \(m) like \(m)", images: [red, blue])
        textView.show(draft)
        XCTAssertEqual(textView.draftNow, draft)
        XCTAssertEqual(chips(textView).map(\.number), [1, 2])
        XCTAssertEqual(chips(textView).map(\.picture), [red, blue])
        // A zoom change restyles the words and keeps the chips.
        textView.applyTypeScale()
        XCTAssertEqual(textView.draftNow, draft)
        // A picture with no mark gets a chip at the end.
        textView.show(Draft(text: "look", images: [red]))
        XCTAssertEqual(textView.draftNow, Draft(text: "look \(m)", images: [red]))
    }

    /// U+FFFC pasted as text isn't a picture.
    func testAStrayMarkInTheWordsIsNoPicture() {
        let (_, textView) = composer()
        textView.replaceText("odd \u{FFFC} text")
        XCTAssertEqual(textView.draftNow, Draft(text: "odd  text"))
    }

    /// A paste goes in where the cursor is, with a space either side;
    /// it's dimmed and left out of the draft until the runner has it.
    func testPastedPicturesGoInWhereTheCursorIs() async throws {
        let (_, textView) = composer()
        textView.replaceText("compare this with that")
        var release: CheckedContinuation<Void, Never>?
        textView.pictures = .init(allowed: { true }, importOne: { url in
            await withCheckedContinuation { release = $0 }
            return ImageRef(path: "/inbox/" + url.lastPathComponent, mediaType: "image/png")
        })
        textView.setSelectedRange(NSRange(location: 12, length: 0))
        textView.insertPictures([URL(fileURLWithPath: "/tmp/shot.png")])
        XCTAssertEqual(textView.string, "compare this \u{FFFC} with that")
        XCTAssertEqual(textView.selectedRange().location, 14, "the cursor goes after the chip")
        XCTAssertEqual(textView.draftNow, Draft(text: "compare this  with that"), "not in the draft until it's in")
        XCTAssertNil(chips(textView).first?.picture)
        try await until { release != nil }
        release?.resume()
        try await until { textView.draftNow.images.count == 1 }
        XCTAssertEqual(textView.draftNow, Draft(text: "compare this \(m) with that",
                                                images: [ImageRef(path: "/inbox/shot.png", mediaType: "image/png")]))

        // Two at the end of the words: spaced, and numbered in order.
        textView.pictures = .init(allowed: { true }, importOne: { url in ImageRef(path: "/inbox/" + url.lastPathComponent, mediaType: "image/png") })
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertPictures([URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")])
        try await until { textView.draftNow.images.count == 3 }
        XCTAssertEqual(textView.draftNow.text, "compare this \(m) with that \(m) \(m) ")
        XCTAssertEqual(textView.draftNow.images.map(\.path), ["/inbox/shot.png", "/inbox/a.png", "/inbox/b.png"])
        XCTAssertEqual(chips(textView).map(\.number), [1, 2, 3])
    }

    /// One that couldn't be read goes again; none go where they aren't allowed.
    func testAPictureThatCouldNotBeReadGoes() async throws {
        let (_, textView) = composer()
        textView.replaceText("hi")
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.pictures = .init(allowed: { true }, importOne: { _ in nil })
        textView.insertPictures([URL(fileURLWithPath: "/tmp/broken.png")])
        try await until { !textView.string.contains("\u{FFFC}") }
        XCTAssertEqual(textView.string, "hi ")
        textView.pictures = .init(allowed: { false }, importOne: { _ in nil })
        textView.insertPictures([URL(fileURLWithPath: "/tmp/a.png")])
        XCTAssertEqual(textView.string, "hi ")
    }

    /// The strip's remove button takes the chip and a space beside it.
    func testRemovingAPictureTakesItsChipOut() {
        let (_, textView) = composer()
        textView.show(Draft(text: "this \(m) like \(m) ok", images: [red, blue]))
        XCTAssertTrue(textView.removePicture(at: 0))
        XCTAssertEqual(textView.draftNow, Draft(text: "this like \(m) ok", images: [blue]))
        XCTAssertEqual(chips(textView).map(\.number), [1])
        XCTAssertFalse(textView.removePicture(at: 1))
        XCTAssertEqual(Draft(text: "a \(m) b \(m)", images: [red, blue]).removingImage(at: 1), Draft(text: "a \(m) b", images: [red]))
    }

    /// Cut or copied chips paste back with their pictures; anywhere else
    /// they read as the markers the agent would get.
    func testCopiedChipsPasteBackWithTheirPictures() {
        let (_, from) = composer()
        from.show(Draft(text: "x \(m) y", images: [red]))
        from.setSelectedRange(NSRange(location: 0, length: (from.string as NSString).length))
        let board = NSPasteboard(name: NSPasteboard.Name("threadbear-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        XCTAssertTrue(from.writeSelection(to: board, types: from.writablePasteboardTypes))
        XCTAssertEqual(board.string(forType: .string), "x [Picture 1] y")

        let (_, to) = composer()
        to.pictures = .init(allowed: { true }, importOne: { _ in nil })
        to.replaceText("> ")
        to.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertTrue(to.readSelection(from: board))
        XCTAssertEqual(to.draftNow, Draft(text: "> x \(m) y", images: [red]))
    }

    /// His bubble draws the markers that place a picture as chips; others stay words.
    func testTheBubbleDrawsMarkersAsChips() {
        let text = RowRenderer.userText(UserMessage(text: "see [Picture 1] and [Picture 2], not [Picture 3]", images: [red, blue]))
        XCTAssertEqual(text.string, "see \u{FFFC} and \u{FFFC}, not [Picture 3]")
        var attachments = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value != nil { attachments += 1 }
        }
        XCTAssertEqual(attachments, 2)
        XCTAssertEqual(RowRenderer.userText(UserMessage(text: "[Picture 1]", images: [])).string, "[Picture 1]")
    }

    /// Editing a message puts its chips back where its markers were.
    func testEditingAMessagePutsItsChipsBack() {
        let app = AppModel()
        app.startEditing(threadId: "th1", seq: 4, text: "this [Picture 2] like [Picture 1]", images: [red, blue])
        XCTAssertEqual(app.drafts["th1"], Draft(text: "this \(m) like \(m)", images: [blue, red]))
    }
}
