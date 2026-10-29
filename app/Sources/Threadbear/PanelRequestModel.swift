import AppKit
import BearDock
import ThreadbearCore

// show_panel (docs/protocol.md, "Showing panels"): a panel the agent asked
// to show Mike waits on its thread until he's looking at it, then opens, or
// comes to the front wherever he has it. Nothing he has open moves.

extension AppModel {
    /// Shows the request waiting on the thread in the main panel, if Mike is
    /// looking at it, and tells the runner it's done. Called when that
    /// thread's summary changes, when it's selected, when the app comes to
    /// the front and when the thread list loads.
    func servePanelRequest() {
        guard openProjectId == nil, !showsHomePage,
              let thread = selectedThread, let request = panelRequestGate.take(thread, looking: isLooking) else { return }
        guard let panel = PanelRequests.panel(request, in: thread) else {
            // Left for the runner to clear with Mike's next message.
            AppLog.write("panels", "\(thread.id.prefix(8)) asked to show \(request.panel), which it hasn't got")
            return
        }
        showRequested(panel, at: PanelRequests.place(request), in: thread)
        AppLog.write("panels", "showed \(request.panel) for \(thread.id.prefix(8))")
        guard let client else { return }
        Task {
            do {
                _ = try await client.panelShown(threadId: thread.id, requestId: request.id)
            } catch {
                AppLog.write("rpc", "threads.panelShown failed: \(error.localizedDescription)")
            }
        }
    }

    /// Opens the panel at `place`, or brings it to the front if it's open,
    /// docked or in a window of its own. A pane section becomes the
    /// thread's chosen one, as a click on its rail button makes it.
    func showRequested(_ panel: RequestedPanel, at place: RequestedPlace, in thread: ThreadSummary) {
        let id: PanelID
        switch panel {
        case .section(let section):
            if panePreview[thread.id].map({ $0.from != section }) ?? false { panePreview[thread.id] = nil }
            panelChoice[thread.id] = section.id
            id = section.id
        case .usage: id = WindowDock.usage
        case .updates: id = WindowDock.updates
        case .connectors: id = WindowDock.connectors
        }
        if dock.layout.contains(id) { return dock.show(id) }
        switch place {
        case .usual:
            switch panel {
            case .section(let section): showPane(section)
            case .usage: usageShown = true
            case .updates: updatesShown = true
            case .connectors: connectorsShown = true
            }
        case .tab: openMainTab(id)
        case .side(let side): dock.open(id, .window(DockEdge(rawValue: side.rawValue) ?? .right))
        case .window: dock.openInNewWindow(id)
        }
    }
}
