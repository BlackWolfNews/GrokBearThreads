import AppKit
import BearDock
import SwiftUI
import ThreadbearCore

/// The window is a dock of panels (BearDock, in /dock): the sidebar, the
/// thread, and the pane sections (Highlights, a project's panels, Patches),
/// each of which Mike can drag anywhere, tab together, close and reopen.
/// A pane section's panel id is its `PaneSection.id`.
enum WindowDock {
    static let threads = "threadbear.threads"
    static let thread = "threadbear.thread"
    static let layoutKey = "dockLayout"

    /// Option 2 of the layout pass (28 Oct): the sidebar without a title,
    /// the thread, and Highlights, side by side.
    static var defaultLayout: DockLayout {
        DockLayout(root: .split(DockSplit(id: "window", axis: .horizontal, children: [
            .group(DockGroup(id: "sidebar", panels: [threads])),
            .group(DockGroup(id: "main", panels: [thread])),
            .group(DockGroup(id: "pane", panels: [PaneSection.highlightsId])),
        ], fractions: [0.29, 0.47, 0.24])), hiddenTitles: [threads])
    }

    @MainActor
    static func makeController(defaults: UserDefaults = .standard) -> DockController {
        var layout = defaults.data(forKey: layoutKey).flatMap { try? JSONDecoder().decode(DockLayout.self, from: $0) } ?? defaultLayout
        // Without the thread there's nothing to type in: a layout saved
        // that way (or by an older build) gets it back.
        if !layout.contains(thread) { layout.add(thread, .window(.right)) }
        let dock = DockController(layout: layout)
        dock.onChange = { defaults.set(try? JSONEncoder().encode($0), forKey: layoutKey) }
        return dock
    }

    /// A pane section's panel, or nil for the sidebar and the thread.
    static func section(_ panel: PanelID) -> PaneSection? {
        panel == threads || panel == thread ? nil : PaneSection(id: panel)
    }

    @MainActor
    static func title(of panel: PanelID, app: AppModel) -> String {
        switch panel {
        case threads: return "Threads"
        case thread: return "Thread"
        default:
            break
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
        case thread: return "text.alignleft"
        case PaneSection.highlightsId: return "pin"
        case PaneSection.patchesId: return "square.dashed"
        default:
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
        o.barsMoveWindow = true
        o.tip = { view, text in AnyView(view.tip(text)) }
        return o
    }

    private var content: DockContent {
        DockContent(
            title: { WindowDock.title(of: $0, app: app) },
            symbol: { WindowDock.symbol(of: $0, app: app) },
            header: { panel in
                // The thread's own title line (folder, title, projects)
                // in place of "Thread".
                panel == WindowDock.thread ? AnyView(ThreadHeader()) : nil
            },
            accessory: { panel in
                if panel == WindowDock.thread { return AnyView(ThreadMenuButton()) }
                if let section = WindowDock.section(panel) { return AnyView(DockPaneButtons(section: section)) }
                return nil
            },
            // Without the thread there's nowhere to type.
            closable: { $0 != WindowDock.thread },
            // A project's panel or Patches only for a thread that has them;
            // the dock keeps their place for the next one that does.
            available: { panel in
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
                case WindowDock.thread: AnyView(DetailView())
                default: AnyView(DockPane(section: PaneSection(id: panel)))
                }
            }
        )
    }
}
