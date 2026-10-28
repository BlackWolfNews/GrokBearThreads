import AppKit
import SwiftUI
import ThreadbearCore
import WebKit

/// A pane section as a panel in the window's dock (WindowDock): Highlights,
/// one of the thread's panels, or Patches, for the thread that's selected.
/// A preview of a file or page opened from it takes its place until Back.
/// A `url` panel is a web view kept loaded between visits (WebPanelPool),
/// so the Convex dashboard doesn't reload every time Mike switches threads.
/// An `image` or `list` panel asks the runner for a fresh picture or rows
/// now and then while it's showing.
struct DockPane: View {
    @Environment(AppModel.self) private var app
    let section: PaneSection

    var body: some View {
        Group {
            if let thread = app.selectedThread {
                if let preview = app.panePreview[thread.id], preview.from == section {
                    PreviewBody(thread: thread, preview: preview)
                } else {
                    switch section {
                    case .highlights:
                        // Its own state (Show all, the edited files open) per thread.
                        HighlightsView(thread: thread)
                            .id(thread.id)
                    case .patches:
                        PatchesList(thread: thread)
                    case .panel(let id):
                        if let panel = thread.panels.first(where: { $0.id == id }) {
                            panelView(panel, in: thread)
                        } else {
                            PaneNote(text: "This thread has no \(WindowDock.title(of: section.id, app: app)) panel.")
                        }
                    }
                }
            } else {
                PaneNote(text: "Pick a thread to see its \(WindowDock.title(of: section.id, app: app)).")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func panelView(_ panel: Panel, in thread: ThreadSummary) -> some View {
        switch panel.kind {
        case .url:
            if let url = panel.pageURL {
                WebPanel(url: url)
            } else {
                PaneNote(text: "This panel has no page to show.")
            }
        case .image:
            ImagePanel(threadId: thread.id, panel: panel)
        case .list:
            ListPanel(thread: thread, panel: panel)
        }
    }
}

/// A pane panel's buttons, at the end of its bar in the dock: Back and the
/// file's or page's buttons over a preview, Open in browser for a page.
struct DockPaneButtons: View {
    @Environment(AppModel.self) private var app
    let section: PaneSection

    var body: some View {
        HStack(spacing: 0) {
            if let thread = app.selectedThread {
                if let preview = app.panePreview[thread.id], preview.from == section {
                    PreviewButtons(thread: thread, preview: preview)
                } else if case .panel(let id) = section, let panel = thread.panels.first(where: { $0.id == id }),
                          panel.kind == .url, let url = panel.pageURL {
                    PaneHeaderButton(symbol: "arrow.up.right", help: "Open in browser") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}

/// The pane's header: the section's title, a grey note after it, and its
/// buttons at the end, over a hairline. Plain, like the sidebar's view
/// headers: the rail already says which section this is.
struct PaneHeader<Leading: View, Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: zoomed(6)) {
                leading
                Text(title)
                    .font(.system(size: TypeScale.label, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: TypeScale.detail))
                        .foregroundStyle(Color(nsColor: Theme.faintText))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: zoomed(4))
                trailing
            }
            .padding(.leading, zoomed(14))
            .padding(.trailing, zoomed(6))
            .frame(height: PaneHeader.height)
            Rectangle().fill(Color(nsColor: Theme.hairline)).frame(height: 0.5)
        }
    }

    static var height: CGFloat { zoomed(38) }
}

extension PaneHeader where Leading == EmptyView {
    init(title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, detail: detail, leading: { EmptyView() }, trailing: trailing)
    }
}

extension PaneHeader where Leading == EmptyView, Trailing == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail, leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

/// A grey glyph button in the pane's header: Open in browser, Back, Reveal.
struct PaneHeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: TypeScale.label, weight: .medium))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: zoomed(26), height: zoomed(26))
                .background(hovering ? SidebarMetrics.hover : .clear, in: RoundedRectangle(cornerRadius: zoomed(6)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .tip(help)
        .accessibilityLabel(help)
    }
}

/// The column of icons down the right edge, mirroring the sidebar's
/// activity bar: Highlights at the top, a button per panel, Patches at the
/// foot. A click shows that section in the pane, or collapses the pane if
/// it's the one showing, as VS Code's bars do. It's also what keeps the
/// thread's highlights fresh, being on screen whenever a thread is.
struct PanelRail: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary

    /// What moves when there may be new highlights: a new event, or a pin,
    /// removal or brief (`highlightsAt`).
    private struct HighlightsKey: Equatable {
        var threadId: String
        var lastSeq: Int
        var highlightsAt: Date?
    }

    var body: some View {
        VStack(spacing: zoomed(4)) {
            // The accent dot while the last turn's asks aren't all ticked:
            // Highlights lists them under Needs you.
            ActivityButton(symbol: "pin", title: "Highlights", dot: thread.firstOpenAsk != nil, active: app.dock.isShowing(PaneSection.highlightsId)) {
                app.clickRail(.highlights, in: thread)
            }
            ForEach(thread.panels) { panel in
                ActivityButton(symbol: PanelIcon.symbol(for: panel), title: panel.title, badge: panel.badge, active: app.dock.isShowing(panel.id)) {
                    app.clickRail(.panel(panel.id), in: thread)
                }
            }
            Spacer(minLength: zoomed(8))
            if !thread.patches.isEmpty {
                ActivityButton(symbol: "square.dashed", title: "Patches", badge: thread.patches.count, active: app.dock.isShowing(PaneSection.patchesId)) {
                    app.clickRail(.patches, in: thread)
                }
            }
        }
        .padding(.top, zoomed(4))
        .padding(.bottom, zoomed(10))
        .frame(width: ActivityBar.width)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .leading) {
            Rectangle().fill(.separator).frame(width: 0.5).padding(.vertical, zoomed(4))
        }
        // Straight away for a thread not fetched yet this session, else
        // after a second like any other change.
        .task(id: thread.id) {
            app.refreshHighlights(thread.id, after: app.highlights[thread.id] == nil ? .zero : .seconds(1))
        }
        .onChange(of: HighlightsKey(threadId: thread.id, lastSeq: thread.lastSeq, highlightsAt: thread.highlightsAt)) { old, new in
            // A different thread is the task's job above.
            if old.threadId == new.threadId { app.refreshHighlights(thread.id) }
        }
    }
}

/// The Patches section: each patch that applies to the thread, where it came
/// from, what it gives, and its error if it couldn't load. A file opens in
/// the default editor. Patches from the thread's projects' folders are
/// grouped under each project, so it's clear why a chip or panel is there.
struct PatchesList: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary

    var body: some View {
        let groups = PatchGroups.group(thread) { app.project($0)?.title }
        ScrollView {
            VStack(alignment: .leading, spacing: zoomed(14)) {
                ForEach(groups) { group in
                    if groups.count > 1 { heading(group) }
                    ForEach(group.patches) { patch in
                        row(patch)
                    }
                }
                Text("A patch is a file in .threadbear/patches (in the thread's folder, a parent folder, a folder of one of its projects, or ~) whose default export lists actions, panels and hooks. Ask the agent for one.")
                    .font(.system(size: TypeScale.small))
                    .foregroundStyle(Color(nsColor: Theme.faintText))
                    .padding(.top, zoomed(6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(zoomed(16))
        }
    }

    /// "This thread's folder", or the project's name, which opens its page.
    @ViewBuilder
    private func heading(_ group: PatchGroup) -> some View {
        HStack(spacing: zoomed(6)) {
            if let projectId = group.projectId {
                PlainLink(title: group.title ?? "A project", help: "Open the project") { app.openProjectPage(projectId) }
                    .foregroundStyle(.secondary)
            } else {
                Text("This thread's folder").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: TypeScale.detail, weight: .semibold))
        .padding(.top, zoomed(4))
        .padding(.bottom, zoomed(4))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: Theme.hairline)).frame(height: 0.5) }
    }

    private func row(_ patch: PatchInfo) -> some View {
        VStack(alignment: .leading, spacing: zoomed(4)) {
            HStack(spacing: zoomed(6)) {
                Image(systemName: "square.dashed")
                    .font(.system(size: zoomed(11), weight: .medium))
                    .foregroundStyle(.secondary)
                Text(patch.id)
                    .font(.system(size: TypeScale.label, weight: .medium))
                Text(PatchesList.sourceName(patch.source))
                    .font(.system(size: TypeScale.small))
                    .foregroundStyle(Color(nsColor: Theme.faintText))
            }
            if let error = patch.error {
                Text(error)
                    .font(.system(size: TypeScale.detail))
                    .foregroundStyle(Color(nsColor: Theme.failed))
                    .textSelection(.enabled)
            } else {
                let gives = PatchesList.gives(patch.id, in: thread)
                if !gives.isEmpty {
                    Text(gives)
                        .font(.system(size: TypeScale.detail))
                        .foregroundStyle(.secondary)
                }
                if let liveError = patch.liveError {
                    Text(liveError)
                        .font(.system(size: TypeScale.detail))
                        .foregroundStyle(Color(nsColor: Theme.failed))
                        .textSelection(.enabled)
                }
            }
            // A tool patch: why it's here, when it came from another repo.
            if let matched = patch.matched, !matched.isEmpty {
                Text("Here for " + matched.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                    .font(.system(size: TypeScale.small))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let file = patch.file {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: file))
                } label: {
                    Text(file.abbreviatingHome)
                        .font(.system(size: TypeScale.small))
                        .foregroundStyle(Color(nsColor: Theme.faintText))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .tip("Open the file")
            } else if let folder = patch.folder, patch.projectId != nil {
                // A built-in from a project folder: which one.
                Text(folder.abbreviatingHome)
                    .font(.system(size: TypeScale.small))
                    .foregroundStyle(Color(nsColor: Theme.faintText))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    static func sourceName(_ source: String) -> String {
        switch source {
        case "builtin": return "built in"
        case "home": return "~/.threadbear"
        default: return "project"
        }
    }

    /// "actions Typecheck, Reseed · panel Storybook · hook Typecheck".
    static func gives(_ patchId: String, in thread: ThreadSummary) -> String {
        var parts: [String] = []
        let actions = thread.actions.filter { $0.patch == patchId }.map(\.title)
        let panels = thread.panels.filter { $0.patch == patchId }.map(\.title)
        let hooks = thread.hooks.filter { $0.patch == patchId }.map(\.title)
        if !actions.isEmpty { parts.append((actions.count == 1 ? "action " : "actions ") + actions.joined(separator: ", ")) }
        if !panels.isEmpty { parts.append((panels.count == 1 ? "panel " : "panels ") + panels.joined(separator: ", ")) }
        if !hooks.isEmpty { parts.append((hooks.count == 1 ? "hook " : "hooks ") + hooks.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// A quiet line in the middle of the pane: why there's nothing to show.
struct PaneNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: TypeScale.label))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(zoomed(24))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Web panels

/// A `url` panel. The web view comes from the pool and is moved into this
/// view's container, so leaving and coming back finds the page as it was.
struct WebPanel: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WebPanelContainer { WebPanelContainer() }

    func updateNSView(_ container: WebPanelContainer, context: Context) {
        container.show(WebPanelPool.shared.webView(for: url))
    }
}

final class WebPanelContainer: NSView {
    func show(_ webView: WKWebView) {
        if webView.superview === self { return }
        subviews.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }
}

/// Web views by page, a few at a time. Each uses the default website data
/// store, so a dashboard login made in one sticks for the next thread with
/// the same project, and across launches.
@MainActor
final class WebPanelPool: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = WebPanelPool()
    private var views: [URL: WKWebView] = [:]
    private var order: [URL] = []
    static let capacity = 4

    func webView(for url: URL) -> WKWebView {
        if let existing = views[url] {
            order.removeAll { $0 == url }
            order.append(url)
            return existing
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.underPageBackgroundColor = .windowBackgroundColor
        load(url, in: view)
        views[url] = view
        order.append(url)
        while order.count > Self.capacity, let oldest = order.first {
            // Never drop the one just asked for; the oldest unused goes.
            order.removeFirst()
            if let gone = views.removeValue(forKey: oldest) { gone.removeFromSuperview() }
        }
        return view
    }

    /// A page kept from an earlier look, read again: a mockup the agent
    /// has rewritten, a dev server that has rebuilt.
    func reloadIfLoaded(_ url: URL) {
        guard let view = views[url] else { return }
        load(url, in: view)
    }

    /// A local file (a mockup in the pane's preview) may read the files
    /// beside it, its styles and pictures, and nothing further up.
    private func load(_ url: URL, in view: WKWebView) {
        if url.isFileURL {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            view.load(URLRequest(url: url))
        }
    }

    /// Links that want a new window (OAuth sign-in pages, "open in new tab")
    /// load in the same view: there is no other window to give them.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}

// MARK: - Image panels

/// An `image` panel: the runner's latest picture (the Simulator's screen),
/// asked for again every few seconds while the panel is showing. Clicking
/// it opens the real Simulator.
private struct ImagePanel: View {
    @Environment(AppModel.self) private var app
    let threadId: String
    let panel: Panel
    @State private var render: PanelRender?
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            if let image {
                Button {
                    ImagePanel.openSimulator()
                } label: {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(zoomed(16))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .tip("Open Simulator")
            } else {
                PaneNote(text: render?.note ?? "Taking a screenshot…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(threadId)/\(panel.id)") {
            // Fresh every few seconds while on screen; the task ends when
            // the panel goes away.
            while !Task.isCancelled {
                let result = await app.renderPanel(threadId: threadId, panelId: panel.id, failure: "Couldn't get a picture from the runner.")
                if Task.isCancelled { return }
                render = result
                // A new NSImage each time: the file's name doesn't change.
                image = result?.image.flatMap { NSImage(contentsOfFile: $0.path) }
                try? await Task.sleep(for: .seconds(result?.image == nil ? 5 : 3))
            }
        }
    }

    static func openSimulator() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iphonesimulator") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - List panels

/// A `list` panel: the rows its patch's `items` function gives, asked for
/// when it's shown and every 15 seconds while it is. A row with a link or a
/// file opens it the way a highlight does.
private struct ListPanel: View {
    @Environment(AppModel.self) private var app
    let thread: ThreadSummary
    let panel: Panel
    @State private var render: PanelRender?

    var body: some View {
        Group {
            if let items = render?.items, !items.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let reserves = items.contains { ListPanel.icon($0) != nil }
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            row(item, reservesIcon: reserves)
                        }
                    }
                    .padding(.vertical, zoomed(8))
                }
            } else if let render {
                PaneNote(text: render.note ?? "Nothing in this list.")
            } else {
                PaneNote(text: "Loading…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(thread.id)/\(panel.id)") {
            render = nil
            while !Task.isCancelled {
                let result = await app.renderPanel(threadId: thread.id, panelId: panel.id, failure: "Couldn't get this list from the runner.")
                if Task.isCancelled { return }
                render = result ?? PanelRender(note: "Not connected to the runner.")
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    private func row(_ item: PanelItem, reservesIcon: Bool) -> some View {
        let link = item.url.flatMap(URL.init(string:))
        let open: (() -> Void)? = if let path = item.path {
            { app.preview(path: path, title: item.title, in: thread) }
        } else if let link {
            { app.openLink(link, title: item.title, in: thread) }
        } else {
            nil
        }
        return PaneRow(icon: ListPanel.icon(item), iconColor: ListPanel.colour(item.tone), title: item.title,
                       trailingSymbol: item.tone == .done && item.icon != nil ? "checkmark" : nil,
                       detail: item.detail, reservesIcon: reservesIcon, action: open)
            .contextMenu {
                if let path = item.path {
                    FileMenu(path: path, thread: thread, title: item.title)
                } else if let link {
                    LinkMenu(url: link, thread: thread, title: item.title)
                }
            }
    }

    /// The row's own icon, else one for its tone, else none.
    static func icon(_ item: PanelItem) -> String? {
        if let icon = item.icon, !icon.isEmpty { return icon }
        switch item.tone {
        case .attention: return "exclamationmark.circle"
        case .failed: return "xmark.circle"
        case .done: return "checkmark"
        case nil: return nil
        }
    }

    /// Orange and red only where they mean something: waiting on Mike, or
    /// broken. Everything else is grey.
    static func colour(_ tone: PanelItem.Tone?) -> Color? {
        switch tone {
        case .attention: Color(nsColor: Theme.needsYou)
        case .failed: Color(nsColor: Theme.failed)
        case .done, nil: nil
        }
    }
}
