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
        freshSidebar(in: window)
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
        // 2b. A message with an image attached: the image above the bubble,
        // right-aligned, with no box behind it.
        if wanted("2b"), let session = app.transcript.session,
           let index = (0..<session.displayCount).first(where: { index in
               if case .user(let message) = session.displayRow(index).content { return !message.images.isEmpty }
               return false
           }) {
            app.transcript.scroll(toRow: index, offset: 140)
            try? await Task.sleep(for: .milliseconds(400))
            await capture(window, dir.appendingPathComponent("2b-user-image.png"))
        }
        // 3. Top of the thread with its first work group open and the file
        // read in it expanded.
        if wanted("3") {
            let session = app.session(for: demo)
            session.expanded.insert("t:c2")
            session.setModelExpanded("g:r:r1", true)
            app.transcript.show(nil)
            app.transcript.show(session)
            await scroll(app, toRow: "u:1", offset: 0)
            await capture(window, dir.appendingPathComponent("3-top-tool-expanded.png"))
            session.setModelExpanded("g:r:r1", false)
        }
        // 4. A thread waiting on a question.
        if wanted("4") {
            await open(app, "demo_button_colour")
            app.transcript.scrollToBottom()
            await capture(window, dir.appendingPathComponent("4-question.png"))
        }
        // 5. The archive, with the pointer over the other row (Unarchive).
        if wanted("5") {
            app.showArchive()
            try? await Task.sleep(for: .milliseconds(400))
            await open(app, "demo_tunnel")
            app.hoverOverride = "demo_quick_ask_readme"
            await capture(window, dir.appendingPathComponent("5-archive.png"))
            app.hoverOverride = nil
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
        // 8. A turn that's still running (the working line and a live
        // group), then the demo's edits: the group open with its new file
        // and its edit opened, and a file opened in the changes card.
        if wanted("8") {
            app.sidebarMode = .inbox
            await open(app, "demo_ci_slow")
            app.transcript.scrollToBottom()
            await capture(window, dir.appendingPathComponent("8a-live-turn.png"))
            await open(app, demo)
            let session = app.session(for: demo)
            // The new file and the edit in the group opened, so the shot
            // shows both kinds of opened diff.
            session.expanded.formUnion(["t:c3", "t:c4"])
            if let group = (0..<session.displayCount).map({ session.displayRow($0) }).first(where: { row in
                if case .group(let group) = row.content { return group.memberIds.contains("t:c3") }
                return false
            }) {
                session.setModelExpanded(group.id, true)
            }
            session.setModelExpanded(ChangedFiles.expansionKey(turnId: "turn_1", path: "/Users/mike/dev/photo-sync/Sources/Upload/UploadTask.swift"), true)
            await scroll(app, toRow: "t:c3", offset: 60)
            await capture(window, dir.appendingPathComponent("8b-group-and-diffs.png"))
            await scroll(app, toRow: "cf:", offset: 120)
            await capture(window, dir.appendingPathComponent("8c-changes-card.png"))
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
                // 7b. An image from the demo thread attached the way "+",
                // paste and drop attach one, with its remove badge showing.
                if let image = demoImage(app, "demo_upload_resume") {
                    let refs = await app.importImages([URL(fileURLWithPath: image)])
                    app.drafts["new", default: Draft()].images += refs
                    AttachmentThumbnail.debugShowRemove = true
                    try? await Task.sleep(for: .milliseconds(400))
                    await capture(window, dir.appendingPathComponent("7b-composer-image.png"))
                    AttachmentThumbnail.debugShowRemove = false
                }
                // 7c. A long draft: the box stops growing at ten lines and scrolls.
                app.drafts["new"] = Draft(text: (1...14).map { "Line \($0) of a long message" }.joined(separator: "\n"))
                try? await Task.sleep(for: .milliseconds(400))
                await capture(window, dir.appendingPathComponent("7c-composer-long.png"))
                app.drafts["new"] = nil
            } else {
                print("composer: not found")
            }
        }
        // 9. The pointer over an inbox row: Snooze and Archive in place of
        // its time.
        if wanted("9") {
            app.sidebarMode = .inbox
            await open(app, "demo_upload_resume")
            app.hoverOverride = "demo_settings_tabs"
            await capture(window, dir.appendingPathComponent("9-sidebar-hover.png"))
            app.hoverOverride = nil
        }
        // 10. What the other threads don't show, from an archived one: a
        // group with a failed tool, open, with its command and its key/value
        // tool opened; then an allowed Write approval (a line in the group,
        // opened to what it asked) and an answered question.
        if wanted("10") {
            let thread = "demo_build_scripts"
            await open(app, thread)
            let session = app.session(for: thread)
            session.expanded.formUnion(["t:ls", "t:pr", "t:rel", "ap:ap_w"])
            session.setModelExpanded("g:t:ls", true)
            app.transcript.show(nil)
            app.transcript.show(session)
            await scroll(app, toRow: "u:", offset: 0)
            await capture(window, dir.appendingPathComponent("10a-tool-details.png"))
            await scroll(app, toRow: "ap:", offset: 20)
            await capture(window, dir.appendingPathComponent("10b-answered-cards.png"))
        }
        NSApp.terminate(nil)
    }

    /// A fresh window's sidebar width. This debug build shares the app's
    /// defaults, so its split view came back at whatever width was saved
    /// last; the shots show the default instead, and don't save it back.
    private static func freshSidebar(in window: NSWindow) {
        func find(_ view: NSView?) -> NSSplitView? {
            guard let view else { return nil }
            if let split = view as? NSSplitView { return split }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        guard let split = find(window.contentView), split.subviews.count > 1 else { return }
        split.autosaveName = nil
        split.setPosition(RootView.sidebarIdealWidth, ofDividerAt: 0)
    }

    /// The first image a demo thread's messages carry, if it's loaded.
    private static func demoImage(_ app: AppModel, _ id: String) -> String? {
        let session = app.session(for: id)
        for index in 0..<session.displayCount {
            switch session.displayRow(index).content {
            case .user(let message) where !message.images.isEmpty: return message.images[0].path
            case .images(_, let images) where !images.isEmpty: return images[0].path
            default: continue
            }
        }
        return nil
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
        if FileManager.default.fileExists(atPath: url.path) {
            print("saved \(url.path)")
        } else if drawInProcess(window, to: url) {
            // With the screen locked (or the display asleep) the window
            // server has no image of the window to give. AppKit can still
            // draw it, without the sidebar's translucency.
            print("saved \(url.path) (drawn in-process: the screen is locked or asleep)")
        } else {
            print("could not save \(url.path)")
        }
    }

    /// The whole window (title bar and toolbar too) drawn by AppKit into a
    /// bitmap at the window's scale.
    private static func drawInProcess(_ window: NSWindow, to url: URL) -> Bool {
        guard let frameView = window.contentView?.superview else { return false }
        frameView.layoutSubtreeIfNeeded()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return false }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}
