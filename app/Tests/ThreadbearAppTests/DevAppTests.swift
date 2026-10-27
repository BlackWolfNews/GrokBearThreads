import AppKit
import XCTest
@testable import Threadbear
@testable import ThreadbearCore

#if DEBUG
/// The automation hook's argument handling and what `dump` and "Copy debug
/// info" print, the parts dev-app.sh users hit when something goes wrong.
@MainActor
final class DevAppTests: XCTestCase {
    private let ids = ["e497c478-78a5-430d-ab00-6a6c9e62e396", "e4a10000-0000-4000-8000-000000000000", "demo_upload"]

    /// A start that matches several threads is an error, not whichever
    /// sorted first (tb and the threadbear tools refuse it too).
    func testThreadsAreNamedByIdOrAUniqueStart() {
        XCTAssertEqual(Automation.thread("demo_upload", in: ids).id, "demo_upload")
        XCTAssertEqual(Automation.thread("e497", in: ids).id, ids[0])
        let ambiguous = Automation.thread("e4", in: ids)
        XCTAssertNil(ambiguous.id)
        XCTAssertEqual(ambiguous.error, "error e4 matches 2 threads")
        XCTAssertEqual(Automation.thread("zz", in: ids).error, "error no such thread zz")
        XCTAssertNil(Automation.thread(42, in: ids).id)
    }

    /// archive, unarchive, snooze and copy-thread-id act on `id` when it's
    /// given, never quietly on whatever is open instead.
    func testCommandsActOnTheThreadNamedElseTheOpenOne() {
        XCTAssertEqual(Automation.target(["cmd": "archive", "id": "demo"], threads: ids, selection: ids[0]).id, "demo_upload")
        XCTAssertEqual(Automation.target(["cmd": "archive"], threads: ids, selection: ids[0]).id, ids[0])
        XCTAssertEqual(Automation.target(["cmd": "archive", "id": NSNull()], threads: ids, selection: ids[0]).id, ids[0])
        let unknown = Automation.target(["cmd": "archive", "id": "nope"], threads: ids, selection: ids[0])
        XCTAssertNil(unknown.id, "an id that matches nothing doesn't fall back to the open thread")
        XCTAssertEqual(unknown.error, "error no such thread nope")
        XCTAssertEqual(Automation.target(["cmd": "snooze"], threads: ids, selection: nil).error, "error no thread: pass id, or open one first")
    }

    /// JSONSerialization raises an Objective-C exception (which `try?`
    /// doesn't catch) for a top level that isn't an object or an array; a
    /// `mock` command with `"params": null` used to crash the app.
    func testMockParamsAreAnObjectOrNothing() {
        XCTAssertEqual(Automation.mockParams(nil), .object([:]))
        XCTAssertEqual(Automation.mockParams(NSNull()), .object([:]))
        XCTAssertEqual(Automation.mockParams(["downMs": 500]), .object(["downMs": .number(500)]))
        XCTAssertNil(Automation.mockParams(3))
        XCTAssertNil(Automation.mockParams("restart"))
        XCTAssertNil(Automation.mockParams([1, 2]))
    }

    /// A temp bundle writing into a protected folder would put a macOS
    /// access prompt in front of Mike.
    func testNeverWritesIntoProtectedFolders() {
        let home = "/Users/someone"
        for path in ["/Users/someone/Desktop/a.png", "/Users/someone/Documents/x/dump.txt", "/Users/someone/Downloads", "/Users/someone/tmp/../Desktop/b.png"] {
            XCTAssertNotNil(Automation.refusesToWrite(path, home: home), path)
        }
        for path in ["/tmp/a.png", "/Users/someone/dev/shots/a.png", "/Users/someone/Desktopper/a.png"] {
            XCTAssertNil(Automation.refusesToWrite(path, home: home), path)
        }
    }

    /// Real runner ids (36-character UUIDs, `g:t:toolu_…`) used to push the
    /// later columns out of line.
    func testDumpColumnsFitTheLongestId() {
        let long = "g:t:toolu_017bkpeTbe7HfEDx7QCN8x28"
        let dump = AppDump(
            instance: "e3d4", connection: "connected", runnerVersion: "0.1.0+source", banner: nil, error: nil, window: nil,
            sidebar: AppDump.Sidebar(mode: "inbox", sections: [
                AppDump.Section(name: "Inbox", threads: [
                    AppDump.Thread(id: ids[0], title: "Use the tools", status: "idle", needsYou: false, unread: true, hovered: false),
                    AppDump.Thread(id: "demo_upload", title: "Upload", status: "running", needsYou: false, unread: false, hovered: false),
                ]),
            ], snoozed: 0, archived: 0),
            selection: nil,
            composer: AppDump.Composer(draft: "new", text: "", images: 0, cwd: "/w", account: "claude-3", model: "default (the account's)", ask: false),
            transcript: AppDump.Transcript(threadId: ids[0], state: "loaded", hasMoreAbove: false, atBottom: true, rows: [
                AppDump.Row(id: "u:1", kind: "user", height: 64, expanded: nil, inGroup: false, onScreen: true, seq: 1, turn: "t1", text: "Read them"),
                AppDump.Row(id: long, kind: "group", height: 32, expanded: false, inGroup: false, onScreen: true, seq: 2, turn: "t1", text: "Read 2 files"),
                AppDump.Row(id: "a:msg_01:0", kind: "assistant", height: 40, expanded: nil, inGroup: true, onScreen: true, seq: 5, turn: "t1", text: "Done"),
            ])
        )
        let lines = dump.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let sidebar = lines.filter { $0.contains("Use the tools") || $0.contains("Upload") }
        XCTAssertEqual(sidebar.count, 2)
        XCTAssertEqual(Set(sidebar.map { $0.range(of: $0.contains("Upload") ? "running" : "idle")!.lowerBound.utf16Offset(in: $0) }).count, 1, "the flags line up")
        let rows = lines.filter { $0.contains("Read them") || $0.contains("Read 2 files") || $0.hasSuffix("Done") }
        XCTAssertEqual(rows.count, 3)
        let kindColumn = Set(rows.map { line in ["user", "group", "assistant"].compactMap { line.range(of: " \($0) ")?.lowerBound.utf16Offset(in: line) }.first! })
        XCTAssertEqual(kindColumn.count, 1, "the kind column lines up:\n" + rows.joined(separator: "\n"))
    }

    /// "Copy debug info" names a command that reaches the runner the app is
    /// on: a bare tb from a thread asks the live runner.
    func testDebugInfoNamesTheRunnerTheAppIsOn() throws {
        _ = NSApplication.shared
        let app = AppModel()
        app.dataDir = RunnerConfig.defaultDataDir
        XCTAssertEqual(app.eventsSource, .tb("tb"))
        app.runnerVersion = "0.0.0-mock+r1"
        XCTAssertEqual(app.eventsSource, .fixture)
        app.runnerVersion = "0.1.0+source"
        let dev = FileManager.default.temporaryDirectory.appendingPathComponent("tb dev \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dev, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dev) }
        app.dataDir = dev
        XCTAssertEqual(app.eventsSource, .tb("THREADBEAR_HOME='\(dev.path)' tb"))
        let tb = dev.appendingPathComponent("tb")
        FileManager.default.createFile(atPath: tb.path, contents: Data("#!/bin/bash\n".utf8), attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(app.eventsSource, .tb("'\(tb.path)'"))
        XCTAssertEqual(AppModel.shellQuoted("/tmp/x/tb"), "/tmp/x/tb")
        XCTAssertEqual(AppModel.shellQuoted("it's"), #"'it'\''s'"#)
    }
}
#endif
