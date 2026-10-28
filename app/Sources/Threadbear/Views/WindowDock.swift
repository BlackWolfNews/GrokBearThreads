import AppKit
import BearDock
import SwiftUI
import ThreadbearCore

/// The window is a dock of panels (BearDock, in /dock): the sidebar, the
/// main panel, the pane sections (Highlights, a project's panels, Patches)
/// and any threads opened in panels of their own, each of which Mike can
/// drag anywhere, tab together, close and reopen. A pane section's panel id
/// is its `PaneSection.id`.
///
/// The main panel follows the context: it shows whatever's picked in the
/// sidebar (a thread, a new thread, a project's page). Panels opened for
/// that context, like a review, open as tabs beside it and close when the
/// context changes, unless Mike drags them out of its group: then they
/// stay where he put them (AppModel.mainTabs). A thread opened in a panel
/// of its own (`threadPanel`) stays put too.
enum WindowDock {
    static let threads = "threadbear.threads"
    /// The main panel. The id is from when it was "the thread" panel, and
    /// stays so saved layouts still have it.
    static let main = "threadbear.thread"
    /// The design review being answered (show_options), a tab beside the
    /// main panel.
    static let review = "threadbear.review"
    static let layoutKey = "dockLayout"
    static let threadPanelPrefix = "threadbear.thread:"

    /// The panel for a thread opened on its own, beside the main panel.
    static func threadPanel(_ threadId: String) -> PanelID { threadPanelPrefix + threadId }

    /// The thread a panel opened on its own shows, or nil for any other panel.
    static func pinnedThread(_ panel: PanelID) -> String? {
        panel.hasPrefix(threadPanelPrefix) ? String(panel.dropFirst(threadPanelPrefix.count)) : nil
    }

    /// Option 2 of the layout pass (28 Oct): the sidebar without a title,
    /// the thread, and Highlights, side by side.
    static var defaultLayout: DockLayout {
        DockLayout(root: .split(DockSplit(id: "window", axis: .horizontal, children: [
            .group(DockGroup(id: "sidebar", panels: [threads])),
            .group(DockGroup(id: "main", panels: [main])),
            .group(DockGroup(id: "pane", panels: [PaneSection.highlightsId])),
        ], fractions: [0.29, 0.47, 0.24])), hiddenTitles: [threads])
    }

    @MainActor
    static func makeController(defaults: UserDefaults = .standard) -> DockController {
        var layout = defaults.data(forKey: layoutKey).flatMap { try? JSONDecoder().decode(DockLayout.self, from: $0) } ?? defaultLayout
        // Without the thread there's nothing to type in: a layout saved
        // that way (or by an older build) gets it back.
        if !layout.contains(main) { layout.add(main, .window(.right)) }
        // A review panel only lasts while its review is open in this run.
        if layout.contains(review) { layout.close(review) }
        let dock = DockController(layout: layout)
        // The layout without the review panel, as it was before the review
        // opened. The review is a visitor: closing it puts that layout back
        // (closing a panel otherwise grows every neighbour, the sidebar
        // too), and a layout with it in is never saved.
        var withoutReview = layout
        var reviewWasOpen = false
        dock.onChange = { [weak dock] next in
            if next.contains(review) {
                reviewWasOpen = true
                return
            }
            if reviewWasOpen {
                reviewWasOpen = false
                if next.groups.map(\.panels) == withoutReview.groups.map(\.panels) {
                    // Nothing else moved while it was open: back to the old sizes.
                    let restored = withoutReview
                    DispatchQueue.main.async { dock?.setLayout(restored) }
                    return
                }
            }
            withoutReview = next
            defaults.set(try? JSONEncoder().encode(next), forKey: layoutKey)
        }
        return dock
    }

    /// A pane section's panel, or nil for the sidebar, the main panel, the
    /// review and a thread's own panel.
    static func section(_ panel: PanelID) -> PaneSection? {
        panel == threads || panel == main || panel == review || pinnedThread(panel) != nil ? nil : PaneSection(id: panel)
    }

    @MainActor
    static func title(of panel: PanelID, app: AppModel) -> String {
        switch panel {
        case threads: return "Threads"
        case main:
            // As a tab beside a review it's named for what it shows.
            if let project = app.openProject { return project.title }
            if app.showsProjectsHome { return "Projects" }
            guard let thread = app.selectedThread else { return "New thread" }
            return thread.title.isEmpty ? "Untitled" : thread.title
        case review: return app.reviewPanel?.review.title ?? "Review"
        default:
            break
        }
        if let id = pinnedThread(panel) {
            let title = app.threads[id]?.title ?? ""
            return title.isEmpty ? "Untitled" : title
        }
        // A file or page open over the section: its name, with Back to the
        // section in the bar.
        if let thread = app.selectedThread, let preview = app.panePreview[thread.id], preview.from.id == panel {
            return preview.title
        }
        switch panel {
        case PaneSection.highlightsId: return "Highlights"
        case PaneSection.patchesId: return "Patches"
        default:
            // The selected thread's panel by that id, else any thread's, as
            // a panel stays in the layout when Mike moves to a thread
            // without it.
            if let hit = app.selectedThread?.panels.first(where: { $0.id == panel }) { return hit.title }
            return app.threads.values.lazy.flatMap(\.panels).first { $0.id == panel }?.title ?? panel
        }
    }

    @MainActor
    static func symbol(of panel: PanelID, app: AppModel) -> String? {
        switch panel {
        case threads: return "bubble.left.and.bubble.right"
        case main: return "text.alignleft"
        case review: return "rectangle.on.rectangle"
        case PaneSection.highlightsId: return "pin"
        case PaneSection.patchesId: return "square.dashed"
        default:
            if pinnedThread(panel) != nil { return "text.alignleft" }
            let hit = app.selectedThread?.panels.first { $0.id == panel } ?? app.threads.values.lazy.flatMap(\.panels).first { $0.id == panel }
            return hit.map(PanelIcon.symbol(for:))
        }
    }
}

// MARK: - The pane, through the dock

extension AppModel {
    /// The pane sections open in the dock, in layout order.
    var openPanes: [PanelID] {
        dock.layout.panels.filter { WindowDock.section($0) != nil }
    }

    /// Opens a section's panel or brings it to the front: beside another
    /// pane section if one's open, else down the right of the window.
    func showPane(_ section: PaneSection) {
        dock.show(section.id, near: openPanes, fallback: .window(.right))
    }
}

/// The window's content: the dock, with the rail of the thread's pane
/// sections down the right.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var app = app
        HStack(spacing: 0) {
            DockView(controller: app.dock, options: Self.options, content: content)
            if let thread = app.selectedThread, app.openProject == nil {
                PanelRail(thread: thread)
            }
        }
        // Up under where the title bar was: the panels' bars take its place.
        .ignoresSafeArea(.container, edges: .top)
        // The window's title (Window menu, Mission Control); nothing shows
        // it, as the window has no title bar.
        .navigationTitle(windowTitle)
        .sheet(item: $app.scheduleEditor) { state in
            ScheduleEditor(state: state)
        }
        // The automation's `settings` opens the Settings window; only a
        // SwiftUI view can (AppKit's showSettingsWindow: does nothing now).
        .onChange(of: app.settingsRequest) { openSettings() }
        // Saves where the window is, so the next launch opens it there.
        .background(MainWindowFrameTracker())
    }

    private var windowTitle: String {
        if let project = app.openProject { return project.title }
        if app.showsProjectsHome { return "Projects" }
        return app.selectedThread.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "New thread"
    }

    /// The window has no title bar (ThreadbearApp): the panels' bars are the
    /// top of the window, with room for the traffic lights in the corner.
    static var options: DockOptions {
        var o = DockOptions()
        o.headerHeight = PaneHeader<EmptyView, EmptyView>.height
        o.titleSize = TypeScale.label
        o.trafficLights = 78
        o.cornerMovesWindow = true
        o.tip = { view, text in AnyView(view.tip(text)) }
        // A panel dragged out into a window of its own: the same model as
        // the main window's views.
        o.windowContent = { AnyView($0.environment(AppModel.shared)) }
        #if DEBUG
        // A scripted run's panel windows stay behind Mike's, as its main one does.
        o.prepareWindow = { if Automation.instanceId != nil { $0.tuckBehind() } }
        #endif
        return o
    }

    private var content: DockContent {
        DockContent(
            title: { WindowDock.title(of: $0, app: app) },
            symbol: { WindowDock.symbol(of: $0, app: app) },
            header: { panel in
                // The thread's own title line (folder, title, projects)
                // in place of its name.
                if panel == WindowDock.main { return AnyView(ThreadHeader()) }
                if let id = WindowDock.pinnedThread(panel) { return AnyView(HeaderTitle(thread: app.threads[id])) }
                return nil
            },
            accessory: { panel in
                if panel == WindowDock.main { return AnyView(ThreadMenuButton()) }
                if let id = WindowDock.pinnedThread(panel) { return AnyView(ThreadMenuButton(pinned: id)) }
                if panel == WindowDock.review { return AnyView(ReviewPanelButtons()) }
                if let section = WindowDock.section(panel) { return AnyView(DockPaneButtons(section: section)) }
                return nil
            },
            // Without the main panel there's nowhere to type.
            closable: { $0 != WindowDock.main },
            // A project's panel or Patches only for a thread that has them;
            // the dock keeps their place for the next one that does.
            available: { panel in
                // Beside the main panel a review only lasts while its
                // context does (AppModel.mainContextChanged); dragged out
                // anywhere else it stays.
                if panel == WindowDock.review { return app.reviewPanel != nil }
                if let id = WindowDock.pinnedThread(panel) { return app.threads[id] != nil }
                guard let thread = app.selectedThread else { return true }
                switch WindowDock.section(panel) {
                case .panel(let id): return thread.panels.contains { $0.id == id }
                case .patches: return !thread.patches.isEmpty
                default: return true
                }
            },
            view: { panel in
                switch panel {
                case WindowDock.threads: AnyView(SidebarView())
                case WindowDock.main: AnyView(DetailView())
                case let id where WindowDock.pinnedThread(id) != nil:
                    AnyView(PinnedThreadView(threadId: WindowDock.pinnedThread(id)!).id(id))
                case WindowDock.review:
                    if let session = app.reviewPanel {
                        AnyView(ReviewWindow(session: session, inPanel: true, back: {}, close: { app.closeReviewPanel() }).id(session.threadId + "/" + session.review.id))
                    } else {
                        AnyView(EmptyView())
                    }
                default: AnyView(DockPane(section: PaneSection(id: panel)))
                }
            }
        )
    }
}
