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
            // What the composer's folder, account, model and "Ask before
            // edits" menus set for a new thread.
            if let cwd = c["cwd"] as? String { app.newThreadCwd = cwd }
            if let account = c["account"] as? String { app.newThreadAccount = account }
            if let model = c["model"] as? String { app.newThreadModel = model }
            if let ask = c["ask"] as? Bool { app.newThreadAsk = ask }
            return "ok"
        case "type":
            guard let composer = find(ComposerTextView.self, in: window?.contentView) else { return "error no composer" }
            if c["replace"] as? Bool == true { app.drafts[app.selection ?? "new", default: Draft()].text = "" }
            window?.makeFirstResponder(composer)
            composer.insertText(c["text"] as? String ?? "", replacementRange: composer.selectedRange())
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
            guard let method = await ScreenshotRunner.save(window, to: URL(fileURLWithPath: path)) else { return "error couldn't capture the window" }
            return "ok \(path) (\(method.rawValue))"
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
