import XCTest
@testable import ThreadbareCore

final class MarkdownBlocksTests: XCTestCase {
    func testParagraphsSplitOnBlankLines() {
        XCTAssertEqual(MarkdownBlocks.split("# Title\nIntro line\n\nSecond para\n\n\nThird"), ["# Title\nIntro line", "Second para", "Third"])
    }

    func testFencedCodeIsOneBlockWithBlankLines() {
        let text = "Before\n```swift\nlet a = 1\n\nlet b = 2\n```\nAfter"
        XCTAssertEqual(MarkdownBlocks.split(text), ["Before", "```swift\nlet a = 1\n\nlet b = 2\n```", "After"])
    }

    func testUnclosedFenceStaysOpenAtTheEnd() {
        XCTAssertEqual(MarkdownBlocks.split("Intro\n\n```\ncode\n\nmore"), ["Intro", "```\ncode\n\nmore"])
    }

    func testLooseListStaysTogether() {
        let text = "1. One\n\n2. Two\n   more\n\n   indented para\n\nAfter list"
        XCTAssertEqual(MarkdownBlocks.split(text), ["1. One\n\n2. Two\n   more\n\n   indented para", "After list"])
    }

    func testTildeFenceAndInlineBackticks() {
        XCTAssertEqual(MarkdownBlocks.split("~~~\na\n\n~~~\n``` not a fence ``` text"), ["~~~\na\n\n~~~", "``` not a fence ``` text"])
    }

    func testStreamingPrefixKeepsEarlierBlocksStable() {
        let full = "Para one.\n\nPara two is longer.\n\n- a\n- b"
        let partial = String(full.prefix(30))
        XCTAssertEqual(Array(MarkdownBlocks.split(partial).dropLast()), Array(MarkdownBlocks.split(full).prefix(1)))
    }
}

final class DiffBuilderTests: XCTestCase {
    func testSimpleReplacement() {
        let hunks = DiffBuilder.hunks(old: "a\nb\nc", new: "a\nB\nc")
        XCTAssertEqual(hunks, [DiffHunk(oldStart: 1, oldLines: 3, newStart: 1, newLines: 3, lines: [" a", "-b", "+B", " c"])])
    }

    func testFarApartChangesMakeTwoHunks() {
        let old = (1...20).map { "line \($0)" }
        var new = old
        new[1] = "changed 2"
        new[17] = "changed 18"
        let hunks = DiffBuilder.hunks(oldLines: old, newLines: new)
        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(hunks[0].oldStart, 1)
        XCTAssertEqual(hunks[1].oldStart, 15)
        XCTAssertEqual(hunks[1].lines.filter { $0.hasPrefix("+") }, ["+changed 18"])
    }

    func testIdenticalTextHasNoHunks() {
        XCTAssertTrue(DiffBuilder.hunks(old: "same", new: "same").isEmpty)
    }

    func testWriteToolIsAllAdded() {
        let call = ToolCall(itemId: "c", name: "Write", kind: .write, title: "Write a.txt", input: .object(["file_path": .string("/a.txt"), "content": .string("x\ny\n")]))
        let diff = DiffBuilder.diff(forTool: call)
        XCTAssertEqual(diff?.hunks.first?.lines, ["+x", "+y"])
        XCTAssertEqual(diff.map(DiffBuilder.stats)?.added, 2)
    }

    func testMultiEdit() {
        let call = ToolCall(itemId: "c", name: "MultiEdit", kind: .edit, title: "MultiEdit", input: .object([
            "file_path": .string("/a"),
            "edits": .array([
                .object(["old_string": .string("a"), "new_string": .string("b")]),
                .object(["old_string": .string("c"), "new_string": .string("d")]),
            ]),
        ]))
        XCTAssertEqual(DiffBuilder.diff(forTool: call)?.hunks.count, 2)
    }

    func testDisplayLinesNumberAndCap() {
        let diff = EditDiff(itemId: "c", path: "/a", hunks: [DiffHunk(oldStart: 10, oldLines: 2, newStart: 10, newLines: 2, lines: [" keep", "-old", "+new"])])
        let lines = DiffBuilder.displayLines(diff)
        XCTAssertEqual(lines.map(\.kind), [.context, .removed, .added])
        XCTAssertEqual(lines[0].oldNumber, 10)
        XCTAssertEqual(lines[2].newNumber, 11)
        let capped = DiffBuilder.displayLines(diff, maxLines: 2)
        XCTAssertEqual(capped.last?.kind, .elided)
        XCTAssertEqual(capped.last?.text, "1 more lines")
    }
}

final class SnoozeTests: XCTestCase {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    func date(_ text: String) -> Date { ISO8601.parse(text)! }

    func testMorningPresets() {
        // Monday 26 Oct 2026, 10:00 London (GMT after the clocks change).
        let presets = Snooze.presets(now: date("2026-10-26T10:00:00Z"), calendar: calendar)
        XCTAssertEqual(presets.map(\.id), ["hour", "evening", "tomorrow", "monday"])
        XCTAssertEqual(presets[0].date, date("2026-10-26T11:00:00Z"))
        XCTAssertEqual(presets[1].date, date("2026-10-26T18:00:00Z"))
        XCTAssertEqual(presets[2].date, date("2026-10-27T09:00:00Z"))
        // Next Monday, not today.
        XCTAssertEqual(presets[3].date, date("2026-11-02T09:00:00Z"))
    }

    func testEveningPresetHiddenLate() {
        let presets = Snooze.presets(now: date("2026-10-30T17:30:00Z"), calendar: calendar)
        XCTAssertEqual(presets.map(\.id), ["hour", "tomorrow", "monday"])
        XCTAssertEqual(presets.last?.date, date("2026-11-02T09:00:00Z"))
    }

    func testPresetDateIsWorkedOutWhenChosen() {
        // The menu was built at 10:00; "1 hour" chosen at 11:50 means 12:50.
        XCTAssertEqual(Snooze.date(for: "hour", now: date("2026-10-26T11:50:00Z"), calendar: calendar), date("2026-10-26T12:50:00Z"))
        // "Tomorrow" chosen after midnight is the next day's 9 am.
        XCTAssertEqual(Snooze.date(for: "tomorrow", now: date("2026-10-27T00:10:00Z"), calendar: calendar), date("2026-10-28T09:00:00Z"))
        // "This evening" from a stale menu at 18:30 falls back to an hour, never the past.
        XCTAssertEqual(Snooze.date(for: "evening", now: date("2026-10-26T18:30:00Z"), calendar: calendar), date("2026-10-26T19:30:00Z"))
    }
}

final class ThreadSectionsTests: XCTestCase {
    func thread(_ id: String, status: ThreadStatus = .idle, needsYou: Bool = false, minutesAgo: Double, snoozed: Date? = nil, archived: Date? = nil) -> ThreadSummary {
        let now = Date(timeIntervalSince1970: 1_000_000)
        return ThreadSummary(id: id, title: id, status: status, needsYou: needsYou, lastActivityAt: now.addingTimeInterval(-minutesAgo * 60), snoozedUntil: snoozed, archivedAt: archived)
    }

    func testSections() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let threads = [
            thread("idle-old", minutesAgo: 50),
            thread("idle-new", minutesAgo: 5),
            thread("waiting", status: .waiting, minutesAgo: 30),
            thread("unread", needsYou: true, minutesAgo: 1),
            thread("running", status: .running, minutesAgo: 2),
            thread("snoozed", minutesAgo: 1, snoozed: now.addingTimeInterval(60)),
            thread("woke", minutesAgo: 1, snoozed: now.addingTimeInterval(-60)),
            thread("archived", minutesAgo: 1, archived: now),
        ]
        let sections = ThreadSections.build(threads, now: now)
        XCTAssertEqual(sections.needsYou.map(\.id), ["unread", "waiting"])
        XCTAssertEqual(sections.running.map(\.id), ["running"])
        XCTAssertEqual(sections.inbox.map(\.id), ["woke", "idle-new", "idle-old"])
        XCTAssertEqual(ThreadSections.snoozed(threads, now: now).map(\.id), ["snoozed"])
    }

    func testPreviewTextDropsMarkdown() {
        XCTAssertEqual(PreviewText.plain("## 0.4 - **Uploads resume** after the app quits"), "0.4 - Uploads resume after the app quits")
        XCTAssertEqual(PreviewText.plain("Done. The tabs now read **General**, `Accounts` and [Usage](https://x.y)."), "Done. The tabs now read General, Accounts and Usage.")
        XCTAssertEqual(PreviewText.plain("Plain files win here: 1. Events are append-only. > quoted ### Next"), "Plain files win here: 1. Events are append-only. quoted Next")
        XCTAssertEqual(PreviewText.plain("C# and a#b stay"), "C# and a#b stay")
    }

    func testArchivedSearch() {
        var a = thread("a", minutesAgo: 1, archived: Date(timeIntervalSince1970: 10))
        a.title = "Résumé builder"
        var b = thread("b", minutesAgo: 1, archived: Date(timeIntervalSince1970: 20))
        b.preview = "Fixed the upload test"
        let c = thread("c", minutesAgo: 1)
        XCTAssertEqual(ThreadSections.archived([a, b, c]).map(\.id), ["b", "a"])
        XCTAssertEqual(ThreadSections.archived([a, b, c], matching: "resume").map(\.id), ["a"])
        XCTAssertEqual(ThreadSections.archived([a, b, c], matching: "UPLOAD").map(\.id), ["b"])
    }

    func testRelativeTime() {
        let now = ISO8601.parse("2026-10-26T12:00:00Z")!
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-10), now: now), "now")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-300), now: now), "5m")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-7200), now: now), "2h")
        XCTAssertEqual(RelativeTime.duration(milliseconds: 850), "850 ms")
        XCTAssertEqual(RelativeTime.duration(milliseconds: 72_000), "1m 12s")
    }

    /// Aliases from the model menu read as words; full model ids as typed.
    func testModelName() {
        XCTAssertEqual(ModelName.display("haiku"), "Haiku")
        XCTAssertEqual(ModelName.display("claude-haiku-5-5"), "claude-haiku-5-5")
        XCTAssertEqual(ModelName.display("opus[1m]"), "opus[1m]")
    }

    /// A small model's turn costs well under a cent; "$0.00" read as free.
    func testCostText() {
        XCTAssertEqual(CostText.format(1.234), "$1.23")
        XCTAssertEqual(CostText.format(0.05), "$0.05")
        XCTAssertEqual(CostText.format(0.0044), "$0.004")
        XCTAssertEqual(CostText.format(0.0004), "<$0.001")
        XCTAssertNil(CostText.format(0))
        XCTAssertNil(CostText.format(nil))
    }
}

final class ImageSizeTests: XCTestCase {
    func testPNG() {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]
        bytes += [0, 0, 0x05, 0x00, 0, 0, 0x02, 0xD0, 8, 6, 0, 0, 0]
        let size = ImageSize.read(data: Data(bytes))
        XCTAssertEqual(size?.width, 1280)
        XCTAssertEqual(size?.height, 720)
    }

    func testGIF() {
        let bytes: [UInt8] = Array("GIF89a".utf8) + [0x40, 0x01, 0xF0, 0x00, 0, 0, 0]
        let size = ImageSize.read(data: Data(bytes))
        XCTAssertEqual(size?.width, 320)
        XCTAssertEqual(size?.height, 240)
    }

    func testJPEGSkipsAPPSegments() {
        var bytes: [UInt8] = [0xFF, 0xD8]
        bytes += [0xFF, 0xE0, 0x00, 0x06, 1, 2, 3, 4] // APP0, length 6
        bytes += [0xFF, 0xC0, 0x00, 0x11, 0x08, 0x01, 0xE0, 0x02, 0x80, 0x03] // SOF0 480 x 640
        bytes += Array(repeating: 0, count: 16)
        let size = ImageSize.read(data: Data(bytes))
        XCTAssertEqual(size?.width, 640)
        XCTAssertEqual(size?.height, 480)
    }

    func testWebPVP8X() {
        var bytes: [UInt8] = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBPVP8X".utf8) + [10, 0, 0, 0, 0, 0, 0, 0]
        bytes += [0x1F, 0x03, 0x00, 0x57, 0x02, 0x00] // 800 x 600 minus one
        bytes += [0, 0]
        let size = ImageSize.read(data: Data(bytes))
        XCTAssertEqual(size?.width, 800)
        XCTAssertEqual(size?.height, 600)
    }

    func testNotAnImage() {
        XCTAssertNil(ImageSize.read(data: Data("hello world, not an image".utf8)))
    }
}

final class MarkdownExportTests: XCTestCase {
    func testTranscriptExport() {
        let model = TranscriptModel(events: [
            E.user(1, "Run the tests"),
            E.call(2, "c1", title: "npm test"),
            E.result(3, "c1", text: "ok ```weird```"),
            E.text(4, "m1", "All **green**."),
            E.done(5),
        ])
        let markdown = MarkdownExport.transcript(title: "Tests", rows: model.items)
        XCTAssertTrue(markdown.hasPrefix("# Tests\n\n## You\n\nRun the tests\n\n"))
        XCTAssertTrue(markdown.contains("**Bash**: `npm test`\n\n````\nok ```weird```\n````"))
        XCTAssertTrue(markdown.contains("## Claude\n\nAll **green**."))
        XCTAssertTrue(markdown.contains("_4s, $0.12_"))
        XCTAssertEqual(MarkdownExport.message(for: model.items[2]), "All **green**.")
    }
}

final class RunnerConfigTests: XCTestCase {
    func testEndpointFromDataDir() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("secrets"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try RunnerConfig.endpoint(dataDir: dir))
        try "test-token\n".write(to: dir.appendingPathComponent("secrets/runner-token"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try RunnerConfig.endpoint(dataDir: dir), RunnerEndpoint(url: URL(string: "ws://127.0.0.1:8797/rpc")!, token: "test-token"))
        try #"{"port": 9123, "other": 1}"#.write(to: dir.appendingPathComponent("runner.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try RunnerConfig.endpoint(dataDir: dir).url.absoluteString, "ws://127.0.0.1:9123/rpc")
    }

    func testDataDirOverrides() {
        XCTAssertEqual(RunnerConfig.dataDir(arguments: ["app", "--data-dir", "/tmp/x"], environment: [:]).path, "/tmp/x")
        XCTAssertEqual(RunnerConfig.dataDir(arguments: ["app"], environment: ["THREADBARE_DATA_DIR": "/tmp/y"]).path, "/tmp/y")
        XCTAssertTrue(RunnerConfig.dataDir(arguments: ["app"], environment: [:]).path.hasSuffix("Library/Application Support/Threadbare"))
    }

    func testBackoff() {
        var backoff = Backoff()
        XCTAssertEqual((0..<8).map { _ in backoff.next() }, [0.25, 0.5, 1, 2, 4, 8, 10, 10])
        backoff.reset()
        XCTAssertEqual(backoff.next(), 0.25)
    }
}
