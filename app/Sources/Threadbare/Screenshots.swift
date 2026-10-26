import AppKit
import ThreadbareCore

/// `--screenshots <dir>`: opens the synthetic demo threads from the mock
/// runner and saves window-only screenshots (`screencapture -l` with this
/// window's id, never the full screen). Used for PRs and design checks.
@MainActor
enum ScreenshotRunner {
    static func start(app: AppModel) {
        Task { await run(app: app) }
    }

    static func run(app: AppModel) async {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--screenshots"), index + 1 < arguments.count else {
            NSApp.terminate(nil)
            return
        }
        let dir = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for _ in 0..<400 where app.connection != .connected || app.threads.isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else {
            NSApp.terminate(nil)
            return
        }
        // `--appearance light|dark` checks both looks whatever the Mac is set to.
        if let index = arguments.firstIndex(of: "--appearance"), index + 1 < arguments.count {
            NSApp.appearance = NSAppearance(named: arguments[index + 1] == "light" ? .aqua : .darkAqua)
        }
        window.setContentSize(NSSize(width: 1240, height: 820))
        window.center()
        // Behind every other window and never activated: these runs happen
        // while Mike is working, and `screencapture -l` captures a window by
        // id even when it's covered.
        window.orderBack(nil)
        try? await Task.sleep(for: .milliseconds(500))

        let only = arguments.firstIndex(of: "--only").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        func wanted(_ name: String) -> Bool { only == nil || name.hasPrefix(only!) }

        // 1. The demo thread at the bottom: images, a footer and an approval card.
        let demo = "demo_upload_resume"
        await open(app, demo)
        if wanted("1") {
            app.transcript.scrollToBottom()
            await capture(window, dir.appendingPathComponent("1-thread-bottom.png"))
        }
        // 2. Further up: the plan, a new file and an edit as diffs.
        if wanted("2") {
            await scroll(app, toRow: "p:", offset: 20)
            await capture(window, dir.appendingPathComponent("2-plan-and-diffs.png"))
        }
        // 3. Top of the thread with the test run expanded.
        if wanted("3") {
            app.session(for: demo).expanded.insert("t:c2")
            app.transcript.show(nil)
            app.transcript.show(app.session(for: demo))
            await scroll(app, toRow: "u:1", offset: 0)
            await capture(window, dir.appendingPathComponent("3-top-tool-expanded.png"))
        }
        // 4. A thread waiting on a question.
        if wanted("4") {
            await open(app, "demo_button_colour")
            app.transcript.scrollToBottom()
            await capture(window, dir.appendingPathComponent("4-question.png"))
        }
        // 5. The archive.
        if wanted("5") {
            app.sidebarMode = .archive
            app.loadArchive()
            try? await Task.sleep(for: .milliseconds(400))
            await open(app, "demo_tunnel")
            await capture(window, dir.appendingPathComponent("5-archive.png"))
        }
        // 6. A long reply (the mock's synthetic stream text): taller than
        // the window, so its text is drawn through a slice. Captured at the
        // end, in the middle, and while it streams pinned to the bottom.
        if wanted("6") {
            app.sidebarMode = .inbox
            let thread = "demo_dark_mode"
            await open(app, thread)
            app.transcript.scrollToBottom()
            _ = try? await app.client?.call("mock.stream", .object([
                "threadId": .string(thread), "seconds": .number(12), "hz": .number(90),
            ]), as: EmptyResult.self)
            try? await Task.sleep(for: .seconds(8))
            await capture(window, dir.appendingPathComponent("6a-long-reply-streaming.png"))
            try? await Task.sleep(for: .seconds(5))
            app.transcript.scrollToBottom()
            await capture(window, dir.appendingPathComponent("6b-long-reply-end.png"))
            if let session = app.transcript.session, let index = (0..<session.displayCount).last(where: { session.displayRow($0).kind == .assistant }) {
                let rect = app.transcript.tableView.rect(ofRow: index)
                print("long reply row: \(Int(rect.height)) pt tall in a \(Int(app.transcript.scrollView.contentView.bounds.height)) pt window")
                app.transcript.scroll(toRow: index, offset: -rect.height / 2)
                try? await Task.sleep(for: .milliseconds(400))
                await capture(window, dir.appendingPathComponent("6c-long-reply-middle.png"))
                if let cell = app.transcript.tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? TextRowCell {
                    print("long reply text view: drawn \(Int(cell.textView.frame.height)) pt of \(Int(cell.textView.fullFrame.height)) pt")
                }
            }
        }
        // 7. Typing into the composer reaches the draft (it used to be dropped).
        if wanted("7") {
            app.select(nil)
            try? await Task.sleep(for: .milliseconds(300))
            if let composer = findComposer(in: window.contentView) {
                window.makeFirstResponder(composer)
                composer.insertText("Hello from the composer", replacementRange: composer.selectedRange())
                try? await Task.sleep(for: .milliseconds(300))
                print("composer: typed text, draft is now \"\(app.drafts["new"]?.text ?? "")\"")
                await capture(window, dir.appendingPathComponent("7-composer-typed.png"))
                app.drafts["new"] = nil
            } else {
                print("composer: not found")
            }
        }
        NSApp.terminate(nil)
    }

    private static func findComposer(in view: NSView?) -> ComposerTextView? {
        guard let view else { return nil }
        if let composer = view as? ComposerTextView { return composer }
        for sub in view.subviews {
            if let found = findComposer(in: sub) { return found }
        }
        return nil
    }

    private static func open(_ app: AppModel, _ id: String) async {
        app.select(id)
        let session = app.session(for: id)
        for _ in 0..<200 where session.state != .loaded || app.transcript.session !== session {
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await Task.sleep(for: .milliseconds(500))
    }

    private static func scroll(_ app: AppModel, toRow prefix: String, offset: CGFloat) async {
        guard let session = app.transcript.session else { return }
        for index in 0..<session.displayCount where session.displayRow(index).id.hasPrefix(prefix) {
            app.transcript.scroll(toRow: index, offset: offset)
            break
        }
        try? await Task.sleep(for: .milliseconds(400))
    }

    private static func capture(_ window: NSWindow, _ url: URL) async {
        window.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-o", "-x", "-l", String(window.windowNumber), url.path]
        try? process.run()
        process.waitUntilExit()
        print("saved \(url.path)")
    }
}
