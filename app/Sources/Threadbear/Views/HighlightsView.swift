import AppKit
import Quartz
import SwiftUI
import ThreadbearCore

/// The pane's Highlights section: what the thread has made, shared and
/// pinned, so it doesn't scroll away with the transcript. The librarian's
/// line on where it's up to, the links of the projects it's in (its live
/// site, admin page), its schedules and sub-agents, then pins, files, links
/// and commits, each under a grey heading like the sidebar's, and left out
/// when empty.
struct HighlightsView: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary
    @State private var editedOpen = false
    /// "Show all" on Links and Changes, for the thread on show.
    @State private var allLinks = false
    @State private var allCommits = false
    @State private var allSubagents = false

    var body: some View {
        if app.highlightsUnsupported {
            PaneNote(text: "This runner doesn't keep highlights yet.")
        } else if let fetched = app.highlights[thread.id] {
            let sections = HighlightSections.build(fetched)
            let projects = ProjectLinkGroups.build(thread: thread, project: app.project)
            if sections.isEmpty && openAsks == nil && projects.isEmpty && toolPanels.isEmpty && schedules.isEmpty && thread.subagents.isEmpty {
                PaneNote(text: "Nothing here yet. Files, links and commits from this thread show up here as it works.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        content(sections, projects: projects)
                    }
                    .padding(.bottom, zoomed(16))
                }
            }
        } else {
            // The first fetch is quick; a spinner would only flash.
            Color.clear
        }
    }

    /// The panels of the thread's tool patches (appliesTo: Tandem's in a
    /// video folder), each a card at the top, so a tool's state is where
    /// Mike already looks rather than only on the rail (Mike picked this,
    /// 28 Oct).
    private var toolPanels: [Panel] {
        let tools = Set(thread.patches.filter { !($0.matched ?? []).isEmpty }.map(\.id))
        return thread.panels.filter { tools.contains($0.patch) }
    }

    @ViewBuilder
    private func content(_ sections: HighlightSections, projects: [Project]) -> some View {
        ForEach(toolPanels) { panel in
            ToolCard(panel: panel) { app.choosePanel(panel.id, in: thread.id) }
                .padding(.horizontal, SidebarMetrics.outerInset)
                .padding(.top, zoomed(10))
        }
        if let brief = sections.brief {
            let points = HighlightSections.points(brief)
            VStack(alignment: .leading, spacing: zoomed(4)) {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .firstTextBaseline, spacing: zoomed(6)) {
                        // An old paragraph brief is one point: no bullet.
                        if points.count > 1 { Text("•") }
                        Text(point)
                            .lineSpacing(zoomed(2))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: TypeScale.label))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.horizontal, SidebarMetrics.leading)
            .padding(.top, zoomed(14))
            .padding(.bottom, zoomed(2))
        }
        // The last turn's asks while its card is open, ticked here or in
        // the transcript alike (the same `threads.tickAsk`).
        if let asksSeq = openAsks {
            SectionHeading(title: "Needs you", icon: "hand.raised")
            ForEach(Array(thread.asks.enumerated()), id: \.offset) { index, ask in
                AskRow(ask: ask) {
                    app.session(for: thread.id).tickAsk(asksSeq: asksSeq, index: index, ticked: !ask.ticked)
                }
            }
        }
        // The places Mike keeps going back to for the thread's projects,
        // under each project's own icon, so the live site is one click
        // from any of its threads (Mike asked 28 Oct).
        ForEach(projects) { project in
            SectionHeading(title: project.title, project: project)
            ForEach(project.links, id: \.url) { projectLink($0) }
        }
        // What will message the thread later, and the helpers it started:
        // they were a line over the composer and only the sidebar's rows
        // under the thread, and Mike wanted them here (29 Oct).
        let scheduled = schedules
        if !scheduled.isEmpty {
            SectionHeading(title: "Scheduled", icon: "clock")
            ForEach(scheduled) { scheduleRow($0) }
        }
        if !thread.subagents.isEmpty {
            let all = SubagentRows.highlights(thread)
            SectionHeading(title: "Sub-agents", icon: "person.2")
            let subagents = HighlightSections.capped(all, limit: HighlightSections.subagentLimit, showAll: allSubagents)
            ForEach(subagents.shown) { subagentRow($0) }
            if subagents.more > 0 { showAll(all.count) { allSubagents = true } }
        }
        if !sections.pinned.isEmpty {
            SectionHeading(title: "Pinned", icon: "pin")
            ForEach(sections.pinned) { row($0) }
        }
        if !sections.files.isEmpty {
            SectionHeading(title: "Files", icon: "doc")
            ForEach(sections.files) { row($0) }
        }
        if !sections.links.isEmpty {
            SectionHeading(title: "Links", icon: "link")
            let links = HighlightSections.capped(sections.links, limit: HighlightSections.linkLimit, showAll: allLinks)
            ForEach(links.shown) { row($0) }
            if links.more > 0 { showAll(sections.links.count) { allLinks = true } }
        }
        if !sections.commits.isEmpty || !sections.edited.isEmpty {
            SectionHeading(title: "Changes", icon: "arrow.triangle.branch")
            let commits = HighlightSections.capped(sections.commits, limit: HighlightSections.commitLimit, showAll: allCommits)
            ForEach(commits.shown) { row($0) }
            if commits.more > 0 { showAll(sections.commits.count) { allCommits = true } }
            if !sections.edited.isEmpty { edited(sections.edited) }
        }
    }

    private var schedules: [ScheduleRows.Row] {
        ScheduleRows.rows(for: thread, in: app.schedules, now: app.now, target: app.scheduleTarget)
    }

    private func scheduleRow(_ row: ScheduleRows.Row) -> some View {
        PaneRow(icon: row.paused ? "pause.circle" : "clock", title: row.title, trailing: row.when, detail: row.detail, titleTruncation: .tail, detailTruncation: .tail) {
            app.editSchedule(row.id)
        }
        .tip("Edit the schedule")
        .contextMenu {
            Button("Edit", systemImage: "pencil") { app.editSchedule(row.id) }
            Button("Show all schedules", systemImage: "clock") { app.showSchedules() }
        }
    }

    /// Like its row under the thread in the sidebar: how it's doing, what
    /// it's up to or found, and how long it took. Opens its transcript.
    private func subagentRow(_ subagent: Subagent) -> some View {
        let (icon, color): (String, Color?) = switch subagent.status {
        case .running: ("circle.dashed", nil)
        case .completed: ("checkmark", nil)
        case .failed: ("xmark", Color(nsColor: Theme.failed))
        case .stopped: ("minus", nil)
        }
        return PaneRow(icon: icon, iconColor: color, title: SubagentRows.title(subagent),
                       trailing: SubagentRows.duration(subagent, now: app.now), detail: SubagentRows.detail(subagent),
                       titleTruncation: .tail, detailTruncation: .tail) {
            app.selectSubagent(threadId: thread.id, subagentId: subagent.id)
        }
        .tip("\(SubagentRows.statusText(subagent)). Click to read its transcript.")
    }

    /// The open card's seq, when the thread has asks on it.
    private var openAsks: Int? {
        thread.asks.isEmpty ? nil : thread.asksSeq
    }

    /// Under a long group: the rest of it, newest first like the rest.
    private func showAll(_ count: Int, action: @escaping () -> Void) -> some View {
        PaneRow(icon: "ellipsis", title: "Show all \(count)", quiet: true) {
            withAnimation(.easeOut(duration: 0.15)) { action() }
        }
    }

    private func row(_ item: Highlight) -> some View {
        let isCommit = item.kind == .commit
        let detail: String? = if let path = item.path {
            HighlightText.folder(of: path, cwd: thread.cwd)
        } else if isCommit {
            HighlightText.commitLine(item)
        } else {
            // Not when it says the same as the title (a bare localhost link).
            item.url.map(HighlightText.address).flatMap { $0 == item.title ? nil : $0 }
        }
        // A pin says why in its note; the rest say how they turned up.
        let how = item.isPinned || isCommit ? nil : item.how.word
        return PaneRow(icon: FileIcon.symbol(for: item), title: item.title, lead: isCommit ? item.sha : nil,
                       trailing: how.flatMap { $0.isEmpty ? nil : $0 }, note: item.note, detail: detail,
                       titleTruncation: item.path == nil ? .tail : .middle,
                       action: isCommit ? nil : { app.open(item, in: thread, external: false) })
            .contextMenu {
                if let path = item.path {
                    FileMenu(path: path, thread: thread, title: item.title)
                } else if let url = item.link {
                    LinkMenu(url: url, thread: thread, title: item.title)
                } else if let sha = item.sha {
                    Button("Copy sha", systemImage: "number") { app.copyToPasteboard(sha) }
                }
                Divider()
                Button("Remove", systemImage: "pin.slash") { app.removeHighlight(item, in: thread.id) }
            }
    }

    private func projectLink(_ link: ProjectLink) -> some View {
        let address = HighlightText.address(link.url)
        return PaneRow(icon: "globe", title: link.title, detail: address == link.title ? nil : address, titleTruncation: .tail) {
            if let url = link.link { app.openLink(url, title: link.title, in: thread) }
        }
        .tip("Open \(address)")
        .contextMenu {
            if let url = link.link { LinkMenu(url: url, thread: thread, title: link.title) }
        }
    }

    /// "4 files edited", which opens to the files; a click opens one in
    /// its own app, since it's code to read in an editor, not to review.
    @ViewBuilder
    private func edited(_ paths: [String]) -> some View {
        PaneRow(icon: editedOpen ? "chevron.down" : "chevron.right", title: HighlightText.editedCount(paths.count), quiet: true) {
            withAnimation(.easeOut(duration: 0.15)) { editedOpen.toggle() }
        }
        if editedOpen {
            ForEach(paths, id: \.self) { path in
                PaneRow(icon: FileIcon.symbol(forPath: path), title: (path as NSString).lastPathComponent,
                        detail: HighlightText.folder(of: path, cwd: thread.cwd), indent: true) {
                    app.openExternally(URL(fileURLWithPath: path))
                }
                .tip("Open in its app")
                .contextMenu { FileMenu(path: path, thread: thread, title: (path as NSString).lastPathComponent) }
            }
        }
    }
}

/// One row in the pane's lists (Highlights, a list panel): a grey icon, the
/// title with a word at its end, then a note and a grey line under it.
/// Shaped like the sidebar's rows, with the same hover.
struct PaneRow: View {
    var icon: String?
    var iconColor: Color?
    let title: String
    /// Before the title, monospaced: a commit's sha.
    var lead: String?
    /// At the end of the title's line, faint: "Written", "Opened".
    var trailing: String?
    var trailingSymbol: String?
    var note: String?
    var detail: String?
    /// Secondary title, for a row that's a control (the edited files' disclosure).
    var quiet = false
    var indent = false
    /// Keeps the icon's room with no icon, so a list where some rows have
    /// one still lines its titles up.
    var reservesIcon = false
    /// A file name keeps its extension (middle); a sentence its start.
    var titleTruncation: Text.TruncationMode = .middle
    /// A path keeps both ends; a sub-agent's report its start.
    var detailTruncation: Text.TruncationMode = .middle
    var action: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        // A row with nothing to open (a commit) isn't a button: a disabled
        // one greyed it out as if it were unavailable.
        Group {
            if let action {
                Button(action: action) { label }
                    .buttonStyle(.plain)
            } else {
                label
            }
        }
        .padding(.horizontal, SidebarMetrics.outerInset)
        .onHover { hovering = $0 }
    }

    private var label: some View {
            HStack(alignment: .firstTextBaseline, spacing: zoomed(8)) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: zoomed(12)))
                        .foregroundStyle(iconColor.map(AnyShapeStyle.init) ?? AnyShapeStyle(Color(nsColor: Theme.faintIcon)))
                        .frame(width: zoomed(16))
                } else if reservesIcon {
                    Color.clear.frame(width: zoomed(16), height: 1)
                }
                VStack(alignment: .leading, spacing: zoomed(2)) {
                    HStack(alignment: .firstTextBaseline, spacing: zoomed(6)) {
                        if let lead {
                            Text(lead)
                                .font(.system(size: TypeScale.detail, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Text(title)
                            .font(.system(size: TypeScale.label))
                            .foregroundStyle(quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            .lineLimit(1)
                            .truncationMode(titleTruncation)
                        Spacer(minLength: zoomed(4))
                        if let trailing {
                            Text(trailing)
                                .font(.system(size: TypeScale.small))
                                .foregroundStyle(SidebarMetrics.faint)
                                .fixedSize()
                        }
                        if let trailingSymbol {
                            Image(systemName: trailingSymbol)
                                .font(.system(size: zoomed(11), weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let note, !note.isEmpty {
                        Text(note)
                            .font(.system(size: TypeScale.detail))
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: TypeScale.small))
                            .foregroundStyle(SidebarMetrics.faint)
                            .lineLimit(1)
                            .truncationMode(detailTruncation)
                    }
                }
            }
            .padding(.leading, SidebarMetrics.leading - SidebarMetrics.outerInset + (indent ? zoomed(24) : 0))
            .padding(.trailing, SidebarMetrics.trailing)
            .padding(.vertical, zoomed(6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering && action != nil ? SidebarMetrics.hover : .clear, in: RoundedRectangle(cornerRadius: SidebarMetrics.corner))
            .contentShape(Rectangle())
    }
}

/// One ask on the open card: a tick box, what Mike has to do, and where.
/// A ticked one is struck through and grey, as on the transcript's card.
private struct AskRow: View {
    let ask: Ask
    let tick: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: zoomed(8)) {
            Button(action: tick) {
                Image(systemName: ask.ticked ? "checkmark.square.fill" : "square")
                    .font(.system(size: zoomed(13)))
                    .foregroundStyle(ask.ticked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(nsColor: Theme.faintIcon)))
                    .frame(width: zoomed(16))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tip(ask.ticked ? "Not done" : "Done")
            VStack(alignment: .leading, spacing: zoomed(2)) {
                Text(ask.action)
                    .font(.system(size: TypeScale.label))
                    .foregroundStyle(ask.ticked ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .strikethrough(ask.ticked)
                    .fixedSize(horizontal: false, vertical: true)
                if let place = ask.where_, !place.isEmpty {
                    Text(place)
                        .font(.system(size: TypeScale.small))
                        .foregroundStyle(SidebarMetrics.faint)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, SidebarMetrics.leading)
        .padding(.trailing, SidebarMetrics.trailing + SidebarMetrics.outerInset)
        .padding(.vertical, zoomed(6))
    }
}

/// A file row's menu.
struct FileMenu: View {
    @Environment(AppModel.self) private var app
    let path: String
    let thread: ThreadSummary
    let title: String

    var body: some View {
        Button("Preview here", systemImage: "sidebar.right") { app.preview(path: path, title: title, in: thread) }
        Button("Open", systemImage: "arrow.up.forward.app") { app.openExternally(URL(fileURLWithPath: path)) }
        Button("Reveal in Finder", systemImage: "folder") { app.revealInFinder(path) }
        Button("Copy path", systemImage: "doc.on.doc") { app.copyToPasteboard(path) }
    }
}

/// A link row's menu: the browser or the panel, and "Default", the
/// same choice as a web link's menu in the transcript (WebLinkMenu). The
/// panel works for any page, but a site that needs a sign-in won't have
/// Mike's there.
struct LinkMenu: View {
    @Environment(AppModel.self) private var app
    @AppStorage(WebLinkAction.clickKey) private var click: WebLinkAction = .browser
    let url: URL
    let thread: ThreadSummary
    let title: String

    var body: some View {
        if url.isFileURL {
            Button("Preview here", systemImage: "sidebar.right") { app.preview(path: url.path, title: title, in: thread) }
            Button("Open", systemImage: "arrow.up.forward.app") { app.openExternally(url) }
        } else {
            Button(WebLinkAction.browser.title, systemImage: WebLinkAction.browser.symbol) { app.openExternally(url) }
            if PreviewRules.isWebPage(url) {
                Button(WebLinkAction.panel.title, systemImage: WebLinkAction.panel.symbol) { app.preview(page: url, title: title, in: thread) }
            }
        }
        Button("Copy link", systemImage: "link") { app.copyToPasteboard(url.absoluteString) }
        if PreviewRules.isWebPage(url) {
            Divider()
            Picker(selection: $click) {
                ForEach(WebLinkAction.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
            } label: {
                Label("Default", systemImage: "cursorarrow.click")
            }
        }
    }
}

// MARK: - Preview

/// A file or page in the pane in place of its section, with Back to that
/// section. An `.html` file or a local page is a web view (from the pool,
/// so it's kept while Mike looks at something else); text (Markdown,
/// code, plain) is the pane's own text view; anything else is Quick Look.
struct PreviewBody: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary
    let preview: PanePreview

    var body: some View {
        switch preview.target {
        case .page(let url):
            WebPanel(url: url)
        case .file(let path):
            if !FileManager.default.fileExists(atPath: path) {
                PaneNote(text: "This file isn't there any more.")
            } else if PreviewRules.viewer(forPath: path) == .web {
                WebPanel(url: URL(fileURLWithPath: path))
            } else if TextFileView.shows(path) {
                TextFileView(url: URL(fileURLWithPath: path), opened: preview.opened, editing: preview.editing)
                    .id(path)
            } else {
                QuickLookView(url: URL(fileURLWithPath: path), opened: preview.opened)
            }
        case .explain:
            ExplainPane(thread: thread)
        }
    }
}

/// A preview's buttons in its panel's bar: Back to the section it came
/// from, Edit (then Done) for a text file, Reveal in Finder for a file,
/// and Open.
struct PreviewButtons: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary
    let preview: PanePreview

    var body: some View {
        PaneHeaderButton(symbol: "chevron.left", help: "Back to \(PreviewBody.name(of: preview.from, in: thread))") {
            app.closePreview(in: thread.id)
        }
        if let file = preview.fileURL {
            if preview.editing {
                PaneHeaderButton(symbol: "checkmark", help: "Done. What you typed is saved.") { app.setPreviewEditing(false, in: thread.id) }
            } else if TextFileView.shows(file.path), TextFileView.canEdit(file.path) {
                PaneHeaderButton(symbol: "pencil", help: "Edit the file here. It's saved as you type.") { app.setPreviewEditing(true, in: thread.id) }
            }
            PaneHeaderButton(symbol: "folder", help: "Reveal in Finder") { app.revealInFinder(file.path) }
        }
        if let url = preview.externalURL {
            PaneHeaderButton(symbol: "arrow.up.right", help: preview.fileURL == nil ? "Open in browser" : "Open in its app") {
                app.openExternally(url)
            }
        }
    }
}

extension PreviewBody {
    static func name(of section: PaneSection, in thread: ThreadSummary) -> String {
        switch section {
        case .highlights: "Highlights"
        case .patches: "Patches"
        case .panel(let id): thread.panels.first { $0.id == id }?.title ?? "the panel"
        }
    }
}

/// Quick Look's own view: pictures, PDFs and video, as the Finder's space
/// bar shows them.
struct QuickLookView: NSViewRepresentable {
    let url: URL
    /// Bumped by each open, so the same file opened again is read again.
    let opened: Int

    final class Coordinator {
        var shown: (URL, Int)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        // .normal draws no frame of its own around the item.
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        // It's reused across files; closing would end it for good.
        view.shouldCloseWithWindow = false
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if let shown = context.coordinator.shown, shown.0 == url, shown.1 == opened { return }
        if context.coordinator.shown?.0 == url {
            view.refreshPreviewItem()
        } else {
            view.previewItem = url as NSURL
        }
        context.coordinator.shown = (url, opened)
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.close()
    }
}

/// A tool patch's panel as a card at the top of Highlights: the tool's
/// icon and the panel's title, its summary (or note) under them, and its
/// count. Opens the panel.
private struct ToolCard: View {
    let panel: Panel
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: zoomed(6)) {
                HStack(spacing: zoomed(8)) {
                    if let image = PatchImage.image(panel.iconFile) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: zoomed(18), height: zoomed(18))
                    } else {
                        Image(systemName: PanelIcon.symbol(for: panel))
                            .font(.system(size: zoomed(13)))
                            .foregroundStyle(.secondary)
                    }
                    Text(panel.title)
                        .font(.system(size: TypeScale.label, weight: .semibold))
                    Spacer(minLength: zoomed(4))
                    Image(systemName: "chevron.right")
                        .font(.system(size: zoomed(10), weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                if let text = panel.summary ?? panel.note {
                    Text(text)
                        .font(.system(size: TypeScale.detail))
                        .foregroundStyle(.secondary)
                        .lineSpacing(zoomed(2))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(zoomed(12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: zoomed(10)).fill(Color.primary.opacity(hovering ? 0.08 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: zoomed(10)).strokeBorder(Color(nsColor: Theme.cardBorder), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: zoomed(10)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .tip("Open \(panel.title)")
    }
}
