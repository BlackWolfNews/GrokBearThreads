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

    /// The box is two lines tall when empty, grows a line at a time, and
    /// stops at ten lines (the rest scrolls).
    func testComposerGrowsFromTwoLinesToTen() throws {
        let composer = ComposerTextField.makeTextView()
        composer.frame = NSRect(x: 0, y: 0, width: 400, height: 40)
        // The transcript's body line height, so a sent message keeps its rhythm.
        let line = ComposerTextField.lineHeight
        XCTAssertEqual(line, TypeScale.bodyLine)
        func lines(_ count: Int) -> String { (1...count).map { "Line \($0)" }.joined(separator: "\n") }

        composer.replaceText("")
        XCTAssertEqual(ComposerTextField.fittingHeight(of: composer), ceil(line * 2))
        composer.replaceText("One line")
        XCTAssertEqual(ComposerTextField.fittingHeight(of: composer), ceil(line * 2))
        composer.replaceText(lines(4))
        XCTAssertEqual(ComposerTextField.fittingHeight(of: composer), ceil(line * 4), accuracy: 1)
        composer.replaceText(lines(30))
        XCTAssertEqual(ComposerTextField.fittingHeight(of: composer), ceil(line * 10))
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

/// The runner restart in the window: a quiet banner while it waits, a quiet
/// "Reconnecting" while it's down, then nothing.
@MainActor
final class RestartBannerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testPendingThenRestartingThenBack() {
        let app = AppModel()
        app.connection = .connected
        XCTAssertNil(app.banner)
        app.noticeForTesting("The runner will restart when 2 threads finish.")
        XCTAssertEqual(app.banner, Banner(style: .quiet, icon: "arrow.clockwise", text: "The runner will restart when 2 threads finish."))
        XCTAssertNil(app.errorMessage, "a restart notice isn't an error")
        app.threads["a"] = ThreadSummary(id: "a", title: "Fix the build", status: .running)
        app.restartStatusForTesting(PendingRestart(waitingFor: ["a"]))
        XCTAssertEqual(app.banner?.text, "The runner will restart when 1 thread finishes.")
        XCTAssertEqual(app.banner?.detail, "Waiting for Fix the build")
        app.noticeForTesting("The runner is restarting now.")
        XCTAssertEqual(app.banner?.text, "The runner is restarting now.")
        XCTAssertNil(app.banner?.icon, "a spinner")
        app.connectionLostForTesting()
        XCTAssertEqual(app.banner, Banner(style: .quiet, icon: nil, text: "The runner is restarting. Reconnecting…"))
        // Failed attempts while it's down are part of the restart too.
        app.connection = .runnerDown("refused")
        XCTAssertEqual(app.banner?.style, .quiet)
    }

    func testAPlainDropIsStillAWarning() {
        let app = AppModel()
        app.connectionLostForTesting()
        XCTAssertEqual(app.banner?.style, .warning)
        XCTAssertEqual(app.banner?.text, "Lost the connection to the runner. Reconnecting…")
        app.noticeForTesting(level: "warning", "Release X kept crashing at startup, so the runner went back to Y.")
        XCTAssertEqual(app.errorMessage, "Release X kept crashing at startup, so the runner went back to Y.")
    }

    /// "Start runner" kickstarts the installed runner's LaunchAgent: never
    /// from an app pointed at the mock or a dev runner.
    func testStartRunnerOnlyForTheRealDataFolder() {
        let app = AppModel()
        app.dataDir = RunnerConfig.defaultDataDir
        app.connection = .runnerDown("refused")
        XCTAssertEqual(app.banner?.showStart, true)
        app.dataDir = URL(fileURLWithPath: "/tmp/tb-mock-xyz", isDirectory: true)
        XCTAssertEqual(app.banner?.showStart, false)
        XCTAssertEqual(app.banner?.showRetry, true)
    }

    /// A scripted run's copies go to its own pasteboard, never Mike's.
    func testCopiesGoToTheAppsPasteboard() {
        let app = AppModel()
        let board = NSPasteboard(name: NSPasteboard.Name("com.mikerosoft.threadbare.test.\(UUID().uuidString)"))
        app.pasteboard = board
        app.copyToPasteboard("th_123")
        XCTAssertEqual(board.string(forType: .string), "th_123")
        board.releaseGlobally()
    }
}

/// The resume the runner sends after a restart is a centred note, not a
/// bubble of Mike's.
final class RunnerMessageRenderTests: XCTestCase {
    func testRunnerMessageRendersAsANote() throws {
        let row = TranscriptRow(id: "u:8", version: 3_000_001, seq: 8, content: .user(UserMessage(text: "Check that your change works.", origin: "runner")))
        let render = RowRenderer.render(row, expanded: false, tableWidth: 900, measurer: TextMeasurer())
        let text = try XCTUnwrap(render.text?.string)
        XCTAssertEqual(text, "Sent by the runner after it restarted\nCheck that your change works.")
        let style = try XCTUnwrap(render.text?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.alignment, .center)
        // Shorter than the same words in a bubble, which has the turn's gap above.
        let bubble = RowRenderer.render(TranscriptRow(id: "u:9", version: 3_000_002, seq: 9, content: .user(UserMessage(text: "Check that your change works."))),
                                        expanded: false, tableWidth: 900, measurer: TextMeasurer())
        XCTAssertLessThan(render.height, bubble.height)
    }
}

#if DEBUG
final class AutomationTests: XCTestCase {
    /// Each dev-app instance has its own channel, so commands never reach
    /// another instance (or the installed app).
    @MainActor
    func testChannelsAndLogPaths() {
        XCTAssertEqual(Automation.channel(id: nil), "com.mikerosoft.threadbare.automation")
        XCTAssertEqual(Automation.channel(id: ""), "com.mikerosoft.threadbare.automation")
        XCTAssertEqual(Automation.channel(id: "a3f9"), "com.mikerosoft.threadbare.automation.a3f9")
        XCTAssertEqual(Automation.appLogURL(automationLog: URL(fileURLWithPath: "/tmp/x/drive.log"), arguments: []).path, "/tmp/x/drive.app.log")
        XCTAssertEqual(Automation.appLogURL(automationLog: URL(fileURLWithPath: "/tmp/x/drive.log"), arguments: ["--app-log", "/tmp/y/app.log"]).path, "/tmp/y/app.log")
        XCTAssertEqual(Automation.parseSize("1240x820"), NSSize(width: 1240, height: 820))
        XCTAssertNil(Automation.parseSize("big"))
        XCTAssertEqual(Automation.json("a\nb"), "\"a\\nb\"")
    }

    func testDumpTextMarksSelectionAndRowsOnScreen() {
        let dump = AppDump(
            instance: "a3f9", connection: "connected", runnerVersion: "0.0.0-mock",
            banner: AppDump.BannerInfo(style: "quiet", text: "The runner will restart when 1 thread finishes.", detail: nil),
            error: nil, window: AppDump.Window(width: 1240, height: 820, appearance: "dark"),
            sidebar: AppDump.Sidebar(mode: "inbox", sections: [
                AppDump.Section(name: "Needs you", threads: []),
                AppDump.Section(name: "Inbox", threads: [AppDump.Thread(id: "th1", title: "Fix it", status: "idle", needsYou: false, unread: true, hovered: false)]),
            ], snoozed: 0, archived: 2),
            selection: AppDump.Thread(id: "th1", title: "Fix it", status: "idle", needsYou: false, unread: false, hovered: false),
            composer: AppDump.Composer(draft: "th1", text: "hello", images: 0, cwd: "/w", account: "claude-3", model: "default (the runner's, claude-haiku-5-5)", ask: true),
            transcript: AppDump.Transcript(threadId: "th1", state: "loaded", hasMoreAbove: false, atBottom: true, rows: [
                AppDump.Row(id: "u:1", kind: "user", height: 64, expanded: nil, inGroup: false, onScreen: false, seq: 1, turn: "t1", text: "Fix it"),
                AppDump.Row(id: "g:r:r1", kind: "group", height: 32, expanded: true, inGroup: false, onScreen: true, seq: 2, turn: "t1", text: "Ran a command"),
            ])
        )
        let text = dump.text
        XCTAssertTrue(text.hasPrefix("dev app a3f9: connected, runner 0.0.0-mock, window 1240x820 dark\n"))
        XCTAssertTrue(text.contains("banner (quiet): The runner will restart when 1 thread finishes."))
        XCTAssertFalse(text.contains("Needs you"), "empty sections are left out")
        XCTAssertTrue(text.contains("  > th1"), "the selected thread is marked")
        XCTAssertTrue(text.contains("composer (th1): \"hello\""))
        XCTAssertTrue(text.contains("\n  runs in /w on claude-3, model default (the runner's, claude-haiku-5-5), asks before edits\n"), text)
        XCTAssertTrue(text.contains("> g:r:r1"))
        XCTAssertTrue(text.contains("open    Ran a command"))
        XCTAssertTrue(dump.json(pretty: false).contains("\"onScreen\":true"))
    }

    /// A scripted app never drives Mike's real threads: no --data-dir
    /// means the installed runner's folder, and that's refused.
    @MainActor
    func testRefusesTheLiveRunnerUnlessAllowed() {
        let live = RunnerConfig.defaultDataDir
        let mock = URL(fileURLWithPath: "/tmp/tb-mock-xyz", isDirectory: true)
        XCTAssertTrue(Automation.refusesLiveRunner(dataDir: live, arguments: ["Threadbare", "--automation", "/tmp/a.log"]))
        XCTAssertTrue(Automation.refusesLiveRunner(dataDir: live.appendingPathComponent("."), arguments: ["Threadbare", "--automation", "/tmp/a.log"]))
        XCTAssertFalse(Automation.refusesLiveRunner(dataDir: live, arguments: ["Threadbare", "--automation", "/tmp/a.log", "--automation-allow-live"]))
        XCTAssertFalse(Automation.refusesLiveRunner(dataDir: mock, arguments: ["Threadbare", "--automation", "/tmp/a.log"]))
        XCTAssertFalse(Automation.refusesLiveRunner(dataDir: live, arguments: ["Threadbare"]), "not scripted at all")
    }

    /// What a new thread from the composer would run on, as `dump` and
    /// `options` report it: whose default model it is matters, since an
    /// account's default can be an expensive one.
    @MainActor
    func testNewThreadSettingsSayWhoseDefaultModel() {
        _ = NSApplication.shared
        let app = AppModel()
        app.defaults = RunnerDefaults(cwd: "/w", accountId: "claude-3")
        XCTAssertEqual(AppDump.newThreadSettings(app).model, "default (the account's)")
        app.defaults.model = "claude-haiku-5-5"
        XCTAssertEqual(AppDump.newThreadSettings(app).model, "default (the runner's, claude-haiku-5-5)")
        app.newThreadModel = "sonnet"
        app.newThreadAsk = true
        let settings = AppDump.newThreadSettings(app)
        XCTAssertEqual(settings.model, "sonnet")
        XCTAssertEqual(settings.cwd, "/w")
        XCTAssertTrue(settings.ask)
    }

    /// `focus` lets a scripted app (never in front) count as looking, so
    /// opening an unread thread marks it read as it would for Mike.
    @MainActor
    func testFocusCountsAsLooking() {
        _ = NSApplication.shared
        let app = AppModel()
        XCTAssertFalse(app.isLooking, "a test process isn't the active app")
        app.actsActive = true
        XCTAssertTrue(app.isLooking)
    }
}
#endif
