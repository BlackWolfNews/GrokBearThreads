import BearDock
#if DEBUG
import AppKit
import BearDock
import ThreadbearCore

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
    static let baseName = "com.mikerosoft.threadbear.automation"
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
        FileHandle.standardError.write(Data(("Threadbear: " + message + "\n").utf8))
        exit(2)
    }

    static func startIfAsked(app: AppModel) {
        guard let path = argument(after: "--automation") else { return }
        instanceId = argument(after: "--automation-id")
        // A dev-app.sh instance stays out of the Dock and the app switcher:
        // Mike Cmd-Tabbing into one by mistake and typing into its composer
        // would start a real turn on a dev runner. (dev-app.sh also marks
        // its bundle LSUIElement, so it's never there even at launch.)
        if instanceId != nil { NSApp.setActivationPolicy(.accessory) }
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
        window.tuckBehind()
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
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 && !($0 is DockPanelWindow) }
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

    /// Opens the Settings window on a tab (`tab`: general, models), kept
    /// behind Mike's windows like the main one, or closes it (`close`).
    /// Says the tab and what the window shows.
    private static func settings(_ c: [String: Any], app: AppModel) async -> String {
        if c["close"] as? Bool == true {
            SettingsWindow.current?.close()
            return "ok closed"
        }
        if let name = c["tab"] as? String {
            guard let tab = SettingsTab(rawValue: name) else {
                return "error tab must be one of \(SettingsTab.allCases.map(\.rawValue).joined(separator: ", "))"
            }
            app.settingsTab = tab
        }
        if SettingsWindow.current?.isVisible != true { app.settingsRequest += 1 }
        for _ in 0..<200 where SettingsWindow.current?.isVisible != true {
            try? await Task.sleep(for: .milliseconds(15))
        }
        guard let window = SettingsWindow.current, window.isVisible else { return "error the Settings window didn't open" }
        window.tuckBehind()
        // Let the tab switch and the window's new height settle.
        try? await Task.sleep(for: .milliseconds(400))
        // {"pair": true}: the Phone & browser tab's pairing code, as a sheet
        // over the window (capture it with `shot --settings --sheet`).
        if c["pair"] as? Bool == true {
            guard app.settingsTab == .devices else { return "error pair needs the devices tab" }
            app.pairRequest += 1
            for _ in 0..<200 where window.attachedSheet == nil {
                try? await Task.sleep(for: .milliseconds(15))
            }
            guard window.attachedSheet != nil else { return "error the pairing code didn't open: \(app.devicesError ?? "no error")" }
            try? await Task.sleep(for: .milliseconds(300))
        }
        let shown: String
        if let settings = app.runnerSettings {
            shown = json([
                "tab": app.settingsTab.rawValue,
                "defaultCwd": settings.defaultCwd,
                "idleMinutes": settings.idleMinutes,
                "maxLiveCLIs": settings.maxLiveCLIs,
                "followMain": settings.followMain,
                // "" is OpenRouter only, or an older runner with no pools.
                "smallJobsPool": settings.models.pool ?? "",
                "keySet": settings.models.openRouterKey.set,
                "dailyBudgetUsd": settings.models.dailyBudgetUsd,
                "privateFolders": settings.models.privateFolders,
                "error": app.settingsError ?? "",
                "pools": app.pools.map { "\($0.id) \"\($0.title)\": " + $0.accountIds.joined(separator: ", ") + ($0.folders.isEmpty ? "" : " [" + $0.folders.joined(separator: ", ") + "]") },
                "poolsError": app.poolsError ?? "",
                // The Phone & browser tab: each paired device as one line,
                // the website, and why nothing can pair when sync is off.
                "devices": app.devices.map { "\($0.kind.rawValue) \"\($0.name)\": \(DeviceText.detail($0))" },
                "devicesSite": app.devicesSite ?? "",
                "devicesReason": app.devicesReason ?? "",
                "devicesError": app.devicesError ?? "",
                "pairingShown": SettingsWindow.current?.attachedSheet != nil,
            ] as [String: Any])
        } else {
            shown = json(["tab": app.settingsTab.rawValue, "unsupported": app.settingsUnsupported] as [String: Any])
        }
        return "ok \(window.windowNumber) " + shown
    }

    private static func run(_ name: String, _ c: [String: Any], app: AppModel) async -> String {
        let window = mainWindow
        switch name {
        case "select":
            let match = thread(c["id"], app)
            guard let id = match.id else { return match.error }
            app.select(id)
            return "ok \(id)"
        case "open":
            // Select and wait until the thread's rows are on screen.
            let match = thread(c["id"], app)
            guard let id = match.id else { return match.error }
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
        case "subagent":
            // Show a sub-agent's transcript, as a click on its sidebar row
            // does: {"thread": id or prefix, "id": the sub-agent's id}.
            let match = thread(c["thread"] ?? app.selection, app)
            guard let threadId = match.id else { return match.error }
            guard let subagentId = c["id"] as? String, !subagentId.isEmpty else { return "error id is the sub-agent's id" }
            app.sidebarMode = .inbox
            app.selectSubagent(threadId: threadId, subagentId: subagentId)
            let session = app.subagentSession(for: SubagentRef(threadId: threadId, subagentId: subagentId))
            let deadline = Date().addingTimeInterval(number(c["timeout"]) ?? 10)
            while Date() < deadline, session.state != .loaded || app.transcript.session !== session {
                if case .failed(let message) = session.state { return session.missing ? "ok \(subagentId) no record" : "error couldn't load: \(message)" }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard session.state == .loaded else { return "error timed out loading \(subagentId)" }
            try? await Task.sleep(for: .milliseconds(150))
            return "ok \(subagentId) \(session.displayCount) rows"
        case "new":
            app.newThread()
            return "ok"
        case "open-panel":
            // A thread in a panel of its own, as the row's Open in New Panel.
            let match = thread(c["id"], app)
            guard let id = match.id else { return match.error }
            app.openThreadInPanel(id)
            try? await Task.sleep(for: .milliseconds(300))
            return "ok \(id)"
        case "dock-move":
            // A panel dragged to a side of the window, as a drag there does:
            // {"panel": "review" (or a full id), "edge": "right"}.
            guard let name = c["panel"] as? String else { return "error panel is a panel id" }
            let panel = app.dock.layout.panels.first { $0 == name || $0 == "threadbear." + name } ?? name
            guard app.dock.layout.contains(panel) else { return "error \(name) isn't in the layout" }
            guard let edge = DockEdge(rawValue: c["edge"] as? String ?? "right") else { return "error edge is left, right, top or bottom" }
            app.dock.layout.move(panel, .window(edge))
            return "ok " + app.dock.layout.summary
        case "mouse-button":
            // A mouse's back or forward button over the window, as the
            // event AppKit gives MouseNavigation's monitor. A made-up event
            // has no window of its own, so it's handed the main one.
            guard let window else { return "error no window" }
            let number: Int64
            switch c["button"] as? String {
            case "back": number = 3
            case "forward": number = 4
            default: return "error button is back or forward"
            }
            guard let cg = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero,
                                   mouseButton: CGMouseButton(rawValue: UInt32(number)) ?? .center) else { return "error no event" }
            guard let event = NSEvent(cgEvent: cg) else { return "error no event" }
            guard MouseNavigation.handle(event, in: window, app: app) else { return "error not taken (not the main window?)" }
            let place = app.place
            return "ok \(place.mode) \(place.threadId ?? "new") back=\(app.canGoBack) forward=\(app.canGoForward)"
        case "options":
            return options(c, app: app)
        case "review":
            return await designReview(c, app: app)
        case "type":
            guard let composer = findComposer(in: window?.contentView) else { return "error no composer" }
            window?.makeFirstResponder(composer)
            // `replace` takes the text view's whole text: clearing only the
            // draft reaches the view on SwiftUI's next update, after this
            // insert, and the old text would come back.
            let range = c["replace"] as? Bool == true ? NSRange(location: 0, length: (composer.string as NSString).length) : composer.selectedRange()
            composer.insertText(c["text"] as? String ?? "", replacementRange: range)
            return "ok"
        case "return":
            return pressReturn(window)
        case "rename":
            // No title: the open thread's title becomes a field, as a click
            // does. With one: saves it, as Return in that field does.
            guard let id = app.selection else { return "error no thread open" }
            if let title = c["title"] as? String {
                app.renamingThread = nil
                app.rename(id, to: title)
            } else {
                app.startRenaming(id)
            }
            return "ok"
        case "send":
            // Types `text` (if given, replacing the draft with `replace` as
            // `type` does) and presses Return, as Mike would.
            if let text = c["text"] as? String {
                guard let composer = findComposer(in: window?.contentView) else { return "error no composer" }
                window?.makeFirstResponder(composer)
                let range = c["replace"] as? Bool == true ? NSRange(location: 0, length: (composer.string as NSString).length) : composer.selectedRange()
                composer.insertText(text, replacementRange: range)
            }
            let fromNew = app.selection == nil
            let known = Set(app.threads.keys)
            let pressed = pressReturn(window)
            guard pressed == "ok" else { return pressed }
            guard fromNew else { return "ok \(app.selection ?? "")" }
            // From the new-thread composer: wait for the thread it made, so
            // its id is there for tb show, tb export or waitFor's thread.
            let wait = number(c["timeout"]) ?? 10
            let deadline = Date().addingTimeInterval(wait)
            while Date() < deadline {
                if let id = app.selection, !known.contains(id) { return "ok \(id)" }
                // A refused send puts the text back in the box with a banner.
                if let message = app.errorMessage, app.drafts["new"].map({ !$0.text.isEmpty }) == true { return "error not sent: \(message)" }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return "error sent, but no new thread showed up within \(Int(wait)) s"
        case "paste-image":
            guard let path = c["path"] as? String, let composer = findComposer(in: window?.contentView) else { return "error no composer" }
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
        case "ask":
            // {"cmd":"ask","row":"ak:6","action":"pick:0:1"} clicks an open
            // asks card's button: "pick:<ask>:<choice>" or "link:<ask>:<link>",
            // 0-based.
            guard let id = c["row"] as? String, let action = c["action"] as? String,
                  case .asks(let card)? = app.transcript.session?.model.row(id: id)?.content else { return "error no asks card" }
            guard card.isOpen else { return "error that card is closed" }
            app.transcript.askAction(card, action: action)
            return "ok"
        case "archive":
            // `id`, else the open thread. These used to ignore `id` and act
            // on whatever was open, which against a dev runner archived (and
            // interrupted) a thread the agent never named.
            let target = target(c, app)
            guard let id = target.id else { return target.error }
            app.archive(id)
            return "ok \(id)"
        case "unarchive":
            let target = target(c, app)
            guard let id = target.id else { return target.error }
            app.unarchive(id)
            return "ok \(id)"
        case "snooze":
            let target = target(c, app)
            guard let id = target.id else { return target.error }
            app.snooze(id, until: Date().addingTimeInterval(number(c["seconds"]) ?? 3600))
            return "ok \(id)"
        case "panel":
            // {"cmd":"panel","id":"convex.dashboard"} shows that section of
            // the selected thread's pane (threadbear.highlights and
            // threadbear.patches are the rail's own); {"cmd":"panel","show":false}
            // hides the pane, {"cmd":"panel","show":true} shows it;
            // {"cmd":"panel"} toggles.
            guard let thread = app.selectedThread else { return "error no thread selected" }
            if let id = c["id"] as? String {
                let ids = [PaneSection.highlightsId] + thread.panels.map(\.id) + (thread.patches.isEmpty ? [] : [PaneSection.patchesId])
                guard ids.contains(id) else { return "error no panel \(id); this thread has \(ids.joined(separator: ", "))" }
                app.choosePanel(id, in: thread.id)
            } else if let show = c["show"] as? Bool {
                app.panelsShown = show
            } else {
                app.togglePanels()
            }
            // A beat for the pane (and a web view) to appear.
            try? await Task.sleep(for: .milliseconds(200))
            return "ok \(app.showsPanels(for: thread) ? "showing \(app.paneSection(for: thread).id)" : "hidden")"
        case "convex":
            // Select through the same model as the panel's deployment menu.
            guard let thread = app.selectedThread,
                  let panel = thread.panels.first(where: { $0.convex != nil }),
                  let configured = panel.convex else { return "error no Convex cloud panel" }
            if let deployment = c["deployment"] as? String {
                switch await app.convexPanelDeployments(threadId: thread.id, panelId: panel.id) {
                case .success(let listed):
                    guard listed.deployments.contains(where: { $0.deployment == deployment }) else { return "error unknown deployment" }
                    WebPanelPool.shared.selectConvex(deployment, for: configured)
                case .failure(let error): return "error \(error.localizedDescription)"
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return "ok \(WebPanelPool.shared.selectedConvex(configured)) browser=\(WebPanelPool.shared.convexBrowserURL(configured)?.absoluteString ?? "none")"
        case "float":
            // {"cmd":"float","id":"threadbear.highlights"} opens a panel in a
            // window of its own, as its menu's Open in New Window does;
            // {"cmd":"float","id":…,"back":true} puts it back in the dock.
            guard let id = c["id"] as? String else { return "error float needs an id" }
            if c["back"] as? Bool == true {
                guard app.dock.layout.isFloating(id) else { return "error \(id) isn't in a window of its own" }
                app.dock.putBack(id)
            } else {
                guard app.dock.layout.canFloat(id) else { return "error \(id) can't go into a window of its own (not in the dock, or the last panel there)" }
                app.dock.openInWindow(id)
            }
            try? await Task.sleep(for: .milliseconds(300))
            return "ok \(app.dock.layout.summary)"
        case "preview":
            // {"cmd":"preview","path":"/abs/file.md"} or {"cmd":"preview",
            // "url":"http://localhost:3000"} opens it in the selected
            // thread's pane, as "Preview here" does; {"cmd":"preview",
            // "close":true} goes back to the section. Over a text file,
            // "edit" true or false is the bar's pencil or Done, "insert"
            // types text at the end of the editor (and waits for the
            // save, unless "wait" is false), and "resolve" ("file" or
            // "mine") is the conflict bar's button.
            guard let thread = app.selectedThread else { return "error no thread selected" }
            if c["close"] as? Bool == true {
                app.closePreview(in: thread.id)
            } else if let editing = c["edit"] as? Bool {
                guard app.panePreview[thread.id]?.fileURL != nil else { return "error no file is open in the pane" }
                app.setPreviewEditing(editing, in: thread.id)
            } else if let text = c["insert"] as? String {
                guard let controller = TextFileController.current, app.panePreview[thread.id]?.editing == true else {
                    return "error nothing is being edited"
                }
                controller.insertAtEnd(text)
                if c["wait"] as? Bool != false { try? await Task.sleep(for: .seconds(1.2)) }
                return "ok editor ends \(String(controller.textView.string.suffix(40)).debugDescription), file ends \(((try? String(contentsOf: controller.url, encoding: .utf8)) ?? "").suffix(40).debugDescription)"
            } else if let side = c["resolve"] as? String {
                guard let controller = TextFileController.current, let fileText = controller.conflict else { return "error no conflict to resolve" }
                if side == "file" { controller.useFile(fileText) } else { controller.keepMine() }
                try? await Task.sleep(for: .milliseconds(300))
                return "ok editor ends \(String(controller.textView.string.suffix(40)).debugDescription), file ends \(((try? String(contentsOf: controller.url, encoding: .utf8)) ?? "").suffix(40).debugDescription)"
            } else if let path = c["path"] as? String {
                app.preview(path: path, in: thread)
            } else if let text = c["url"] as? String, let url = URL(string: text) {
                app.preview(page: url, title: HighlightText.address(url.absoluteString), in: thread)
            } else {
                return "error preview needs path, url or close"
            }
            try? await Task.sleep(for: .milliseconds(300))
            return "ok \(app.panePreview[thread.id].map { "showing \($0.title)" } ?? "no preview")"
        case "action":
            // {"cmd":"action","id":"reseed.reseed-dev-db"} runs that action of
            // the selected thread and waits for a command to finish.
            guard let thread = app.selectedThread else { return "error no thread selected" }
            guard let id = c["id"] as? String, let action = thread.actions.first(where: { $0.id == id }) else {
                return "error no action \(c["id"] ?? ""); this thread has \(thread.actions.map(\.id).joined(separator: ", "))"
            }
            app.runAction(action, in: thread.id)
            let deadline = Date().addingTimeInterval(number(c["timeout"]) ?? 60)
            while Date() < deadline, app.isRunning(action: action, in: thread.id) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if app.isRunning(action: action, in: thread.id) { return "error \(id) still running after the timeout" }
            try? await Task.sleep(for: .milliseconds(150))
            return "ok ran \(id)"
        case "mode":
            switch c["mode"] as? String {
            case "archive": app.showArchive()
            case "snoozed": app.sidebarMode = .snoozed
            case "scheduled": app.showSchedules()
            case "projects":
                guard app.projectsSupported else { return "error this runner has no projects" }
                app.showProjects()
            case "librarian":
                guard app.projectsSupported else { return "error this runner has no projects" }
                app.showLibrarian()
            default: app.sidebarMode = .inbox
            }
            return "ok"
        case "schedule":
            // The schedule editor: {"id": "sc_…"} edits one; without an id
            // it's a new one, from the open thread's composer (its draft
            // too) unless {"from": "none"}, as the Scheduled view's button.
            if let id = c["id"] as? String {
                guard app.schedule(id) != nil else { return "error no schedule \(id)" }
                app.editSchedule(id)
            } else if c["from"] as? String == "none" {
                app.newSchedule(from: nil)
            } else {
                app.newSchedule(from: app.selectedThread, draftKey: app.selection ?? "new")
            }
            try? await Task.sleep(for: .milliseconds(400))
            return "ok"
        case "project":
            // {"cmd":"project","id":"p_…"} opens a project's page in the
            // detail area; {"cmd":"project","close":true} closes it.
            if c["close"] as? Bool == true {
                app.openProjectId = nil
                return "ok"
            }
            guard let id = c["id"] as? String else {
                return "error give an id: \(app.projects.map(\.id).joined(separator: ", "))"
            }
            guard app.project(id) != nil else { return "error no project \(id); there are \(app.projects.map(\.id).joined(separator: ", "))" }
            app.openProjectPage(id)
            try? await Task.sleep(for: .milliseconds(200))
            return "ok"
        case "close-schedule":
            app.scheduleEditor = nil
            return "ok"
        case "expand", "collapse":
            if let raw = c["section"] as? String {
                // An inbox heading, as clicking it does.
                guard let section = InboxSection(rawValue: raw) else {
                    return "error section must be one of \(InboxSection.allCases.map(\.rawValue).joined(separator: ", "))"
                }
                if name == "expand" { app.collapsedSections.remove(section) } else { app.collapsedSections.insert(section) }
                return "ok"
            }
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
        case "swipe":
            return await swipe(c, app: app)
        case "decide":
            return decide(c, app: app)
        case "hints":
            ShortcutHints.shared.setShowing(c["on"] as? Bool ?? true)
            try? await Task.sleep(for: .milliseconds(100))
            return "ok \(ShortcutHints.shared.showing)"
        case "tour":
            // {"do": "start"|"next"|"back"|"end"}, or nothing to just read
            // where it's at. Says the step, its title and what it lights up.
            let tour = Tour.shared
            switch c["do"] as? String {
            case "start": tour.start()
            case "next": tour.next()
            case "back": tour.back()
            case "end": tour.finish()
            case nil: break
            default: return "error do is start, next, back or end"
            }
            // The card and spotlight's move to settle before a shot.
            try? await Task.sleep(for: .milliseconds(400))
            guard let step = tour.step, let current = tour.current else { return "ok off" }
            let lit = tour.frame(for: current).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "nothing"
            return "ok \(step + 1)/\(tour.shown.count) \(current.title) lit: \(lit)"
        case "chip":
            return chip(c, app: app)
        case "select-text":
            return select(c, app: app)
        case "account-ids":
            // For screenshots: accounts are titled by their email address,
            // so show their ids instead. Lasts until the next reconnect.
            app.accounts = app.accounts.map {
                Account(id: $0.id, provider: $0.provider, title: $0.id, configDir: $0.configDir, defaultModel: $0.defaultModel, models: $0.models)
            }
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
            if let refused = refusesToWrite(out) { return refused }
            do {
                try text.write(toFile: out, atomically: true, encoding: .utf8)
            } catch {
                return "error couldn't write \(out): \(error.localizedDescription)"
            }
            return "ok \(out)"
        case "screenshot":
            guard let path = c["path"] as? String, path.hasPrefix("/") else { return "error path must be absolute" }
            if let refused = refusesToWrite(path) { return refused }
            guard var window else { return "error no window" }
            // {"review": id}: its own window when popped out; in the
            // Review panel it's in the main window already.
            if let id = c["review"] as? String {
                if let review = app.reviewWindows.values.first(where: { $0.session.review.id == id })?.window {
                    window = review
                } else if app.reviewPanel?.review.id != id {
                    return "error that review isn't open"
                }
            }
            // The Settings window first, so {"settings": true, "sheet": true}
            // is the sheet over it (the pairing code).
            if c["settings"] as? Bool == true {
                guard let settings = SettingsWindow.current, settings.isVisible else { return "error the Settings window isn't open" }
                window = settings
            }
            if c["sheet"] as? Bool == true {
                guard let sheet = window.attachedSheet else { return "error no sheet" }
                window = sheet
            }
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
            guard var window else { return "error no window" }
            // {"review": id}: its own window when popped out; in the
            // Review panel it's in the main window already.
            if let id = c["review"] as? String {
                if let review = app.reviewWindows.values.first(where: { $0.session.review.id == id })?.window {
                    window = review
                } else if app.reviewPanel?.review.id != id {
                    return "error that review isn't open"
                }
            }
            // {"settings": true}: the Settings window (open it with `settings`).
            if c["settings"] as? Bool == true {
                guard let settings = SettingsWindow.current, settings.isVisible else { return "error the Settings window isn't open" }
                window = settings
            }
            // {"sheet": true}: the sheet over it (the schedule editor, or the
            // pairing code over Settings), a window of its own that a
            // capture of the one under it leaves out.
            if c["sheet"] as? Bool == true {
                guard let sheet = window.attachedSheet else { return "error no sheet" }
                window = sheet
            }
            // {"panel": id}: a panel's window of its own (see `float`).
            if let id = c["panel"] as? String {
                guard let panel = NSApp.windows.first(where: { ($0 as? DockPanelWindow)?.panel == id && $0.isVisible }) else { return "error \(id) has no window of its own" }
                window = panel
            }
            window.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(300))
            let size = AppDump.contentSize(window)
            return "ok \(window.windowNumber) \(Int(size.width))x\(Int(size.height))"
        case "settings":
            return await settings(c, app: app)
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
        case "composer-menu":
            return composerMenu(c, app: app)
        case "usage":
            // The Usage panel: {"show": true} opens it ({"show": false}
            // closes it), {"click": "Update"} presses one of the Updates
            // panel's buttons for a CLI ({"provider": "codex"}), and
            // with neither it lists what it says.
            return usage(c, app: app)
        case "updates":
            // The Updates panel: {"show": true} opens it ({"show": false}
            // closes it). {"rightClick": true} right-clicks the icon, which
            // opens or closes the app's update popover ({"popover": false}
            // closes it). {"preview": "staged" | "building" | "failed" |
            // "none"} makes up the app's update first, for screenshots.
            // With nothing, whether the icon has its dot, its tooltip,
            // whether the popover is up and what it says, and what the
            // panel says about the app and runner.
            if let state = c["preview"] as? String {
                guard ["staged", "building", "failed", "none"].contains(state) else { return "error preview is staged, building, failed or none" }
                AppUpdater.shared.previewUpdate(state)
            }
            if c["rightClick"] as? Bool == true {
                // A made-up right-click through the app's own event
                // dispatch, so it's the icon's monitor that takes it.
                guard let window,
                      let icon = all(RightClickView.self, in: window.contentView).first(where: { $0.identifier?.rawValue == "updates" })
                else { return "error no updates icon" }
                let center = icon.convert(NSPoint(x: icon.bounds.midX, y: icon.bounds.midY), to: nil)
                guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                else { return "error no event" }
                NSApp.sendEvent(event)
                try? await Task.sleep(for: .milliseconds(500))
                return "ok popover \(app.updatePopoverShown ? "shown" : "closed")"
            }
            if let popover = c["popover"] as? Bool {
                app.updatePopoverShown = popover
                try? await Task.sleep(for: .milliseconds(300))
                return "ok popover \(app.updatePopoverShown ? "shown" : "closed")"
            }
            if let show = c["show"] as? Bool {
                app.updatesShown = show
                guard show else { return "ok closed" }
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                return app.updatesShown ? "ok shown" : "error the panel didn't open"
            }
            let side = UpdatesPanel.appSide(AppUpdater.shared)
            let shown = UpdatesText.shown(app: side, runner: app.runnerUpdates)
            let tip = UpdatesText.iconTooltip(app: side, runner: app.runnerUpdates, clis: app.clis)
            let popover = "popover: " + (app.updatePopoverShown ? "shown, " : "closed, ") + UpdatesText.popoverLine(side)
            return "ok " + json(["shown: \(shown)", "tip: " + tip.replacingOccurrences(of: "\n", with: " / "), popover, UpdatesText.appLine(side)] + UpdatesText.runnerLines(app.runnerUpdates))
        case "restart-countdown":
            // The update's countdown card: {"show": 5} shows it at that
            // count (with no build behind it), {"show": 0} hides it.
            let seconds = (c["show"] as? Int) ?? 0
            AppUpdater.shared.previewCountdown(seconds > 0 ? seconds : nil)
            return "ok"
        case "debug-info":
            // What the row menu's "Copy debug info" copies, copied the same
            // way (to this instance's pasteboard).
            guard let id = displayedRow(c["row"] as? String, app)?.id, let text = app.transcript.debugInfo(rowId: id) else { return "error no such row" }
            app.copyToPasteboard(text)
            return "ok " + json(text)
        case "copy-thread-id":
            // What the ... menu's "Copy thread id" does.
            let target = target(c, app)
            guard let id = target.id else { return target.error }
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
        let known: Set<String> = ["cmd", "rid", "cwd", "account", "model", "effort", "ask", "pool", "provider"]
        let unknown = c.keys.filter { !known.contains($0) }.sorted()
        guard unknown.isEmpty else { return "error options takes cwd, account, pool, provider, model, effort and ask, not \(unknown.joined(separator: ", "))" }
        // A pool picked for the draft (null: back to the folder's or the
        // last one), and which of a mixed pool's providers. Both unpin it.
        if let value = c["pool"] {
            if value is NSNull { app.newThreadPool = nil } else {
                guard let pool = value as? String, app.pool(pool) != nil else {
                    return "error pool is one of \(app.pools.map(\.id).joined(separator: ", ")), or null"
                }
                app.newThreadPool = pool
            }
            app.newThreadAccount = nil
        }
        if let value = c["provider"] {
            if value is NSNull { app.newThreadProvider = nil } else {
                guard let provider = value as? String else { return "error provider is claude or codex, or null" }
                app.newThreadProvider = provider
            }
        }
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
        if let value = c["effort"] {
            // null goes back to the model's own level.
            if value is NSNull { app.newThreadEffort = nil } else {
                guard let effort = value as? String, ComposerChips.codexEffortLevels.contains(effort)
                else { return "error effort is one of \(ComposerChips.codexEffortLevels.joined(separator: ", ")), or null for the default" }
                app.newThreadEffort = effort
            }
        }
        if let value = c["ask"] {
            guard let ask = value as? Bool else { return "error ask is true or false" }
            app.newThreadAsk = ask
        }
        let settings = AppDump.newThreadSettings(app)
        return "ok cwd=\(settings.cwd) account=\(settings.account)" + (settings.pool.map { " pool=\($0)" } ?? "")
            + " model=\(settings.model) effort=\(settings.effort) ask=\(settings.ask)"
    }

    private static func pressReturn(_ window: NSWindow?) -> String {
        // The same key event the Return key sends.
        guard let composer = findComposer(in: window?.contentView),
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

    /// The thread `value` names, by id or the start of one, or why not as
    /// an error result. A start that matches several is an error, as in tb
    /// and the threadbear tools: it used to take the first in sorted order.
    static func thread(_ value: Any?, in threads: some Collection<String>) -> (id: String?, error: String) {
        guard let prefix = value as? String, !prefix.isEmpty else { return (nil, "error id is a thread id or the start of one") }
        if threads.contains(prefix) { return (prefix, "") }
        let hits = threads.filter { $0.hasPrefix(prefix) }
        if hits.count == 1 { return (hits.first, "") }
        return (nil, hits.isEmpty ? "error no such thread \(prefix)" : "error \(prefix) matches \(hits.count) threads")
    }

    private static func thread(_ value: Any?, _ app: AppModel) -> (id: String?, error: String) {
        thread(value, in: app.threads.keys)
    }

    /// The thread a command acts on: `id` when it's given (an error if it
    /// doesn't name exactly one), else the open one.
    static func target(_ c: [String: Any], threads: some Collection<String>, selection: String?) -> (id: String?, error: String) {
        if let value = c["id"], !(value is NSNull) { return thread(value, in: threads) }
        guard let selection else { return (nil, "error no thread: pass id, or open one first") }
        return (selection, "")
    }

    private static func target(_ c: [String: Any], _ app: AppModel) -> (id: String?, error: String) {
        target(c, threads: app.threads.keys, selection: app.selection)
    }

    /// The temp bundle has no privacy permissions, so writing into Desktop,
    /// Documents or Downloads would put a macOS access prompt in front of
    /// Mike's work (again for every instance). dev-app.sh's shot and dump
    /// have the app write into the instance's folder and move the file from
    /// the agent's shell.
    static func refusesToWrite(_ path: String, home: String = NSHomeDirectory()) -> String? {
        let full = URL(fileURLWithPath: path).standardizedFileURL.path
        for folder in ["Desktop", "Documents", "Downloads"] {
            let protected = URL(fileURLWithPath: home).appendingPathComponent(folder).standardizedFileURL.path
            if full == protected || full.hasPrefix(protected + "/") {
                return "error won't write into ~/\(folder): macOS would ask Mike to let this dev app in. Use a temp folder (dev-app.sh shot and dump move the file for you)"
            }
        }
        return nil
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
        // A schedule's row in the Scheduled view, by its id.
        if let id = value as? String, app.schedule(id) != nil {
            app.hoverOverride = id
            return "ok \(id)"
        }
        let match = thread(value, app)
        guard let id = match.id else { return match.error }
        app.hoverOverride = id
        return "ok \(id)"
    }

    /// Two fingers across a sidebar row (`{"id": thread, "dx": -150}`, left
    /// negative): synthetic trackpad events posted to the app, so they go
    /// through the same monitor as a real swipe. `"lift": false` leaves the
    /// fingers down, for a shot of the row part way along; a later swipe
    /// with `"lift": true` (and any `dx`, 0 included) carries on and lets go.
    /// Says where the row ended up and whether it's past the line.
    private static func swipe(_ c: [String: Any], app: AppModel) async -> String {
        let match = Self.thread(c["id"], app)
        guard let id = match.id else { return match.error }
        app.hoverOverride = id
        try? await Task.sleep(for: .milliseconds(100))
        guard let row = RowSwipeController.listening else { return "error \(id) has no swipe here (is its row drawn?)" }
        let dx = number(c["dx"]) ?? 0
        let steps = max(1, Int(number(c["steps"]) ?? 8))
        let fresh = row.swipe.phase == .idle
        if fresh { post(RowSwipeEvents.event(dx: 0, phase: .began)) }
        for _ in 0..<steps {
            post(RowSwipeEvents.event(dx: dx / Double(steps), phase: .changed))
            try? await Task.sleep(for: .milliseconds(16))
        }
        let along = "offset \(Int(row.offset)) armed \(row.swipe.armed)"
        guard c["lift"] as? Bool ?? true else { return "ok \(along)" }
        post(RowSwipeEvents.event(dx: 0, phase: .ended))
        try? await Task.sleep(for: .milliseconds(500))
        app.hoverOverride = nil
        return "ok \(along), let go: \(app.threads[id]?.isArchived == true ? "archived" : "not archived")"
    }

    private static func post(_ event: NSEvent?) {
        guard let event else { return }
        NSApp.postEvent(event, atStart: false)
    }

    /// Selects `words` in a message row's text and shows the selection bar
    /// (`{"row": id, "words": "…"}`, which says the bar's window number);
    /// with `"action": "explain" | "quote" | "copy"`, clicks that instead.
    private static func select(_ c: [String: Any], app: AppModel) -> String {
        guard let prefix = c["row"] as? String, let words = c["words"] as? String else { return "error row and words are required" }
        guard let row = displayedRow(prefix, app), let index = app.transcript.session?.displayIndex(of: row.id) else { return "error no such row" }
        app.transcript.scroll(toRow: index, offset: 120)
        guard let cell = app.transcript.tableView.view(atColumn: 0, row: index, makeIfNecessary: true) as? TextRowCell else {
            return "error \(row.id) isn't a text row"
        }
        let action: SelectionBarWindow.Action?
        switch c["action"] as? String {
        case nil: action = nil
        case "explain": action = .explain
        case "quote": action = .quote
        case "copy": action = .copy
        case let other?: return "error unknown action \(other)"
        }
        guard cell.textView.selectionMessage != nil else { return "error \(row.id) isn't a message" }
        guard cell.textView.debugSelect(words, then: action) else { return "error \(words) isn't in \(row.id)" }
        if action != nil { return "ok" }
        return cell.textView.debugSelectionBarWindow.map { "ok window \($0)" } ?? "error the bar didn't show"
    }

    /// Thread chips in a transcript row's text: `{"row": id}` lists them
    /// (word, then the thread it opens); with `"word"`, `"show": true`
    /// shows that chip's hover card (and says its window number, for
    /// `screencapture -l`), `false` closes it, and `"click": true` clicks it.
    private static func chip(_ c: [String: Any], app: AppModel) -> String {
        guard let prefix = c["row"] as? String else { return "error row is required" }
        guard let row = displayedRow(prefix, app), let index = app.transcript.session?.displayIndex(of: row.id) else { return "error no such row" }
        app.transcript.scroll(toRow: index, offset: 120)
        guard let cell = app.transcript.tableView.view(atColumn: 0, row: index, makeIfNecessary: true) as? TextRowCell else {
            return "error \(row.id) isn't a text row"
        }
        let chips = cell.textView.debugChips()
        guard let word = c["word"] as? String else {
            return chips.isEmpty ? "ok none" : "ok " + chips.map { "\($0.word)=\($0.threadId)" }.joined(separator: " ")
        }
        guard chips.contains(where: { $0.word == word }) else { return "error \(word) isn't a chip in \(row.id)" }
        if c["click"] as? Bool == true {
            cell.textView.debugClickChip(word)
            return "ok opened \(app.selection ?? "nothing")"
        }
        if c["show"] as? Bool == false {
            cell.textView.closeChipCard()
            return "ok"
        }
        guard let window = cell.textView.debugShowChip(word) else { return "error the card didn't show" }
        return "ok window \(window)"
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

    /// The composer's model picker, or its account, permission or folder
    /// menu, as the open thread (or a new one) would get it, a JSON list
    /// of lines: `[x]` for the ticked one, `*` for the default, the
    /// subtitle after a dash, submenus and older models indented, `#` on
    /// a section (a provider column, Effort). `click` picks an item by
    /// title, as a click on it would.
    private static func composerMenu(_ c: [String: Any], app: AppModel) -> String {
        let settings = ThreadSettings(app: app, thread: app.selectedThread)
        let menu: NSMenu
        // Opens a chip's popover, and says its window number so a
        // screencapture -l can take just it.
        func show(_ bump: () -> Void) -> String {
            bump()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let popover = NSApp.windows.first { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }
            return popover.map { "ok window \($0.windowNumber)" } ?? "error the picker didn't open"
        }
        switch c["menu"] as? String ?? "model" {
        case "model":
            if let title = c["click"] as? String {
                // With pools, `pool` says which pool's column to pick from.
                return settings.pickerClick(title, column: c["pool"] as? String) ? "ok" : "error no item \(title)"
            }
            if c["show"] as? Bool == true { return show { app.modelPickerRequest += 1 } }
            return "ok " + json(settings.pickerLines())
        case "account":
            // An account by its email (as the picker shows it) or its id.
            if let title = c["click"] as? String {
                guard let item = settings.accountSections.flatMap(\.items).first(where: { $0.title == title || $0.id == title }) else { return "error no item \(title)" }
                settings.setAccount(item.id)
                return "ok"
            }
            if c["show"] as? Bool == true { return show { app.accountPickerRequest += 1 } }
            return "ok " + json(settings.accountLines())
        case "pin":
            // Pinning, which the picker no longer offers (28 Oct): a login
            // by its email or id pins the thread (or the draft) to it;
            // "Unpin" unpins.
            guard settings.usesPools else { return "error the runner has no pools; use menu account" }
            if let title = c["click"] as? String {
                if title == "Unpin" { return settings.pickerClick("Unpin") ? "ok" : "error it isn't pinned" }
                guard let item = settings.pinSections.flatMap(\.items).first(where: { $0.title == title || $0.id == title }) else { return "error no item \(title)" }
                settings.pin(item.id)
                return "ok"
            }
            return "ok " + json(AccountMenu.lines(settings.pinSections, footer: settings.pinnedLine))
        case "permission": menu = settings.permissionMenu()
        case "folder": menu = settings.folderMenu()
        default: return "error menu is model, account, pin, permission or folder"
        }
        if let title = c["click"] as? String {
            guard let item = allItems(menu).first(where: { $0.title == title }), let action = item.action else { return "error no item \(title)" }
            NSApp.sendAction(action, to: item.target, from: item)
            return "ok"
        }
        return "ok " + json(describe(menu, indent: ""))
    }

    private static func usage(_ c: [String: Any], app: AppModel) -> String {
        if let show = c["show"] as? Bool {
            app.usageShown = show
            guard show else { return "ok closed" }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            return app.usageShown ? "ok shown" : "error the panel didn't open"
        }
        if let title = c["click"] as? String {
            if title == "Check now" { app.checkClis(); return "ok" }
            guard let provider = c["provider"] as? String, let cli = app.clis.first(where: { $0.provider == provider }) else { return "error provider is claude or codex" }
            if title == CliText.updateTitle(cli) {
                app.updateCli(provider, force: cli.status == "held")
            } else if title == CliText.goBackTitle(cli), let previous = cli.previousVersion {
                app.updateCli(provider, version: previous)
            } else if let policy = CliText.policies.first(where: { CliText.policyTitle($0) == title }) {
                app.setCliPolicy(provider, policy)
            } else {
                return "error no button \(title) for \(provider)"
            }
            return "ok"
        }
        return "ok " + json(AppDump.usageLines(app))
    }

    private static func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
    }

    private static func describe(_ menu: NSMenu, indent: String) -> [String] {
        menu.items.flatMap { item -> [String] in
            if item.isSeparatorItem { return [indent + "---"] }
            if item.isSectionHeader { return [indent + "# " + item.title] }
            var line = indent + (item.state == .on ? "[x] " : "[ ] ") + item.title
            if item.image?.accessibilityDescription == "Default" { line += " *" }
            if let subtitle = item.subtitle, !subtitle.isEmpty { line += " - " + subtitle }
            return [line] + (item.submenu.map { describe($0, indent: indent + "    ") } ?? [])
        }
    }

    /// Mock runner helpers (`mock.restartPending`, `mock.restart`, ...),
    /// through the app's own connection. Only `mock.` methods: anything the
    /// real runner answers belongs to `tb`.
    private static func mock(_ c: [String: Any], app: AppModel) async -> String {
        guard let method = c["method"] as? String, !method.isEmpty else { return "error no method" }
        guard let params = mockParams(c["params"]) else { return "error params is an object" }
        guard let client = app.client else { return "error not connected" }
        do {
            let result = try await client.call("mock." + method, params, as: JSONValue.self)
            let data = (try? JSONEncoder().encode(result)) ?? Data()
            return "ok " + String(decoding: data, as: UTF8.self)
        } catch {
            return "error \(error.localizedDescription)"
        }
    }

    /// `params` for a mock call: an object, or nothing (null counts as
    /// nothing). Anything else is refused here: JSONSerialization raises an
    /// Objective-C exception for a top level that isn't an array or an
    /// object, which `try?` can't catch, and that crashed the app.
    static func mockParams(_ raw: Any?) -> JSONValue? {
        guard let raw, !(raw is NSNull) else { return .object([:]) }
        guard raw is [String: Any], JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return value
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

    /// The composer's text view, not a decision card's box that shares
    /// its class.
    private static func findComposer(in view: NSView?) -> ComposerTextView? {
        guard let view else { return nil }
        if let match = view as? ComposerTextView { return match }
        for sub in view.subviews {
            if let found = findComposer(in: sub) { return found }
        }
        return nil
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for sub in view.subviews {
            if let found = find(type, in: sub) { return found }
        }
        return nil
    }

    /// Drives the same session as the comparison controls. Replies still
    /// go through the dev/mock runner, never the installed runner.
    private static func designReview(_ c: [String: Any], app: AppModel) async -> String {
        guard let threadId = app.selection else { return "error open a thread first" }
        let snapshot = app.session(for: threadId).model.items.compactMap { row -> DesignReview? in
            if case .review(let review) = row.content { return review }
            return nil
        }.first { c["id"] as? String == nil || $0.id == c["id"] as? String }
        guard let snapshot else { return "error no review in this thread" }
        let key = threadId + "/" + snapshot.id
        if c["close"] as? Bool == true {
            app.reviewWindows[key]?.close()
            if app.reviewPanel?.review.id == snapshot.id { app.closeReviewPanel() }
            return "ok closed"
        }
        app.openReview(threadId: threadId, review: snapshot)
        // {"popOut": true}: into its own window, as the panel's button does.
        if c["popOut"] as? Bool == true { app.popOutReview() }
        let controller = app.reviewWindows[key]
        guard let session = controller?.session ?? app.reviewPanel else { return "error couldn't open review" }
        await session.refresh()
        if let mode = c["mode"] as? String, let view = ReviewMode(rawValue: mode) { session.mode = view }
        if let actual = c["actual"] as? Bool { session.actualSize = actual }
        if let left = c["left"] as? Int { session.show(left, slot: 0) }
        if let right = c["right"] as? Int { session.show(right, slot: 1) }
        if let notes = c["notes"] as? [String: String] { for (id, text) in notes { session.setNote(text, for: id) } }
        if let pick = c["pick"] as? String { session.pick(pick) }
        if c["save"] as? Bool == true { await session.saveNow() }
        if c["submit"] as? Bool == true { await session.submit() }
        if c["cancel"] as? Bool == true { await session.cancelReview() }
        controller?.window?.tuckBehind()
        try? await Task.sleep(for: .milliseconds(250))
        return "ok " + json([
            "id": session.review.id, "window": controller?.window?.windowNumber ?? 0, "panel": controller == nil,
            "status": session.review.status, "revision": session.review.revision,
            "mode": session.mode.rawValue, "actual": session.actualSize,
            "pickedId": session.draft.pickedId ?? "", "notes": session.draft.notes,
            "dirty": session.dirty, "error": session.error ?? "",
        ] as [String: Any])
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

extension Automation {
    /// The open thread's card of asks, picked as its buttons pick:
    /// `pick` is "ask:option", both 1-based ("2:1" picks the second ask's
    /// first choice, or unpicks it if it was), `clear` drops every pick,
    /// `send` sends the composer with them. Says where it is after, as
    /// `dump` does.
    @MainActor
    static func decide(_ c: [String: Any], app: AppModel) -> String {
        guard let thread = app.selectedThread else { return "error no thread open" }
        guard Decisions.isOpen(thread) else { return "error the open thread has no card of asks to answer" }
        if c["clear"] as? Bool == true {
            for (ask, option) in app.picks(for: thread) { app.pickAnswer(thread: thread, ask: ask, option: option) }
        }
        if let pick = c["pick"] as? String {
            let parts = pick.split(separator: ":").compactMap { Int($0) }
            // Choice 0 is "Something else".
            guard parts.count == 2, thread.asks.indices.contains(parts[0] - 1),
                  parts[1] == 0 || Decisions.choices(for: thread.asks[parts[0] - 1]).indices.contains(parts[1] - 1) else { return "error no choice \(pick)" }
            app.pickAnswer(thread: thread, ask: parts[0] - 1, option: parts[1] == 0 ? Decisions.ownAnswer : parts[1] - 1)
        }
        if c["send"] as? Bool == true {
            app.send(threadId: thread.id)
            return "ok sent"
        }
        return "ok " + (AppDump.decisions(thread, app: app) ?? []).joined(separator: "\n")
    }
}
#endif
