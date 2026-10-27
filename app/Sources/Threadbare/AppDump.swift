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
        /// What the row says is running in the background, if anything.
        var background: String?
        /// The sub-agent rows under it, as the sidebar shows them.
        var subagents: [SubagentInfo] = []
    }

    struct SubagentInfo: Encodable {
        var id: String
        var depth: Int
        var status: String
        var title: String
        var detail: String
        var selected: Bool
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
        /// Where that thread runs, or where a new one will start: what the
        /// composer's chips and menus show.
        var cwd: String
        var account: String
        /// The model, or "default (...)" saying whose default.
        var model: String
        var ask: Bool
        /// The effort level, or "default" for the model's own.
        var effort: String = "default"
    }

    struct Settings {
        var cwd: String
        var account: String
        var model: String
        var ask: Bool
        var effort: String = "default"
    }

    /// What a new thread sent from the composer would get, as the
    /// composer's menus show it (`ThreadSettings` in ComposerControls).
    @MainActor
    static func newThreadSettings(_ app: AppModel) -> Settings {
        let account = app.newThreadAccountId
        return Settings(cwd: app.newThreadCwd ?? app.defaults.cwd, account: account,
                        model: app.newThreadModel ?? defaultModel(app, account: account), ask: app.newThreadAsk,
                        effort: app.newThreadEffort ?? "default")
    }

    /// Whose default a new thread gets, and which model that is when known.
    @MainActor
    static func defaultModel(_ app: AppModel, account: String) -> String {
        if let model = app.defaults.model(for: app.provider(ofAccount: account)) { return "default (the runner's, \(model))" }
        if let model = app.account(account)?.defaultModel { return "default (the account's, \(model))" }
        return "default (the account's)"
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
    /// The sub-agent whose transcript is showing, if one is.
    var subagent: String?
    /// The selected thread's panels and the pane (PanelsView).
    var panels: Panels?
    /// Its action chips (ActionChips).
    var actions: [ActionInfo] = []
    var composer: Composer
    var transcript: Transcript?
    /// The usage popover's content as lines, and whether it's open.
    var usage: Usage? = nil
    /// The project page showing in place of the thread, if one is.
    var project: ProjectInfo? = nil
    /// The librarian's state in words ("Looking at ..."), when the runner
    /// has projects.
    var librarian: String? = nil

    struct ProjectInfo: Encodable {
        var id: String
        var title: String
        var folders: [String]
        var threads: [String]
        var patches: [String]
        var archived: Bool
    }

    struct Usage: Encodable {
        var shown: Bool
        var lines: [String]
    }

    struct ActionInfo: Codable {
        var id: String
        var title: String
        var kind: String
        var running: Bool
    }

    struct Panels: Codable {
        struct Item: Codable {
            var id: String
            var title: String
            var kind: String
            var url: String?
            var note: String?
            var active: Bool
        }
        var shown: Bool
        var width: Int
        var items: [Item]
        /// A file or page open over the section: "file /path" or "page <url>".
        var preview: String?
        /// What the Highlights section has: "3 pinned, 2 files, ..." or why not.
        var highlights: String?
    }

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
            let selectedSub = app.subagentSelection?.threadId == summary.id ? app.subagentSelection?.subagentId : nil
            let subagents = section == nil ? [] : SubagentRows.visible(summary, threadSelected: app.selection == summary.id, selectedSubagent: selectedSub, now: app.now).map {
                SubagentInfo(id: $0.id, depth: $0.depth, status: $0.subagent.status.rawValue, title: SubagentRows.title($0.subagent),
                             detail: SubagentRows.detail($0.subagent), selected: $0.id == selectedSub)
            }
            return Thread(id: summary.id, title: summary.title, status: summary.status.rawValue, needsYou: summary.needsYou,
                          unread: look.unread, hovered: app.hoverOverride == summary.id,
                          background: look.status == .background ? BackgroundWork.short(summary.background) : nil,
                          subagents: subagents)
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
        case .projects:
            // A section per project, then the threads in none.
            let built = app.projectSections
            sections = built.sections.map { Section(name: $0.project.title, threads: $0.threads.map { thread($0) }) }
                + [Section(name: "Not in a project", threads: built.unfiled.map { thread($0) })]
        case .librarian:
            // Looks in the thread shape: the queue's reason, or what a look
            // did, is the status.
            let status = app.librarian
            sections = [
                Section(name: "Next", threads: (status?.queue ?? []).map { job in
                    Thread(id: job.threadId, title: job.threadTitle, status: job.reason.rawValue, needsYou: false, unread: false, hovered: false)
                }),
                Section(name: "Recent", threads: (status?.recent ?? []).map { entry in
                    Thread(id: entry.threadId, title: entry.text, status: entry.outcome.rawValue, needsYou: false, unread: false, hovered: false)
                }),
            ]
        case .scheduled:
            // Schedules in the thread shape: their state is the status.
            sections = [Section(name: "Scheduled", threads: app.schedules.map { schedule in
                Thread(id: schedule.id, title: schedule.title, status: schedule.paused ? "paused" : schedule.isFinished ? "finished" : "active",
                       needsYou: false, unread: false, hovered: app.hoverOverride == schedule.id)
            })]
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
            subagent: app.subagentSelection?.subagentId,
            panels: app.selectedThread.flatMap { panels($0, app: app) },
            actions: app.selectedThread.map { thread in
                thread.actions.map { ActionInfo(id: $0.id, title: $0.title, kind: $0.kind.rawValue, running: app.isRunning(action: $0, in: thread.id)) }
            } ?? [],
            composer: composer(app, key: key),
            transcript: transcript,
            usage: Usage(shown: app.usagePopoverShown, lines: usageLines(app)),
            project: app.openProject.map { project in
                let threads = ProjectSections.threads(in: project.id, from: app.threads.values)
                return ProjectInfo(id: project.id, title: project.title, folders: project.folders, threads: threads.map(\.id),
                                   patches: PatchGroups.patches(of: project.id, in: threads).map(\.patch.id), archived: project.archived)
            },
            librarian: app.librarian.map(LibrarianText.state)
        )
    }

    @MainActor
    private static func panels(_ thread: ThreadSummary, app: AppModel) -> Panels? {
        let section = app.paneSection(for: thread)
        var items = [Panels.Item(id: PaneSection.highlightsId, title: "Highlights", kind: "highlights", url: nil, note: nil, active: section == .highlights)]
        items += thread.panels.map {
            Panels.Item(id: $0.id, title: $0.title, kind: $0.kind.rawValue, url: $0.url, note: $0.note, active: section == .panel($0.id))
        }
        if !thread.patches.isEmpty {
            let summary = thread.patches.map { $0.id + ($0.error != nil ? " (error)" : "") }.joined(separator: ", ")
            items.append(Panels.Item(id: PaneSection.patchesId, title: "Patches", kind: "patches", url: nil, note: summary, active: section == .patches))
        }
        let preview: String? = app.panePreview[thread.id].map { preview in
            switch preview.target {
            case .file(let path): "file \(path)"
            case .page(let url): "page \(url.absoluteString)"
            }
        }
        return Panels(shown: app.showsPanels(for: thread), width: Int(app.panelWidth), items: items, preview: preview,
                      highlights: highlightsLine(app, thread.id))
    }

    @MainActor
    private static func highlightsLine(_ app: AppModel, _ threadId: String) -> String {
        if app.highlightsUnsupported { return "not kept by this runner" }
        guard let fetched = app.highlights[threadId] else { return "not fetched" }
        let sections = HighlightSections.build(fetched)
        if sections.isEmpty { return "empty" }
        let parts = [("pinned", sections.pinned.count), ("files", sections.files.count), ("links", sections.links.count),
                     ("commits", sections.commits.count), ("edited", sections.edited.count)]
        let counts = parts.filter { $0.1 > 0 }.map { "\($0.1) \($0.0)" }
        return ((sections.brief != nil ? ["a brief"] : []) + counts).joined(separator: ", ")
    }

    /// What the usage popover says: each account's room by provider, then
    /// the CLIs (`UsagePopover`).
    @MainActor
    static func usageLines(_ app: AppModel) -> [String] {
        var lines: [String] = []
        for section in UsageSections.build(app.accounts) {
            lines.append("# " + ModelPicker.providerTitle(section.provider))
            for account in section.accounts {
                var line = AccountName.title(account)
                if let plan = account.plan { line += " (\(plan))" }
                if let note = account.note { line += ", " + note }
                if let usage = account.usage {
                    if usage.blocked { line += ", limit reached" }
                    if usage.stale { line += ", stale" }
                    let windows = usage.windows.map { "\($0.title) \(AccountUsageText.percent($0.remainingPercent))" }
                    if !windows.isEmpty { line += ": " + windows.joined(separator: ", ") }
                    if let notice = usage.notice { line += " [\(notice)]" }
                } else {
                    line += ": nothing known"
                }
                lines.append(line)
            }
        }
        if let source = AccountUsageText.sourceLine(app.accounts, now: app.now) { lines.append(source) }
        lines.append("# CLIs")
        if app.clisSupported == false || (app.clisSupported == nil && app.clis.isEmpty) {
            lines.append("needs a newer runner")
        } else {
            for cli in app.clis {
                var line = CliText.statusLine(cli) + " (" + CliText.policyTitle(cli.policy).lowercased() + ")"
                if let button = CliText.updateTitle(cli) { line += " [\(button)]" }
                if let back = CliText.goBackTitle(cli) { line += " [\(back)]" }
                if CliText.isUpdating(cli), let text = CliText.bannerText(cli) { line += ": " + text }
                lines.append(line)
            }
        }
        return lines
    }

    @MainActor
    private static func composer(_ app: AppModel, key: String) -> Composer {
        let settings: Settings
        if let thread = app.selectedThread {
            // A thread's model is its own, or what its last turn ran on,
            // or the account's default.
            let model = thread.model ?? thread.modelInUse.map { "default (the account's, \($0))" } ?? defaultModel(app, account: thread.accountId)
            settings = Settings(cwd: thread.cwd, account: thread.accountId, model: model, ask: thread.permissionMode == .ask,
                                effort: thread.effort ?? thread.effortInUse.map { "default (\($0))" } ?? "default")
        } else {
            settings = newThreadSettings(app)
        }
        return Composer(draft: key, text: app.drafts[key]?.text ?? "", images: app.drafts[key]?.images.count ?? 0,
                        cwd: settings.cwd, account: settings.account, model: settings.model, ask: settings.ask, effort: settings.effort)
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
        // Columns as wide as the longest id: a real runner's ids are 36
        // character UUIDs, and fixed widths pushed every later column out
        // of line.
        let threadWidth = max(12, sidebar.sections.flatMap(\.threads).map(\.id.count).max() ?? 0)
        for section in sidebar.sections where !section.threads.isEmpty {
            lines.append("  \(section.name)")
            for thread in section.threads {
                var flags = [thread.status]
                if thread.unread { flags.append("unread") }
                if thread.hovered { flags.append("hovered") }
                if let background = thread.background { flags.append("bg: " + background) }
                let mark = thread.id == selection?.id ? ">" : " "
                lines.append("  \(mark) \(pad(thread.id, threadWidth)) \(pad(flags.joined(separator: " "), 16)) \(thread.title)")
                for sub in thread.subagents {
                    let indent = String(repeating: "  ", count: sub.depth + 1)
                    lines.append("  \(sub.selected ? ">" : " ") \(indent)sub \(sub.id) [\(sub.status)] \(sub.title): \(sub.detail)")
                }
            }
        }
        lines.append("")
        if let selection {
            lines.append("selection: \(selection.id) \"\(selection.title)\" (\(selection.status))" + (subagent.map { ", showing sub-agent \($0)" } ?? ""))
        } else {
            lines.append("selection: none (new thread)")
        }
        if let panels {
            let items = panels.items.map { item in
                var text = item.title + (item.active ? "*" : "") + " (\(item.kind)"
                // A data: URL (the mock's page) is thousands of characters.
                if let url = item.url { text += " " + (url.count > 80 ? String(url.prefix(77)) + "…" : url) }
                text += ")"
                if let note = item.note { text += " \"\(note)\"" }
                return text
            }
            lines.append("panels (\(panels.shown ? "shown, \(panels.width) wide" : "hidden")): " + items.joined(separator: ", "))
            if let preview = panels.preview { lines.append("pane preview: \(preview)") }
            if let highlights = panels.highlights { lines.append("highlights: \(highlights)") }
        }
        if !actions.isEmpty {
            lines.append("actions: " + actions.map { "\($0.id) \"\($0.title)\" (\($0.kind)\($0.running ? ", running" : ""))" }.joined(separator: ", "))
        }
        if let usage, usage.shown {
            lines.append("usage popover:")
            lines += usage.lines.map { "  " + $0 }
        }
        lines.append("composer (\(composer.draft)): \"\(composer.text)\"" + (composer.images > 0 ? " and \(composer.images) image(s)" : ""))
        lines.append("  \(composer.draft == "new" ? "starts" : "runs") in \(composer.cwd) on \(composer.account), model \(composer.model), "
            + (composer.effort == "default" ? "" : "effort \(composer.effort), ") + (composer.ask ? "asks before edits" : "full access"))
        if let transcript {
            var about = "\(transcript.rows.count) rows, \(transcript.state)"
            if transcript.hasMoreAbove { about += ", more above" }
            about += transcript.atBottom ? ", at the bottom" : ", scrolled up"
            lines.append("")
            lines.append("transcript \(transcript.threadId): \(about)")
            let ids = transcript.rows.map { ($0.inGroup ? "  " : "") + $0.id }
            let rowWidth = max(12, ids.map(\.count).max() ?? 0)
            for (row, id) in zip(transcript.rows, ids) {
                let open = row.expanded.map { $0 ? "open" : "closed" } ?? ""
                lines.append("\(row.onScreen ? ">" : " ") \(pad(id, rowWidth)) \(pad(row.kind, 10)) \(pad(String(row.height), 5)) \(pad(open, 7)) \(row.text)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}
#endif
