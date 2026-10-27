#if DEBUG
import AppKit
import ThreadbareCore

/// Debug builds only, and only when launched with `--automation <log file>`:
/// lets a script or an agent drive the app through its own UI code paths
/// (the composer, the transcript's buttons and menus, archive and snooze)
/// without the window having to be in front. macOS gives an agent's process
/// no accessibility access to this window, and taking focus from whatever
/// Mike is typing into is worse, so the commands arrive as distributed
/// notifications instead. `Tools/dev-app.sh` and `Tools/drive.sh` post them.
///
/// Each command is a JSON object in the notification's `object` string;
/// each result is one line in the log file: `<cmd> ok ...` or
/// `<cmd> error ...`, starting `#<rid> ` when the command carried a `rid`
/// (dev-app.sh waits for its own). `--automation-id <id>` gives an instance
/// its own notification name and pasteboard, so several can run at once.
@MainActor
enum Automation {
    static let baseName = "com.mikerosoft.threadbare.automation"
    private(set) static var instanceId: String?
    private static var logURL: URL?
    private static var observer: NSObjectProtocol?
    /// When the last command came in, for `--automation-idle-quit`.
    private static var lastCommandAt = Date()
    /// A transcript cell drawn as hovered by `hover`, to clear later.
    private static weak var hoveredCell: RowCellView?

    /// The notification name and the private pasteboard's name for an
    /// instance (or the shared ones `drive.sh` uses).
    static func channel(id: String?) -> String {
        guard let id, !id.isEmpty else { return baseName }
        return "\(baseName).\(id)"
    }

    /// This instance's pasteboard: images pasted in and anything the app
    /// copies go through it, so Mike's clipboard is never touched.
    static var pasteboard: NSPasteboard { NSPasteboard(name: NSPasteboard.Name(channel(id: instanceId))) }

    static func argument(after flag: String, in arguments: [String] = CommandLine.arguments) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// Where the app's own log goes: `--app-log`, else beside the automation
    /// log (`drive.log` gives `drive.app.log`).
    static func appLogURL(automationLog: URL, arguments: [String] = CommandLine.arguments) -> URL {
        if let path = argument(after: "--app-log", in: arguments) { return URL(fileURLWithPath: path) }
        return automationLog.deletingPathExtension().appendingPathExtension("app.log")
    }

    /// A scripted app pointed at the installed runner's data folder would
    /// send, approve, archive and snooze in Mike's real threads (and the
    /// installed app is itself a debug build). It needs `--data-dir` (the
    /// mock or a dev runner), or `--automation-allow-live` from Mike.
    static func refusesLiveRunner(dataDir: URL, arguments: [String] = CommandLine.arguments) -> Bool {
        guard argument(after: "--automation", in: arguments) != nil, !arguments.contains("--automation-allow-live") else { return false }
        return dataDir.resolvingSymlinksInPath().standardizedFileURL.path
            == RunnerConfig.defaultDataDir.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Says why in the automation log (where the script waits for "ready")
    /// and on stderr, then exits before the app connects to anything.
    static func refuseLiveRunner() -> Never {
        let message = "error refusing to be scripted against the live runner's data folder: pass --data-dir (the mock or a dev runner; Tools/dev-app.sh does), or --automation-allow-live if Mike asked for it"
        if let path = argument(after: "--automation") {
            FileManager.default.createFile(atPath: path, contents: Data((message + "\n").utf8))
        }
        FileHandle.standardError.write(Data(("Threadbare: " + message + "\n").utf8))
        exit(2)
    }

    static func startIfAsked(app: AppModel) {
        guard let path = argument(after: "--automation") else { return }
        instanceId = argument(after: "--automation-id")
        let logURL = URL(fileURLWithPath: path)
        self.logURL = logURL
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        AppLog.writeFile(to: appLogURL(automationLog: logURL))
        AppLog.write("automation", "listening on \(channel(id: instanceId))")
        app.pasteboard = pasteboard
        if let mode = argument(after: "--appearance") { setAppearance(mode) }
        observer = DistributedNotificationCenter.default().addObserver(forName: Notification.Name(channel(id: instanceId)), object: nil, queue: .main) { note in
            let text = note.object as? String ?? ""
            MainActor.assumeIsolated { handle(text, app: app) }
        }
        Task {
            await keepBehind()
            log("ready")
        }
        // dev-app.sh passes it so an instance an agent never stopped (an
        // interrupted turn, a thread that ran out of context) doesn't sit
        // behind Mike's windows for good. Its mock runner exits with it.
        if let seconds = argument(after: "--automation-idle-quit").flatMap(Double.init), seconds > 0 {
            Task {
                while true {
                    try? await Task.sleep(for: .seconds(min(60, seconds)))
                    let idle = Date().timeIntervalSince(lastCommandAt)
                    guard idle >= seconds else { continue }
                    AppLog.write("automation", "quitting: no command for \(Int(idle)) s (--automation-idle-quit)")
                    log("quit idle for \(Int(idle)) s")
                    NSApp.terminate(nil)
                    return
                }
            }
        }
    }

    /// The window goes behind everything as soon as it's there, and is sized
    /// from `--window-size WxH`: a scripted run happens while Mike is
    /// working, and `screencapture -l` captures a covered window anyway.
    private static func keepBehind() async {
        for _ in 0..<200 where mainWindow == nil {
            try? await Task.sleep(for: .milliseconds(15))
        }
        guard let window = mainWindow else { return }
        window.orderBack(nil)
        // Sizes set by a script aren't the user's: never saved as the
        // window's frame (a bundle that shares the installed app's id would
        // otherwise reopen Mike's window at them).
        window.setFrameAutosaveName("")
        if let size = argument(after: "--window-size").flatMap(parseSize) {
            window.setContentSize(size)
        }
    }

    static func parseSize(_ text: String) -> NSSize? {
        let parts = text.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return NSSize(width: parts[0], height: parts[1])
    }

    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }
    }

    private static func handle(_ text: String, app: AppModel) {
        guard let data = text.data(using: .utf8),
              let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = command["cmd"] as? String else {
            log("error bad command \(text)")
            AppLog.write("automation", "bad command \(text)")
            return
        }
        let prefix = (command["rid"] as? String).map { "#\($0) " } ?? ""
        lastCommandAt = Date()
        AppLog.write("automation", text)
        Task {
            let result = await run(name, command, app: app)
            AppLog.write("automation", "\(name) \(result.count > 300 ? String(result.prefix(300)) + "…" : result)")
            log("\(prefix)\(name) \(result)")
            if name == "quit", result.hasPrefix("ok") {
                // After the result is written: terminate doesn't return.
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }
    }

    private static func run(_ name: String, _ c: [String: Any], app: AppModel) async -> String {
        let window = mainWindow
        switch name {
        case "select":
            guard let id = thread(c["id"], app) else { return "error no such thread" }
            app.select(id)
            return "ok \(id)"
        case "open":
            // Select and wait until the thread's rows are on screen.
            guard let id = thread(c["id"], app) else { return "error no such thread" }
            if let thread = app.threads[id] {
                app.sidebarMode = thread.isArchived ? .archive : thread.isSnoozed(at: Date()) ? .snoozed : .inbox
            }
            app.select(id)
            let session = app.session(for: id)
            let deadline = Date().addingTimeInterval(number(c["timeout"]) ?? 10)
            while Date() < deadline, session.state != .loaded || app.transcript.session !== session {
                if case .failed(let message) = session.state { return "error couldn't load: \(message)" }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard session.state == .loaded else { return "error timed out loading \(id)" }
            // A beat for the table to lay out and draw.
            try? await Task.sleep(for: .milliseconds(150))
            return "ok \(id) \(session.displayCount) rows"
        case "new":
            app.newThread()
            return "ok"
        case "options":
            return options(c, app: app)
        case "type":
            guard let composer = find(ComposerTextView.self, in: window?.contentView) else { return "error no composer" }
            window?.makeFirstResponder(composer)
            // `replace` takes the text view's whole text: clearing only the
            // draft reaches the view on SwiftUI's next update, after this
            // insert, and the old text would come back.
            let range = c["replace"] as? Bool == true ? NSRange(location: 0, length: (composer.string as NSString).length) : composer.selectedRange()
            composer.insertText(c["text"] as? String ?? "", replacementRange: range)
            return "ok"
        case "return":
            return pressReturn(window)
        case "send":
            // Types `text` (if given) and presses Return, as Mike would.
            if let text = c["text"] as? String {
                guard let composer = find(ComposerTextView.self, in: window?.contentView) else { return "error no composer" }
                window?.makeFirstResponder(composer)
                composer.insertText(text, replacementRange: composer.selectedRange())
            }
            return pressReturn(window)
        case "paste-image":
            guard let path = c["path"] as? String,
                  let composer = find(ComposerTextView.self, in: window?.contentView) else { return "error no composer" }
            let board = pasteboard
            board.clearContents()
            board.writeObjects([URL(fileURLWithPath: path) as NSURL])
            return composer.takeImages(from: board) ? "ok" : "error not an image"
        case "click":
            // A visible, enabled button in the transcript with this title.
            guard let title = c["title"] as? String else { return "error no title" }
            let buttons = all(NSButton.self, in: app.transcript.tableView)
                .filter { $0.title == title && $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor }
            guard let button = buttons.last else { return "error no button \(title)" }
            button.performClick(nil)
            return "ok"
        case "archive":
            app.archive()
            return "ok"
        case "unarchive":
            guard let id = thread(c["id"], app) else { return "error no such thread" }
            app.unarchive(id)
            return "ok"
        case "snooze":
            app.snooze(until: Date().addingTimeInterval(number(c["seconds"]) ?? 3600))
            return "ok"
        case "mode":
            switch c["mode"] as? String {
            case "archive": app.showArchive()
            case "snoozed": app.sidebarMode = .snoozed
            default: app.sidebarMode = .inbox
            }
            return "ok"
        case "expand", "collapse":
            return setExpanded(c, open: name == "expand", app: app)
        case "scroll":
            switch c["to"] as? String {
            case "top":
                app.transcript.scroll(toRow: 0, offset: 0)
                return "ok"
            case "bottom":
                app.transcript.scrollToBottom()
                return "ok"
            default:
                return scroll(toRow: c["row"] as? String, offset: number(c["offset"]) ?? 0, app: app)
            }
        case "scroll-to":
            return scroll(toRow: c["row"] as? String, offset: number(c["offset"]) ?? 0, app: app)
        case "bottom":
            app.transcript.scrollToBottom()
            return "ok"
        case "resize", "size":
            guard let window else { return "error no window" }
            window.setContentSize(NSSize(width: number(c["w"]) ?? 1240, height: number(c["h"]) ?? 820))
            let size = AppDump.contentSize(window)
            return "ok \(Int(size.width))x\(Int(size.height))"
        case "appearance":
            guard let mode = c["mode"] as? String, ["light", "dark", "system"].contains(mode) else { return "error mode is light, dark or system" }
            setAppearance(mode)
            // Layer colours and cached renders are resolved for a look;
            // give AppKit a moment to redraw in the new one.
            try? await Task.sleep(for: .milliseconds(200))
            return "ok \(mode)"
        case "zoom":
            // What ⌘=, ⌘- and ⌘0 do, or a percent from TextZoom.steps.
            let zoom = TextZoom.shared
            switch c["to"] as? String {
            case "in": zoom.zoomIn()
            case "out": zoom.zoomOut()
            case "reset": zoom.reset()
            case nil:
                if let percent = number(c["percent"]).map({ Int($0) }) {
                    guard TextZoom.steps.contains(percent) else { return "error percent is one of \(TextZoom.steps)" }
                    zoom.set(percent)
                }
            default: return "error to is in, out or reset"
            }
            try? await Task.sleep(for: .milliseconds(100))
            return "ok \(zoom.percent)"
        case "hover":
            return hover(c, app: app)
        case "account-ids":
            // For screenshots: accounts are titled by their email address,
            // so show their ids instead. Lasts until the next reconnect.
            app.accounts = app.accounts.map { Account(id: $0.id, provider: $0.provider, title: $0.id, configDir: $0.configDir) }
            return "ok"
        case "status":
            return "ok " + status(app)
        case "streaming":
            // The text of every row still streaming, as the table has it.
            guard let session = app.transcript.session else { return "error no thread open" }
            var out: [String: String] = [:]
            for index in 0..<session.displayCount {
                let row = session.displayRow(index)
                switch row.content {
                case .assistant(let item) where item.isStreaming: out[item.itemId] = item.text
                case .reasoning(let item) where item.isStreaming: out[item.itemId] = item.text
                default: break
                }
            }
            return "ok " + json(out)
        case "sidebar":
            // The inbox's rows by section, as the sidebar lists them.
            let sections = app.sections
            let object: [String: Any] = [
                "needsYou": sections.needsYou.map(\.id), "running": sections.running.map(\.id),
                "inbox": sections.inbox.map(\.id), "snoozed": app.snoozed.count, "archived": app.archivedCount,
                "hover": app.hoverOverride ?? "",
            ]
            return "ok " + json(object)
        case "dump":
            let dump = AppDump.make(app: app, window: window, instance: instanceId)
            let text = c["format"] as? String == "text" ? dump.text : dump.json(pretty: c["out"] != nil)
            guard let out = c["out"] as? String else { return "ok " + dump.json(pretty: false) }
            do {
                try text.write(toFile: out, atomically: true, encoding: .utf8)
            } catch {
                return "error couldn't write \(out): \(error.localizedDescription)"
            }
            return "ok \(out)"
        case "screenshot":
            guard let path = c["path"] as? String, path.hasPrefix("/") else { return "error path must be absolute" }
            guard let window else { return "error no window" }
            // A dev-app.sh instance never runs screencapture itself: its temp
            // bundle has no Screen Recording permission (the capture is
            // refused, and macOS may ask Mike for it). dev-app.sh's shot runs
            // screencapture from the agent's shell first, with this window's
            // id from `window`, and asks for the in-process drawing only
            // when that gives no image.
            let tryScreencapture = instanceId == nil && c["inProcess"] as? Bool != true
            guard let method = await ScreenshotRunner.save(window, to: URL(fileURLWithPath: path), tryScreencapture: tryScreencapture) else { return "error couldn't capture the window" }
            return "ok \(path) (\(method.rawValue))"
        case "window":
            // The window's id for `screencapture -l`, once anything pending
            // has been drawn (as `screenshot` waits).
            guard let window else { return "error no window" }
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(300))
            let size = AppDump.contentSize(window)
            return "ok \(window.windowNumber) \(Int(size.width))x\(Int(size.height))"
        case "focus":
            // The app acts as if it were in front, so a thread that's open
            // gets marked read the way it does when Mike looks at it. It is
            // never activated: a scripted app stays behind his windows.
            let on = c["on"] as? Bool ?? true
            app.actsActive = on
            if on { app.appBecameActive() }
            return "ok \(on ? "on" : "off")"
        case "waitFor":
            return await waitFor(c, app: app)
        case "menu":
            return menu(c, app: app)
        case "debug-info":
            guard let id = displayedRow(c["row"] as? String, app)?.id, let text = app.transcript.debugInfo(rowId: id) else { return "error no such row" }
            return "ok " + json(text)
        case "copy-thread-id":
            // What the ... menu's "Copy thread id" does.
            guard let id = c["id"].flatMap({ thread($0, app) }) ?? app.selection else { return "error no thread" }
            app.copyToPasteboard(id)
            return "ok \(id)"
        case "clipboard":
            // This instance's pasteboard, where its Copy items went.
            return "ok " + json(pasteboard.string(forType: .string) ?? "")
        case "mock":
            return await mock(c, app: app)
        case "quit":
            return "ok"
        default:
            return "error unknown command \(name)"
        }
    }

    // MARK: Commands

    /// What the new-thread composer's folder, account, model and "Ask
    /// before edits" menus set. Anything else is an error rather than a
    /// silent "ok" (a typo like "models" would leave the account's default
    /// model in place), and the answer says what's set now.
    private static func options(_ c: [String: Any], app: AppModel) -> String {
        let known: Set<String> = ["cmd", "rid", "cwd", "account", "model", "ask"]
        let unknown = c.keys.filter { !known.contains($0) }.sorted()
        guard unknown.isEmpty else { return "error options takes cwd, account, model and ask, not \(unknown.joined(separator: ", "))" }
        if let value = c["cwd"] {
            guard let cwd = value as? String, !cwd.isEmpty else { return "error cwd is a folder path" }
            app.newThreadCwd = cwd
        }
        if let value = c["account"] {
            guard let account = value as? String else { return "error account is an account id" }
            if !app.accounts.isEmpty, !app.accounts.contains(where: { $0.id == account }) {
                return "error no account \(account) (the runner has \(app.accounts.map(\.id).joined(separator: ", ")))"
            }
            app.newThreadAccount = account
        }
        if let value = c["model"] {
            // null goes back to the default.
            if value is NSNull { app.newThreadModel = nil } else {
                guard let model = value as? String, !model.isEmpty else { return "error model is a model name, or null for the default" }
                app.newThreadModel = model
            }
        }
        if let value = c["ask"] {
            guard let ask = value as? Bool else { return "error ask is true or false" }
            app.newThreadAsk = ask
        }
        let settings = AppDump.newThreadSettings(app)
        return "ok cwd=\(settings.cwd) account=\(settings.account) model=\(settings.model) ask=\(settings.ask)"
    }

    private static func pressReturn(_ window: NSWindow?) -> String {
        // The same key event the Return key sends.
        guard let composer = find(ComposerTextView.self, in: window?.contentView),
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window?.windowNumber ?? 0, context: nil, characters: "\r",
                                           charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
        else { return "error no composer" }
        composer.keyDown(with: event)
        return "ok"
    }

    static func setAppearance(_ mode: String) {
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// A thread by id or the start of one.
    private static func thread(_ value: Any?, _ app: AppModel) -> String? {
        guard let prefix = value as? String, !prefix.isEmpty else { return nil }
        if app.threads[prefix] != nil { return prefix }
        return app.threads.keys.sorted().first { $0.hasPrefix(prefix) }
    }

    /// A row on screen in the open thread, by id or the start of one.
    private static func displayedRow(_ prefix: String?, _ app: AppModel) -> TranscriptRow? {
        guard let prefix, let session = app.transcript.session else { return nil }
        if let index = session.displayIndex(of: prefix) { return session.displayRow(index) }
        return (0..<session.displayCount).lazy.map { session.displayRow($0) }.first { $0.id.hasPrefix(prefix) }
    }

    private static func scroll(toRow prefix: String?, offset: Double, app: AppModel) -> String {
        guard let row = displayedRow(prefix, app), let index = app.transcript.session?.displayIndex(of: row.id) else { return "error no such row" }
        app.transcript.scroll(toRow: index, offset: offset)
        return "ok \(row.id)"
    }

    /// Opens or closes a row: a group, a tool, a thinking block, a settled
    /// approval, or (with `file`) a file in a changes card. A row folded in
    /// a closed group opens the group first. `all` shows all of a diff.
    private static func setExpanded(_ c: [String: Any], open: Bool, app: AppModel) -> String {
        guard let session = app.transcript.session, let prefix = c["row"] as? String else { return "error no row" }
        var row = displayedRow(prefix, app)
        if row == nil, open, let item = session.model.items.first(where: { $0.id == prefix }) ?? session.model.items.first(where: { $0.id.hasPrefix(prefix) }),
           let group = (0..<session.displayCount).lazy.map({ session.displayRow($0) }).first(where: { candidate in
               if case .group(let group) = candidate.content { return group.memberIds.contains(item.id) }
               return false
           }) {
            session.setModelExpanded(group.id, true)
            row = displayedRow(item.id, app)
        }
        guard let row else { return "error no such row" }
        if case .changes(let card) = row.content {
            let file: ChangedFile?
            if let index = c["file"] as? Int {
                file = card.files.indices.contains(index) ? card.files[index] : nil
            } else if let path = c["file"] as? String {
                file = card.files.first { $0.path == path } ?? card.files.first { $0.path.hasSuffix(path) }
            } else {
                return "error a changes card needs \"file\": a path or an index"
            }
            guard let file else { return "error no such file in \(row.id)" }
            let key = ChangedFiles.expansionKey(turnId: card.turnId, path: file.path)
            session.setModelExpanded(c["all"] as? Bool == true && open ? DiffPreview.allKey(key) : key, open)
            return "ok \(row.id) \(file.path)"
        }
        if case .group = row.content {
            session.setModelExpanded(row.id, open)
            return "ok \(row.id)"
        }
        guard [.tool, .diff, .reasoning, .approval].contains(row.kind) else { return "error \(row.id) doesn't open" }
        if app.transcript.isExpanded(row) != open { app.transcript.toggleExpanded(rowId: row.id) }
        if open, c["all"] as? Bool == true, row.kind == .diff { app.transcript.showAllLines(DiffPreview.allKey(row.id)) }
        return "ok \(row.id)"
    }

    /// `{"id": thread}` shows a sidebar row's hover buttons; `{"row": id}`
    /// draws a transcript row as hovered; neither clears both.
    private static func hover(_ c: [String: Any], app: AppModel) -> String {
        if let prefix = c["row"] as? String {
            guard let row = displayedRow(prefix, app), let index = app.transcript.session?.displayIndex(of: row.id) else { return "error no such row" }
            app.transcript.scroll(toRow: index, offset: 120)
            guard let cell = app.transcript.tableView.view(atColumn: 0, row: index, makeIfNecessary: true) as? RowCellView else { return "error row isn't drawn" }
            _ = hoveredCell?.debugHover(false)
            guard cell.debugHover(true) else { return "error \(row.id) has no hover state" }
            hoveredCell = cell
            return "ok \(row.id)"
        }
        guard let value = c["id"] else {
            app.hoverOverride = nil
            _ = hoveredCell?.debugHover(false)
            hoveredCell = nil
            return "ok"
        }
        guard let id = thread(value, app) else { return "error no such thread" }
        app.hoverOverride = id
        return "ok \(id)"
    }

    /// A row's context menu: `{"row": id}` lists its items, and with
    /// `"click": title` chooses one (copies land on this instance's
    /// pasteboard; read it back with `clipboard`).
    private static func menu(_ c: [String: Any], app: AppModel) -> String {
        guard let row = displayedRow(c["row"] as? String, app), let index = app.transcript.session?.displayIndex(of: row.id),
              let menu = app.transcript.menu(forRow: index) else { return "error no such row" }
        let items = menu.items.filter { !$0.isSeparatorItem }
        guard let title = c["click"] as? String else { return "ok " + json(items.map(\.title)) }
        guard let item = items.first(where: { $0.title == title }), let action = item.action else { return "error no item \(title)" }
        NSApp.sendAction(action, to: item.target, from: item)
        return "ok"
    }

    /// Mock runner helpers (`mock.restartPending`, `mock.restart`, ...),
    /// through the app's own connection. Only `mock.` methods: anything the
    /// real runner answers belongs to `tb`.
    private static func mock(_ c: [String: Any], app: AppModel) async -> String {
        guard let method = c["method"] as? String, !method.isEmpty else { return "error no method" }
        guard let client = app.client else { return "error not connected" }
        let params: JSONValue
        if let raw = c["params"], let data = try? JSONSerialization.data(withJSONObject: raw), let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            params = value
        } else {
            params = .object([:])
        }
        do {
            let result = try await client.call("mock." + method, params, as: JSONValue.self)
            let data = (try? JSONEncoder().encode(result)) ?? Data()
            return "ok " + String(decoding: data, as: UTF8.self)
        } catch {
            return "error \(error.localizedDescription)"
        }
    }

    // MARK: waitFor

    /// Waits until every condition given holds (or, with `"not": true`,
    /// until they don't), checking every 50 ms, for up to `timeout` seconds
    /// (default 10).
    private static func waitFor(_ c: [String: Any], app: AppModel) async -> String {
        let conditions = WaitCondition(c)
        guard !conditions.isEmpty else { return "error nothing to wait for (row, kind, status, text, banner, connection, loaded, ready)" }
        let started = Date()
        let timeout = number(c["timeout"]) ?? 10
        while true {
            if conditions.holds(app) {
                return "ok \(Int(Date().timeIntervalSince(started) * 1000)) ms"
            }
            if Date().timeIntervalSince(started) >= timeout {
                return "error timed out after \(timeout.formatted()) s waiting for \(conditions.description)"
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    struct WaitCondition: CustomStringConvertible {
        var row: String?
        var kind: String?
        var status: String?
        var thread: String?
        var text: String?
        var banner: String?
        var connection: String?
        var loaded: Bool?
        /// Connected, with the first thread list in (what `dev-app.sh
        /// start` waits for).
        var ready: Bool?
        var negate = false

        init(_ c: [String: Any]) {
            row = c["row"] as? String
            kind = c["kind"] as? String
            status = c["status"] as? String
            thread = c["thread"] as? String
            text = c["text"] as? String
            banner = c["banner"] as? String
            connection = c["connection"] as? String
            loaded = c["loaded"] as? Bool
            ready = c["ready"] as? Bool
            negate = c["not"] as? Bool ?? false
        }

        var isEmpty: Bool { [row, kind, status, text, banner, connection].allSatisfy { $0 == nil } && loaded == nil && ready == nil }

        var description: String {
            var parts: [String] = []
            if let row { parts.append("row \(row)") }
            if let kind { parts.append("a \(kind) row") }
            if let status { parts.append("status \(status)" + (thread.map { " on \($0)" } ?? "")) }
            if let text { parts.append("text \"\(text)\"") }
            if let banner { parts.append(banner.isEmpty ? "no banner" : "banner \"\(banner)\"") }
            if let connection { parts.append("connection \(connection)") }
            if let loaded { parts.append(loaded ? "the thread loaded" : "no thread loaded") }
            if let ready { parts.append(ready ? "the thread list" : "no thread list") }
            return (negate ? "not " : "") + parts.joined(separator: " and ")
        }

        @MainActor
        func holds(_ app: AppModel) -> Bool {
            allHold(app) != negate
        }

        @MainActor
        private func allHold(_ app: AppModel) -> Bool {
            let session = app.transcript.session
            let rows = session.map { s in (0..<s.displayCount).map { s.displayRow($0) } } ?? []
            if let row, !rows.contains(where: { $0.id.hasPrefix(row) }) { return false }
            if let kind, !rows.contains(where: { $0.kind.rawValue == kind }) { return false }
            if let status {
                let id = thread.flatMap { prefix in app.threads.keys.sorted().first { $0.hasPrefix(prefix) } } ?? app.selection
                guard let id, app.threads[id]?.status.rawValue == status else { return false }
            }
            if let text {
                // Items too, so text folded in a closed group counts.
                let items = session?.model.items ?? []
                guard (rows + items).contains(where: { RowDebug.text($0).contains(text) }) else { return false }
            }
            if let banner {
                let shown = app.banner?.text ?? ""
                if banner.isEmpty ? !shown.isEmpty : !shown.contains(banner) { return false }
            }
            if let connection, AppDump.connectionName(app.connection) != connection { return false }
            if let loaded {
                let isLoaded = session != nil && session?.state == .loaded && session?.threadId == app.selection
                if isLoaded != loaded { return false }
            }
            if let ready, (app.connection == .connected && app.threadsLoaded) != ready { return false }
            return true
        }
    }

    // MARK: Helpers

    private static func status(_ app: AppModel) -> String {
        var rows: [String] = []
        if let session = app.transcript.session {
            rows = (0..<session.displayCount).map { session.displayRow($0).id }
        }
        let threads = app.threads.values.sorted { $0.lastActivityAt > $1.lastActivityAt }.map {
            ["id": $0.id, "status": $0.status.rawValue, "needsYou": $0.needsYou, "archived": $0.isArchived,
             "snoozed": $0.isSnoozed(at: Date()), "title": $0.title] as [String: Any]
        }
        let object: [String: Any] = [
            "connection": String(describing: app.connection),
            "selection": app.selection ?? "",
            "mode": String(describing: app.sidebarMode),
            "error": app.errorMessage ?? "",
            "banner": app.banner?.text ?? "",
            "drafts": app.drafts.mapValues { ["text": $0.text, "images": $0.images.map(\.path)] },
            "rows": rows,
            "threads": threads,
        ]
        return json(object)
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    }

    /// One line of JSON (a string becomes a quoted, escaped string).
    static func json(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for sub in view.subviews {
            if let found = find(type, in: sub) { return found }
        }
        return nil
    }

    private static func all<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        var out: [T] = []
        if let match = view as? T { out.append(match) }
        for sub in view.subviews { out += all(type, in: sub) }
        return out
    }

    private static func log(_ line: String) {
        guard let logURL, let handle = try? FileHandle(forWritingTo: logURL) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }
}
#endif
