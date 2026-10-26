#if DEBUG
import AppKit
import ThreadbareCore

/// Debug builds only, and only when launched with `--automation <log file>`:
/// lets a test script drive the app through its own UI code paths (the
/// composer, the approval card's buttons, archive and snooze) without the
/// window having to be in front. macOS gives an agent's process no
/// accessibility access to this window, and taking focus from whatever
/// Mike is typing into is worse, so the commands arrive as distributed
/// notifications instead. `Tools/drive.sh` posts them.
///
/// Each command is a JSON object in the notification's `object` string;
/// each result is one line in the log file.
@MainActor
enum Automation {
    static let notificationName = Notification.Name("com.mikerosoft.threadbare.automation")
    private static var logURL: URL?
    private static var observer: NSObjectProtocol?

    static func startIfAsked(app: AppModel) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--automation"), index + 1 < arguments.count else { return }
        logURL = URL(fileURLWithPath: arguments[index + 1])
        FileManager.default.createFile(atPath: logURL!.path, contents: nil)
        observer = DistributedNotificationCenter.default().addObserver(forName: notificationName, object: nil, queue: .main) { note in
            let text = note.object as? String ?? ""
            MainActor.assumeIsolated { handle(text, app: app) }
        }
        log("ready")
    }

    private static func handle(_ text: String, app: AppModel) {
        guard let data = text.data(using: .utf8),
              let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = command["cmd"] as? String else {
            log("error bad command \(text)")
            return
        }
        let result = run(name, command, app: app)
        log("\(name) \(result)")
    }

    private static func run(_ name: String, _ c: [String: Any], app: AppModel) -> String {
        let window = NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }
        switch name {
        case "select":
            guard let prefix = c["id"] as? String,
                  let id = app.threads.keys.first(where: { $0.hasPrefix(prefix) }) else { return "error no such thread" }
            app.select(id)
            return "ok \(id)"
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
            window?.makeFirstResponder(composer)
            composer.insertText(c["text"] as? String ?? "", replacementRange: composer.selectedRange())
            return "ok"
        case "return":
            // The same key event the Return key sends.
            guard let composer = find(ComposerTextView.self, in: window?.contentView),
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window?.windowNumber ?? 0, context: nil, characters: "\r",
                                               charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
            else { return "error no composer" }
            composer.keyDown(with: event)
            return "ok"
        case "paste-image":
            // A private pasteboard, so Mike's clipboard is never touched.
            guard let path = c["path"] as? String,
                  let composer = find(ComposerTextView.self, in: window?.contentView) else { return "error no composer" }
            let board = NSPasteboard(name: NSPasteboard.Name("com.mikerosoft.threadbare.automation"))
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
            guard let prefix = c["id"] as? String,
                  let id = app.threads.keys.first(where: { $0.hasPrefix(prefix) }) else { return "error no such thread" }
            app.unarchive(id)
            return "ok"
        case "snooze":
            app.snooze(until: Date().addingTimeInterval(c["seconds"] as? Double ?? 3600))
            return "ok"
        case "mode":
            switch c["mode"] as? String {
            case "archive": app.showArchive()
            case "snoozed": app.sidebarMode = .snoozed
            default: app.sidebarMode = .inbox
            }
            return "ok"
        case "expand":
            guard let row = c["row"] as? String else { return "error no row" }
            app.transcript.toggleExpanded(rowId: row)
            return "ok"
        case "scroll-to":
            // Puts the first row whose id starts with `row` at the top.
            guard let prefix = c["row"] as? String, let session = app.transcript.session,
                  let index = (0..<session.displayCount).first(where: { session.displayRow($0).id.hasPrefix(prefix) })
            else { return "error no such row" }
            app.transcript.scroll(toRow: index, offset: c["offset"] as? Double ?? 0)
            return "ok"
        case "bottom":
            app.transcript.scrollToBottom()
            return "ok"
        case "size":
            window?.setContentSize(NSSize(width: c["w"] as? Double ?? 1240, height: c["h"] as? Double ?? 820))
            return "ok"
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
            let data = (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data()
            return "ok " + String(decoding: data, as: UTF8.self)
        case "sidebar":
            // The inbox's rows by section, as the sidebar lists them.
            let sections = app.sections
            let object: [String: Any] = [
                "needsYou": sections.needsYou.map(\.id), "running": sections.running.map(\.id),
                "inbox": sections.inbox.map(\.id), "snoozed": app.snoozed.count, "archived": app.archivedCount,
                "hover": app.hoverOverride ?? "",
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return "ok " + String(decoding: data, as: UTF8.self)
        case "hover":
            // Shows a row's hover buttons as if the pointer were over it;
            // with no id, clears it.
            guard let prefix = c["id"] as? String else {
                app.hoverOverride = nil
                return "ok"
            }
            guard let id = app.threads.keys.first(where: { $0.hasPrefix(prefix) }) else { return "error no such thread" }
            app.hoverOverride = id
            return "ok \(id)"
        case "quit":
            NSApp.terminate(nil)
            return "ok"
        default:
            return "error unknown command"
        }
    }

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
            "drafts": app.drafts.mapValues { ["text": $0.text, "images": $0.images.map(\.path)] },
            "rows": rows,
            "threads": threads,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
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
