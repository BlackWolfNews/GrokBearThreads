import AppKit
import XCTest
@testable import Threadbare
@testable import ThreadbareCore

/// The composer used to be built with no text storage, so typing did nothing.
final class ComposerTests: XCTestCase {
    func testComposerKeepsWhatIsTyped() {
        let composer = ComposerTextView()
        XCTAssertNotNil(composer.textStorage)
        XCTAssertNotNil(composer.layoutManager)
        composer.string = "Hello there"
        XCTAssertEqual(composer.string, "Hello there")
        composer.insertText("!", replacementRange: NSRange(location: composer.string.utf16.count, length: 0))
        XCTAssertEqual(composer.string, "Hello there!")
    }
}

final class QuestionAnswerTests: XCTestCase {
    let colour = Question(question: "Which colour?", options: [QuestionOption(label: "Blue"), QuestionOption(label: "Green")])
    let size = Question(question: "Which size?", options: [QuestionOption(label: "S"), QuestionOption(label: "L")])

    func testTypedTextReplacesASingleChoice() {
        let request = QuestionRequest(approvalId: "q1", questions: [colour])
        let answers = QuestionRowCell.answers(for: request, chosen: [0: ["Green"]], typed: "Something purple")
        XCTAssertEqual(answers, ["Which colour?": "Something purple"])
    }

    func testTypedTextJoinsMultipleChoices() {
        var multi = colour
        multi.multiSelect = true
        let request = QuestionRequest(approvalId: "q1", questions: [multi])
        let answers = QuestionRowCell.answers(for: request, chosen: [0: ["Blue", "Green"]], typed: "and purple")
        XCTAssertEqual(answers, ["Which colour?": "Blue, Green, and purple"])
    }

    func testTypedTextOnlyAnswersTheLastQuestion() {
        let request = QuestionRequest(approvalId: "q1", questions: [colour, size])
        let answers = QuestionRowCell.answers(for: request, chosen: [:], typed: "Medium")
        XCTAssertEqual(answers, ["Which size?": "Medium"])
    }
}

/// Incremental measuring while a reply streams must give exactly the height
/// a full measure would, or rows would be clipped or padded.
final class StreamingMeasureTests: XCTestCase {
    func testIncrementalHeightsMatchFullMeasure() {
        let source = """
        Here is how the upload pipeline fits together, step by step.

        ## Reading the file

        The app reads the file in **64 KB chunks** so memory stays flat even for large videos. Each chunk is hashed as it goes.

        ```swift
        for try await chunk in reader.chunks(of: 65_536) {
            hasher.update(data: chunk)
        }
        ```

        - Retries use exponential backoff starting at 250 ms.
        - A failed chunk is re-sent on its own, not the whole file.

        Then the server confirms the checksum and `UploadStore` keeps the state.
        """
        let measurer = StreamingMeasurer()
        let full = TextMeasurer()
        var length = 0
        var steps = 0
        while length < source.count {
            length = min(source.count, length + 2 + steps % 11)
            steps += 1
            let rendered = MarkdownRenderer.render(String(source.prefix(length)))
            let incremental = measurer.measure(rowId: "a:m1", rendered, width: 640)
            let whole = full.measure(rendered.string, width: 640)
            XCTAssertEqual(incremental, whole, "at \(length) characters")
        }
        // A different width or row starts again from scratch.
        let rendered = MarkdownRenderer.render(source)
        XCTAssertEqual(measurer.measure(rowId: "a:m1", rendered, width: 400), full.measure(rendered.string, width: 400))
        XCTAssertEqual(measurer.measure(rowId: "a:m2", rendered, width: 400), full.measure(rendered.string, width: 400))
    }
}

final class RenderCacheTests: XCTestCase {
    func streaming(_ text: String, version: Int, streaming: Bool = true) -> TranscriptRow {
        TranscriptRow(id: "a:live", version: version, seq: 1, content: .assistant(TextItem(itemId: "live", text: text, isStreaming: streaming)))
    }

    /// Each streaming flush is a new version; only the newest is kept, so a
    /// long reply doesn't push every other render out of the cache.
    func testOnlyTheNewestVersionOfAStreamingRowIsKept() {
        let cache = RenderCache()
        let first = streaming("Hel", version: 1_000_001)
        let second = streaming("Hello", version: 1_000_002)
        _ = cache.render(first, expanded: false, width: 900)
        XCTAssertNotNil(cache.cached(first, expanded: false, width: 900))
        _ = cache.render(second, expanded: false, width: 900)
        XCTAssertNil(cache.cached(first, expanded: false, width: 900))
        XCTAssertNotNil(cache.cached(second, expanded: false, width: 900))
        let done = streaming("Hello!", version: 1_000_003, streaming: false)
        _ = cache.render(done, expanded: false, width: 900)
        XCTAssertNil(cache.cached(second, expanded: false, width: 900))
        XCTAssertNotNil(cache.cached(done, expanded: false, width: 900))
    }

    /// Renders depend on the reading column's width, so two table widths
    /// with the column at its widest share them (a legacy scroller showing
    /// or not, a sidebar drag).
    func testTableWidthsWithTheSameColumnShareRenders() {
        let cache = RenderCache()
        let row = TranscriptRow(id: "u:1", version: 2_000_001, seq: 1, content: .user(UserMessage(text: "Hi")))
        _ = cache.render(row, expanded: false, width: 982)
        XCTAssertNotNil(cache.cached(row, expanded: false, width: 965))
        XCTAssertNil(cache.cached(row, expanded: false, width: 600))
    }
}

/// Tall text draws through a slice around what's on screen instead of one
/// layer the height of the whole text.
@MainActor
final class SlicedTextTests: XCTestCase {
    func testTallTextOnlyDrawsAroundTheVisiblePart() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 800, height: 20_000))
        scroll.documentView = document
        let text = TranscriptTextView()
        document.addSubview(text)
        text.show(NSAttributedString(string: String(repeating: "line\n", count: 1000)), width: 700)
        text.place(NSRect(x: 10, y: 100, width: 700, height: 15_000))
        // At the top: a slice from the text's top, not 15,000 pt.
        XCTAssertLessThanOrEqual(text.frame.height, 600 * 2.5)
        XCTAssertEqual(text.bounds.minY, 0)
        XCTAssertEqual(text.fullFrame.height, 15_000)
        // Scrolled far down, the slice follows and text coordinates stay put.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 8_000))
        text.updateSlice()
        XCTAssertLessThanOrEqual(text.frame.height, 600 * 2.5)
        XCTAssertLessThanOrEqual(text.frame.minY, 8_000)
        XCTAssertGreaterThanOrEqual(text.frame.maxY, 8_600)
        XCTAssertEqual(text.frame.minY - text.fullFrame.minY, text.bounds.minY, "bounds origin is the slice's offset into the text")
        // Small moves inside the slice don't redraw it.
        let before = text.frame
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 8_050))
        text.updateSlice()
        XCTAssertEqual(text.frame, before)
        // Parked off screen it holds no drawing; placing it back restores it.
        text.park()
        XCTAssertEqual(text.frame.height, 0)
        text.updateSlice(force: true)
        XCTAssertGreaterThan(text.frame.height, 600)
    }

    func testShortTextIsNotSliced() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 800, height: 2_000))
        scroll.documentView = document
        let text = TranscriptTextView()
        document.addSubview(text)
        text.place(NSRect(x: 10, y: 100, width: 700, height: 500))
        XCTAssertEqual(text.frame, NSRect(x: 10, y: 100, width: 700, height: 500))
        XCTAssertEqual(text.bounds.origin, .zero)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// AppModel keeps a message that wasn't sent.
@MainActor
final class DraftTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // AppModel reads NSApp in places.
        _ = NSApplication.shared
    }

    func testSendingWhileDisconnectedKeepsTheDraft() {
        let app = AppModel()
        app.drafts["th1"] = Draft(text: "This message matters", images: [ImageRef(path: "/tmp/a.png", mediaType: "image/png")])
        app.send(threadId: "th1")
        XCTAssertEqual(app.drafts["th1"]?.text, "This message matters")
        XCTAssertEqual(app.drafts["th1"]?.images.count, 1)
        XCTAssertNotNil(app.errorMessage)
    }

    func testAFailedSendPutsTheDraftBack() async throws {
        let app = AppModel()
        let transport = RefusingTransport()
        let client = RPCClient(transport: transport)
        try await client.start()
        app.useClientForTesting(client)
        app.drafts["th1"] = Draft(text: "Keep me")
        app.send(threadId: "th1")
        XCTAssertNil(app.drafts["th1"], "the box empties straight away")
        for _ in 0..<200 where app.drafts["th1"] == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(app.drafts["th1"]?.text, "Keep me")
        XCTAssertEqual(app.errorMessage, "Busy")
    }

    func testNewThreadSettingsResetAfterCreatingOne() async throws {
        let app = AppModel()
        let transport = RefusingTransport()
        transport.createdThread = true
        let client = RPCClient(transport: transport)
        try await client.start()
        app.useClientForTesting(client)
        app.newThreadCwd = "/tmp/somewhere"
        app.newThreadModel = "haiku"
        app.newThreadAsk = true
        app.newThreadAccount = "claude-3"
        app.drafts["new"] = Draft(text: "Start something")
        app.send(threadId: nil)
        for _ in 0..<200 where app.selection == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(app.selection, "th_new")
        XCTAssertNil(app.newThreadCwd)
        XCTAssertNil(app.newThreadModel)
        XCTAssertFalse(app.newThreadAsk)
        XCTAssertEqual(app.newThreadAccount, "claude-3", "the account sticks")
    }
}

/// Answers threads.send with a busy error, and threads.create with a thread.
private final class RefusingTransport: RPCTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    var createdThread = false

    func open() async throws {}

    func send(_ text: String) async throws {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let id = object["id"] as? Int, let method = object["method"] as? String else { return }
        let reply: [String: Any]
        if method == "threads.create" && createdThread {
            reply = ["jsonrpc": "2.0", "id": id, "result": ["thread": ["id": "th_new", "title": "Start something"]]]
        } else {
            reply = ["jsonrpc": "2.0", "id": id, "error": ["code": -32020, "message": "Busy"]]
        }
        push(try JSONSerialization.data(withJSONObject: reply))
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !inbox.isEmpty {
                let data = inbox.removeFirst()
                lock.unlock()
                continuation.resume(returning: data)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func close() {}

    private func push(_ data: Data) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: data)
        } else {
            inbox.append(data)
            lock.unlock()
        }
    }
}
