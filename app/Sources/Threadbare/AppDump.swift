#if DEBUG
import AppKit
import ThreadbareCore

/// The automation hook's `dump`: what the window shows, as data. The
/// sidebar's rows by section, the open thread's rows (id, kind, height,
/// open or not, the start of their text, which are on screen), the
/// selection, the composer's text and the banner. `Tools/dev-app.sh dump`
/// prints `text`; `dump --json` the JSON.
struct AppDump: Encodable {
    struct Window: Encodable {
        var width: Int
        var height: Int
        var appearance: String
    }

    struct BannerInfo: Encodable {
        var style: String
        var text: String
        var detail: String?
    }

    struct Thread: Encodable {
        var id: String
        var title: String
        var status: String
        var needsYou: Bool
        var unread: Bool
        var hovered: Bool
    }

    struct Section: Encodable {
        var name: String
        var threads: [Thread]
    }

    struct Sidebar: Encodable {
        var mode: String
        var sections: [Section]
        var snoozed: Int
        var archived: Int
    }

    struct Composer: Encodable {
        /// The thread the draft belongs to, or "new".
        var draft: String
        var text: String
        var images: Int
    }

    struct Row: Encodable {
        var id: String
        var kind: String
        var height: Int
        /// Nil for a row that doesn't open (a message, a waiting card).
        var expanded: Bool?
        var inGroup: Bool
        var onScreen: Bool
        var seq: Int
        var turn: String?
        var text: String
    }

    struct Transcript: Encodable {
        var threadId: String
        var state: String
        /// Rows above the first one shown (more pages in as you scroll up).
        var hasMoreAbove: Bool
        var atBottom: Bool
        var rows: [Row]
    }

    var instance: String?
    var connection: String
    var runnerVersion: String
    var banner: BannerInfo?
    var error: String?
    var window: Window?
    var sidebar: Sidebar
    var selection: Thread?
    var composer: Composer
    var transcript: Transcript?

    static func connectionName(_ state: ConnectionState) -> String {
        switch state {
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .runnerDown: return "down"
        case .lost: return "lost"
        case .unauthorized: return "unauthorized"
        }
    }

    @MainActor
    static func make(app: AppModel, window: NSWindow?, instance: String?) -> AppDump {
        let now = Date()
        func thread(_ summary: ThreadSummary, section: InboxSection? = nil) -> Thread {
            let look = ThreadRowLook(summary, section: section)
            return Thread(id: summary.id, title: summary.title, status: summary.status.rawValue, needsYou: summary.needsYou,
                          unread: look.unread, hovered: app.hoverOverride == summary.id)
        }
        let sections: [Section]
        switch app.sidebarMode {
        case .inbox:
            let built = app.sections
            sections = InboxSection.allCases.map { section in
                Section(name: section.title, threads: built[section].map { thread($0, section: section) })
            }
        case .snoozed:
            sections = [Section(name: "Snoozed", threads: app.snoozed.map { thread($0) })]
        case .archive:
            sections = [Section(name: "Archive", threads: app.archived.map { thread($0) })]
        }
        let key = app.selection ?? "new"
        var transcript: Transcript?
        if let session = app.transcript.session {
            let table = app.transcript.tableView
            let visible = table.rows(in: table.visibleRect)
            let rows = (0..<session.displayCount).map { index -> Row in
                let row = session.displayRow(index)
                return Row(id: row.id, kind: row.kind.rawValue, height: Int(table.rect(ofRow: index).height.rounded()),
                           expanded: opens(row) ? app.transcript.isExpanded(row) : nil, inGroup: row.inGroup,
                           onScreen: NSLocationInRange(index, visible), seq: row.seq, turn: row.turnId, text: RowDebug.excerpt(row))
            }
            let state: String
            switch session.state {
            case .idle: state = "idle"
            case .loading: state = "loading"
            case .loaded: state = "loaded"
            case .failed(let message): state = "failed: \(message)"
            }
            transcript = Transcript(threadId: session.threadId, state: state, hasMoreAbove: session.hasMoreAbove,
                                    atBottom: app.transcript.isAtBottom, rows: rows)
        }
        let appearance = window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
        return AppDump(
            instance: instance,
            connection: connectionName(app.connection),
            runnerVersion: app.runnerVersion,
            banner: app.banner.map { BannerInfo(style: $0.style.rawValue, text: $0.text, detail: $0.detail) },
            error: app.errorMessage,
            window: window.map { Window(width: Int(contentSize($0).width), height: Int(contentSize($0).height), appearance: appearance) },
            sidebar: Sidebar(mode: String(describing: app.sidebarMode), sections: sections,
                             snoozed: ThreadSections.snoozed(app.threads.values, now: now).count, archived: app.archivedCount),
            selection: app.selectedThread.map { thread($0) },
            composer: Composer(draft: key, text: app.drafts[key]?.text ?? "", images: app.drafts[key]?.images.count ?? 0),
            transcript: transcript
        )
    }

    /// Rows a click opens: work lines, groups and settled approvals that
    /// have something to show.
    static func opens(_ row: TranscriptRow) -> Bool {
        switch row.content {
        case .group, .tool, .reasoning: return true
        case .approval(let item): return item.resolution != nil && item.opens
        default: return false
        }
    }

    /// The window's content size, as `--window-size` and `resize` set it
    /// (the toolbar included).
    static func contentSize(_ window: NSWindow) -> NSSize {
        window.contentRect(forFrameRect: window.frame).size
    }

    func json(pretty: Bool) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(self)) ?? Data()
        return String(decoding: data, as: UTF8.self) + (pretty ? "\n" : "")
    }

    /// For reading: one thing per line, rows in a table, `>` marking the
    /// rows on screen.
    var text: String {
        var lines: [String] = []
        var head = "\(instance.map { "dev app \($0)" } ?? "app"): \(connection)"
        if !runnerVersion.isEmpty { head += ", runner \(runnerVersion)" }
        if let window { head += ", window \(window.width)x\(window.height) \(window.appearance)" }
        lines.append(head)
        if let banner { lines.append("banner (\(banner.style)): \(banner.text)" + (banner.detail.map { "  [\($0)]" } ?? "")) }
        if let error { lines.append("error banner: \(error)") }
        lines.append("")
        lines.append("sidebar, \(sidebar.mode) (\(sidebar.snoozed) snoozed, \(sidebar.archived) archived):")
        for section in sidebar.sections where !section.threads.isEmpty {
            lines.append("  \(section.name)")
            for thread in section.threads {
                var flags = [thread.status]
                if thread.unread { flags.append("unread") }
                if thread.hovered { flags.append("hovered") }
                let mark = thread.id == selection?.id ? ">" : " "
                lines.append("  \(mark) \(pad(thread.id, 22)) \(pad(flags.joined(separator: " "), 16)) \(thread.title)")
            }
        }
        lines.append("")
        if let selection {
            lines.append("selection: \(selection.id) \"\(selection.title)\" (\(selection.status))")
        } else {
            lines.append("selection: none (new thread)")
        }
        lines.append("composer (\(composer.draft)): \"\(composer.text)\"" + (composer.images > 0 ? " and \(composer.images) image(s)" : ""))
        if let transcript {
            var about = "\(transcript.rows.count) rows, \(transcript.state)"
            if transcript.hasMoreAbove { about += ", more above" }
            about += transcript.atBottom ? ", at the bottom" : ", scrolled up"
            lines.append("")
            lines.append("transcript \(transcript.threadId): \(about)")
            for row in transcript.rows {
                let open = row.expanded.map { $0 ? "open" : "closed" } ?? ""
                let id = (row.inGroup ? "  " : "") + row.id
                lines.append("\(row.onScreen ? ">" : " ") \(pad(id, 24)) \(pad(row.kind, 10)) \(pad(String(row.height), 5)) \(pad(open, 7)) \(row.text)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}
#endif
