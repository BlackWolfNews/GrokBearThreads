import AppKit
import BearDock
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
            if let convex = panel.convex {
                ConvexPanel(threadId: thread.id, panelId: panel.id, convex: convex)
                    .id("\(thread.id) \(panel.id) \(convex.deployment)")
            } else if let url = panel.pageURL {
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
    @ObservedObject private var pool = WebPanelPool.shared
    let section: PaneSection

    var body: some View {
        HStack(spacing: 0) {
            if let thread = app.selectedThread {
                if let preview = app.panePreview[thread.id], preview.from == section {
                    PreviewButtons(thread: thread, preview: preview)
                } else if case .panel(let id) = section, let panel = thread.panels.first(where: { $0.id == id }),
                          panel.kind == .url, let url = panel.pageURL {
                    if let convex = panel.convex {
                        let selected = pool.selectedConvex(convex)
                        PaneHeaderButton(symbol: "key", help: "Make a new deploy key for \(selected), if the old one was revoked") {
                            pool.renewConvex(selected)
                        }
                        PaneHeaderButton(symbol: "arrow.clockwise", help: "Reload panel") { pool.reloadConvex(selected) }
                        PaneHeaderButton(symbol: "arrow.up.right", help: "Open \(selected) in browser") {
                            if let target = pool.convexBrowserURL(convex) { NSWorkspace.shared.open(target) }
                        }
                    } else {
                        PaneHeaderButton(symbol: "arrow.clockwise", help: "Reload panel") { WebPanelPool.shared.reloadIfLoaded(url) }
                        PaneHeaderButton(symbol: "arrow.up.right", help: "Open in browser") { NSWorkspace.shared.open(url) }
                    }
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
            .tourTarget(.highlightsRail)
            ForEach(thread.panels) { panel in
                let origin = PanelOrigin.of(panel, in: thread)
                ActivityButton(symbol: PanelIcon.symbol(for: panel), image: PatchImage.image(panel.iconFile), tinted: false, title: panel.title,
                               tip: origin.tip(panel.title, projectTitle: projectTitle(origin)), badge: panel.badge, active: app.dock.isShowing(panel.id)) {
                    app.clickRail(.panel(panel.id), in: thread)
                }
                // Bottom corner: the top one is the patch's count.
                .overlay(alignment: .bottomTrailing) { PanelOriginBadge(origin: origin, projectTitle: projectTitle(origin) ?? "") }
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

    private func projectTitle(_ origin: PanelOrigin) -> String? {
        guard case .project(let id) = origin else { return nil }
        return thread.projects.first { $0.id == id }?.title ?? app.project(id)?.title
    }
}

/// The little badge in the bottom corner of a panel's rail button that says
/// where it came from: the project's own icon for a project's folder, else
/// a glyph (a house for ~/.threadbear, a folder for the thread's own, a
/// wrench for a tool patch, a box for a built-in). Grey and small, like the
/// counts: it's there to answer "where's this from?", not to be noticed.
struct PanelOriginBadge: View {
    @Environment(AppModel.self) private var app
    let origin: PanelOrigin
    /// For the letter tile, when the project isn't in the list yet.
    var projectTitle = ""

    var body: some View {
        Group {
            if case .project(let id) = origin {
                ProjectIconView(project: app.project(id), title: projectTitle, size: 10)
            } else if let symbol = origin.symbol {
                Image(systemName: symbol)
                    .font(.system(size: zoomed(6.5), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: zoomed(13), height: zoomed(13))
        .background(Color(nsColor: .windowBackgroundColor), in: Circle())
        .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
        .offset(x: zoomed(2), y: zoomed(1))
        .allowsHitTesting(false)
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
                if let image = PatchImage.image(patch.iconFile) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: zoomed(14), height: zoomed(14))
                } else {
                    Image(systemName: patch.icon ?? "square.dashed")
                        .font(.system(size: zoomed(11), weight: .medium))
                        .foregroundStyle(.secondary)
                }
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
    @Environment(\.isDockGhost) private var isGhost

    func makeNSView(context: Context) -> WebPanelContainer { WebPanelContainer() }

    func updateNSView(_ container: WebPanelContainer, context: Context) {
        // The dock's drag ghost would take the page out of its panel.
        if isGhost { return }
        container.show(WebPanelPool.shared.webView(for: url))
    }
}

/// The Convex panel: Convex's embedded dashboard, which takes a deploy key
/// instead of a Convex login (docs/protocol.md, "The Convex panel"). The
/// runner makes the key the first time, which takes a few seconds.
private struct ConvexPanel: View {
    @Environment(AppModel.self) private var app
    let threadId: String
    let panelId: String
    let convex: ConvexDeployment
    @ObservedObject private var pool = WebPanelPool.shared
    @State private var key: ConvexPanelKey?
    @State private var failure: String?
    @State private var choices: [ConvexDeploymentChoice] = []
    @State private var choicesNote: String?
    @State private var loadingChoices = true
    @State private var refresh = 0

    private var selected: String { pool.selectedConvex(convex) }
    private var label: String { choices.first(where: { $0.deployment == selected })?.label ?? "Configured" }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: zoomed(6)) {
                HStack(spacing: zoomed(8)) {
                    // A deployment's name doesn't say whose it is.
                    if let project = convex.project {
                        Text(project)
                            .font(.system(size: TypeScale.label, weight: .semibold))
                            .lineLimit(1)
                            .tip(convex.team.map { "Convex project \(project), team \($0)" } ?? "Convex project \(project)")
                    }
                    Menu {
                        ForEach(choices, id: \.deployment) { choice in
                            Button {
                                pool.selectConvex(choice.deployment, for: convex)
                            } label: {
                                if selected == choice.deployment {
                                    Label("\(choice.label) · \(choice.deployment)", systemImage: "checkmark")
                                } else {
                                    Text("\(choice.label) · \(choice.deployment)")
                                }
                            }
                            .tip("Show \(choice.deployment) in this panel")
                        }
                        Divider()
                        Button("Refresh deployments") { refresh += 1 }
                            .tip("Look up this project's development and production deployments again")
                    } label: {
                        Text(label)
                            .font(.system(size: TypeScale.label, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(loadingChoices)
                    .tip("Choose the deployment shown in this panel")
                    Text(selected)
                        .font(.system(size: TypeScale.small, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .tip(selected)
                    Spacer(minLength: 0)
                    if loadingChoices { ProgressView().controlSize(.mini) }
                }
                if let choicesNote {
                    Text(choicesNote)
                        .font(.system(size: TypeScale.small))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .tip(choicesNote)
                }
            }
            .padding(.horizontal, zoomed(12))
            .padding(.vertical, zoomed(8))
            Divider()
            content
        }
        .task(id: refresh) { await loadChoices() }
        // A cancelled request must never put the previous deployment back.
        .task(id: "\(selected) \(pool.convexRenewals[selected, default: 0])") { await fetch() }
    }

    @ViewBuilder
    private var content: some View {
        if let key, key.deployment == selected {
            ConvexWebPage(key: key)
        } else if let failure {
            VStack(spacing: zoomed(12)) {
                Text(failure)
                    .font(.system(size: TypeScale.label))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Try again") { Task { await fetch() } }
                    .tip("Ask the runner for a deploy key again")
            }
            .padding(zoomed(24))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PaneNote(text: loadingChoices ? "Finding deployments…" : "Getting a deploy key for \(selected)…")
        }
    }

    private func loadChoices() async {
        loadingChoices = true
        let result = await app.convexPanelDeployments(threadId: threadId, panelId: panelId, refresh: refresh > 0)
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let listed):
            choices = listed.deployments
            choicesNote = listed.note
        case .failure(let error):
            choicesNote = "Couldn't load other deployments: \(error.localizedDescription)"
        }
        if !choices.contains(where: { $0.deployment == convex.deployment }) {
            choices.insert(ConvexDeploymentChoice(deployment: convex.deployment, deploymentUrl: convex.deploymentUrl, label: "Configured"), at: 0)
        }
        if !choices.contains(where: { $0.deployment == selected }) {
            pool.selectConvex(convex.deployment, for: convex)
        }
        loadingChoices = false
    }

    private func fetch() async {
        let target = selected
        let renew = pool.takeRenewal(target)
        if renew || key?.deployment != target { key = nil }
        failure = nil
        let result = await app.convexPanelKey(threadId: threadId, panelId: panelId, deployment: target, renew: renew)
        guard !Task.isCancelled, selected == target else { return }
        switch result {
        case .success(let made): key = made
        case .failure(let error): failure = error.localizedDescription
        }
    }
}

private struct ConvexWebPage: NSViewRepresentable {
    let key: ConvexPanelKey
    @Environment(\.isDockGhost) private var isGhost

    func makeNSView(context: Context) -> WebPanelContainer { WebPanelContainer() }

    func updateNSView(_ container: WebPanelContainer, context: Context) {
        if isGhost { return }
        container.show(WebPanelPool.shared.convexView(for: key))
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
final class WebPanelPool: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = WebPanelPool()
    private var views: [URL: WKWebView] = [:]
    private var order: [URL] = []
    static let capacity = 4
    private let defaults: UserDefaults
    @Published private var convexSelections: [String: String]
    /// Bumped by New deploy key, so the deployment's panel asks again.
    @Published private(set) var convexRenewals: [String: Int] = [:]
    private var pendingRenewals: Set<String> = []
    static let convexEmbedded = URL(string: "https://dashboard-embedded.convex.dev/")!

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        convexSelections = defaults.dictionary(forKey: "convexPanelDeployments") as? [String: String] ?? [:]
        super.init()
    }

    func selectedConvex(_ configured: ConvexDeployment) -> String {
        convexSelections[configured.deployment] ?? configured.deployment
    }

    func selectConvex(_ deployment: String, for configured: ConvexDeployment) {
        convexSelections[configured.deployment] = deployment
        defaults.set(convexSelections, forKey: "convexPanelDeployments")
    }

    func convexBrowserURL(_ configured: ConvexDeployment) -> URL? {
        URL(string: "https://dashboard.convex.dev/d/\(selectedConvex(configured))")
    }

    func webView(for url: URL) -> WKWebView {
        if let existing = views[url] {
            order.removeAll { $0 == url }
            order.append(url)
            return existing
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = makeView(config)
        load(url, in: view)
        keep(view, as: url)
        return view
    }

    /// Convex's embedded dashboard for one deployment, given its deploy key
    /// by a script that answers the page's own request for it. The store
    /// isn't saved to disk, so the key isn't either.
    func convexView(for key: ConvexPanelKey) -> WKWebView {
        let slot = Self.convexSlot(key.deployment)
        if let existing = views[slot] {
            order.removeAll { $0 == slot }
            order.append(slot)
            return existing
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(WKUserScript(
            source: Self.convexCredentialsScript(key), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = makeView(config)
        view.load(URLRequest(url: Self.convexEmbedded))
        keep(view, as: slot)
        return view
    }

    /// Answers the embedded dashboard's `dashboard-credentials-request`
    /// (docs.convex.dev/platform-apis/embedded-dashboard), only on its own
    /// origin, and only to a message from the page itself.
    static func convexCredentialsScript(_ key: ConvexPanelKey) -> String {
        let credentials: [String: String] = [
            "type": "dashboard-credentials", "adminKey": key.adminKey,
            "deploymentUrl": key.deploymentUrl, "deploymentName": key.deployment,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: credentials)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let origin = convexEmbedded.absoluteString.dropLast()
        return """
        (() => {
          if (location.origin !== '\(origin)') return;
          const credentials = \(json);
          window.addEventListener('message', (e) => {
            if (e.source === window && e.data && e.data.type === 'dashboard-credentials-request') window.postMessage(credentials, location.origin);
          });
        })();
        """
    }

    /// The pool's key for a deployment's view: not a page anyone loads.
    private static func convexSlot(_ deployment: String) -> URL {
        URL(string: "threadbear-convex:\(deployment)")!
    }

    func reloadConvex(_ deployment: String) {
        views[Self.convexSlot(deployment)]?.load(URLRequest(url: Self.convexEmbedded))
    }

    /// New deploy key: drops the view with the old key and has the panel
    /// ask the runner for a fresh one.
    func renewConvex(_ deployment: String) {
        let slot = Self.convexSlot(deployment)
        views.removeValue(forKey: slot)?.removeFromSuperview()
        order.removeAll { $0 == slot }
        pendingRenewals.insert(deployment)
        convexRenewals[deployment, default: 0] += 1
    }

    func takeRenewal(_ deployment: String) -> Bool {
        pendingRenewals.remove(deployment) != nil
    }

    private func makeView(_ config: WKWebViewConfiguration) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.underPageBackgroundColor = .windowBackgroundColor
        return view
    }

    private func keep(_ view: WKWebView, as url: URL) {
        views[url] = view
        order.append(url)
        while order.count > Self.capacity, let oldest = order.first {
            // Never drop the one just asked for; the oldest unused goes.
            order.removeFirst()
            if let gone = views.removeValue(forKey: oldest) { gone.removeFromSuperview() }
        }
    }

    private func isConvexView(_ webView: WKWebView) -> Bool {
        views.contains { $0.key.scheme == "threadbear-convex" && $0.value === webView }
    }

    /// The embedded dashboard's links out (docs, the full dashboard) open in
    /// the browser, so the page holding the key stays the only one in its view.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if isConvexView(webView), navigationAction.targetFrame?.isMainFrame ?? true,
           let url = navigationAction.request.url, url.host != Self.convexEmbedded.host,
           ["http", "https"].contains(url.scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
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
        guard let url = navigationAction.request.url else { return nil }
        if isConvexView(webView) { NSWorkspace.shared.open(url) } else { webView.load(URLRequest(url: url)) }
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
