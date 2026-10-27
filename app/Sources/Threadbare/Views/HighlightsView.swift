import AppKit
import Quartz
import SwiftUI
import ThreadbareCore

/// The pane's Highlights section: what the thread has made, shared and
/// pinned, so it doesn't scroll away with the transcript. The librarian's
/// line on where it's up to, then pins, files, links and commits, each
/// under a grey heading like the sidebar's, and left out when empty.
struct HighlightsView: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary
    @State private var editedOpen = false
    /// "Show all" on Links and Changes, for the thread on show.
    @State private var allLinks = false
    @State private var allCommits = false

    var body: some View {
        if app.highlightsUnsupported {
            PaneNote(text: "This runner doesn't keep highlights yet.")
        } else if let fetched = app.highlights[thread.id] {
            let sections = HighlightSections.build(fetched)
            if sections.isEmpty {
                PaneNote(text: "Nothing here yet. Files, links and commits from this thread show up here as it works.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        content(sections)
                    }
                    .padding(.bottom, zoomed(16))
                }
            }
        } else {
            // The first fetch is quick; a spinner would only flash.
            Color.clear
        }
    }

    @ViewBuilder
    private func content(_ sections: HighlightSections) -> some View {
        if let brief = sections.brief {
            Text(brief)
                .font(.system(size: TypeScale.label))
                .foregroundStyle(.secondary)
                .lineSpacing(zoomed(2))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, SidebarMetrics.leading)
                .padding(.top, zoomed(14))
                .padding(.bottom, zoomed(2))
        }
        // "Needs you" (the thread's open asks) goes here once ThreadSummary
        // has `asks`, from the needs-you branch.
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
                       action: isCommit ? nil : { app.open(item, in: thread, external: false) })
            .contextMenu {
                if let path = item.path {
                    FileMenu(path: path, thread: thread, title: item.title)
                } else if let url = item.link {
                    LinkMenu(url: url, thread: thread, title: item.title)
                } else if let sha = item.sha {
                    Button("Copy sha") { app.copyToPasteboard(sha) }
                }
                Divider()
                Button("Remove") { app.removeHighlight(item, in: thread.id) }
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
                .help("Open in its app")
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
                            .truncationMode(.middle)
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
                            .truncationMode(.middle)
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

/// A file row's menu.
struct FileMenu: View {
    @Environment(AppModel.self) private var app
    let path: String
    let thread: ThreadSummary
    let title: String

    var body: some View {
        Button("Preview here") { app.preview(path: path, title: title, in: thread) }
        Button("Open") { app.openExternally(URL(fileURLWithPath: path)) }
        Button("Reveal in Finder") { app.revealInFinder(path) }
        Button("Copy path") { app.copyToPasteboard(path) }
    }
}

/// A link row's menu. Preview here works for any page, but a site that
/// needs a sign-in won't have Mike's there; Open is the browser.
struct LinkMenu: View {
    @Environment(AppModel.self) private var app
    let url: URL
    let thread: ThreadSummary
    let title: String

    var body: some View {
        Button("Preview here") {
            if url.isFileURL { app.preview(path: url.path, title: title, in: thread) } else { app.preview(page: url, title: title, in: thread) }
        }
        Button("Open in browser") { app.openExternally(url) }
        Button("Copy link") { app.copyToPasteboard(url.absoluteString) }
    }
}

// MARK: - Preview

/// A file or page in the pane in place of its section, with Back to that
/// section. An `.html` file or a local page is a web view (from the pool,
/// so it's kept while Mike looks at something else); anything else is
/// Quick Look.
struct PreviewPane: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary
    let preview: PanePreview

    var body: some View {
        PaneHeader(title: preview.title) {
            PaneHeaderButton(symbol: "chevron.left", help: "Back to \(PreviewPane.name(of: preview.from, in: thread))") {
                app.closePreview(in: thread.id)
            }
            .padding(.leading, -zoomed(8))
        } trailing: {
            if let file = preview.fileURL {
                PaneHeaderButton(symbol: "folder", help: "Reveal in Finder") { app.revealInFinder(file.path) }
            }
            PaneHeaderButton(symbol: "arrow.up.right", help: preview.fileURL == nil ? "Open in browser" : "Open in its app") {
                app.openExternally(preview.externalURL)
            }
        }
        switch preview.target {
        case .page(let url):
            WebPanel(url: url)
        case .file(let path):
            if !FileManager.default.fileExists(atPath: path) {
                PaneNote(text: "This file isn't there any more.")
            } else if PreviewRules.viewer(forPath: path) == .web {
                WebPanel(url: URL(fileURLWithPath: path))
            } else {
                QuickLookView(url: URL(fileURLWithPath: path), opened: preview.opened)
            }
        }
    }

    static func name(of section: PaneSection, in thread: ThreadSummary) -> String {
        switch section {
        case .highlights: "Highlights"
        case .patches: "Patches"
        case .panel(let id): thread.panels.first { $0.id == id }?.title ?? "the panel"
        }
    }
}

/// Quick Look's own view: pictures, PDFs, video, Markdown and text, as the
/// Finder's space bar shows them.
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
