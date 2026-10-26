import AppKit
import Quartz
import SwiftUI
import ThreadbareCore

/// The transcript table. Owns Quick Look control for image clicks and the
/// row context menu.
final class TranscriptTableView: NSTableView {
    weak var controller: TranscriptController?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return controller?.menu(forRow: row(at: point))
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLookCoordinator.shared.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { QuickLookCoordinator.shared.end(panel) }

    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        // Let text views inside rows take focus for selection.
        true
    }
}

/// Where a thread was scrolled to, so switching back restores it.
struct ScrollMemory {
    var pinned: Bool
    var anchorId: String?
    var offset: CGFloat
}

/// Drives the `NSTableView` from a `ThreadSession`: row inserts and reloads,
/// never full reloads for live updates; cached heights; bottom pinning; and
/// keeping the visible row anchored when older rows are paged in.
@MainActor
final class TranscriptController: NSObject, NSTableViewDataSource, NSTableViewDelegate, RowCellDelegate {
    nonisolated static let renders = RenderCache()

    let scrollView = NSScrollView()
    let tableView = TranscriptTableView()
    private(set) weak var session: ThreadSession?
    private(set) var width: CGFloat = 0
    private var deferred = Set<String>()
    private var deferredTimer: Timer?
    private var questionDrafts: [String: [Int: Set<String>]] = [:]
    /// Set by perf runs: called after older rows are added at the top.
    var onPrepend: (() -> Void)?
    /// Pause paging (perf runs drive it themselves at times).
    var pagingEnabled = true
    /// After a width change on a long thread only the rows near the screen
    /// are re-measured at once; this re-measures the rest off the main thread
    /// once the resizing stops.
    private var remeasureTask: Task<Void, Never>?
    /// Up to this many rows are re-measured straight away on a width change.
    static let syncRemeasureLimit = 400
    /// The clip view's height at the last frame change, to tell whether the
    /// view was at the bottom before it got shorter.
    private var lastClipHeight: CGFloat = 0

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.usesAutomaticRowHeights = false
        tableView.allowsColumnReordering = false
        tableView.focusRingType = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.controller = self

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 10, left: 0, bottom: 14, right: 0)
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
    }

    // MARK: Showing a session

    func show(_ newSession: ThreadSession?) {
        if newSession === session {
            return
        }
        let previous = session
        if let previous { previous.scrollMemory = captureMemory() }
        previous?.view = nil
        if previous?.scrollMemory?.pinned == true { previous?.trimToNewest() }
        session = newSession
        newSession?.view = self
        questionDrafts = [:]
        deferred = []
        remeasureTask?.cancel()
        width = currentTableWidth
        reloadAll()
    }

    /// The width rows are laid out at. It's the scroll view's width less a
    /// legacy scroller's, whether or not the scroller is showing: with
    /// "Show scroll bars: Automatic" and a mouse the scroller comes and goes
    /// as threads get long or short, and using the clip view's width made
    /// every switch lay rows out twice (982 then 965 pt).
    var currentTableWidth: CGFloat {
        max(320, scrollView.frame.width - reservedScrollerWidth)
    }

    /// The width a legacy scroller takes at the right edge (0 with overlay
    /// scrollers). The reading column is centred in what's left, so the
    /// composer below lines itself up by the same amount.
    var reservedScrollerWidth: CGFloat {
        let probe = NSSize(width: 1000, height: 1000)
        let content = NSScrollView.contentSize(
            forFrameSize: probe, horizontalScrollerClass: nil, verticalScrollerClass: NSScroller.self,
            borderType: scrollView.borderType, controlSize: .regular, scrollerStyle: scrollView.scrollerStyle
        )
        return probe.width - content.width
    }

    /// Full reload: only used when switching threads or after a fresh load.
    func reloadAll() {
        let memory = session?.scrollMemory
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        if let memory, !memory.pinned, let id = memory.anchorId, let index = session?.displayIndex(of: id) {
            scroll(toRow: index, offset: memory.offset)
        } else {
            scrollToBottom()
        }
    }

    var rowCount: Int { session?.displayCount ?? 0 }

    func row(at index: Int) -> TranscriptRow? {
        guard let session, index >= 0, index < session.displayCount else { return nil }
        return session.displayRow(index)
    }

    func render(_ row: TranscriptRow) -> RowRender {
        Self.renders.render(row, expanded: isExpanded(row), width: width)
    }

    /// Item rows keep their open state in the session; groups and changes
    /// cards carry theirs in the row.
    func isExpanded(_ row: TranscriptRow) -> Bool {
        RenderCache.effectiveExpanded(row, session?.expanded.contains(row.id) == true)
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableView(_ tableView: NSTableView, heightOfRow index: Int) -> CGFloat {
        guard let row = row(at: index) else { return 1 }
        return max(1, render(row).height)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let row = row(at: index) else { return nil }
        let cell = makeCell(for: row)
        cell.delegate = self
        cell.configure(row: row, render: render(row), tableWidth: width, expanded: isExpanded(row))
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        for case let cell as RowCellView in rowView.subviews { cell.releaseContent() }
    }

    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        // Placed in the table now, so it knows which part of it is on screen.
        for case let cell as RowCellView in rowView.subviews { cell.updateSlices(force: true) }
    }

    static func cellIdentifier(for row: TranscriptRow) -> String {
        switch row.kind {
        case .user, .assistant, .plan, .error, .footer: return "text"
        // A system note folded into an open group reads as one of its lines.
        case .note: return row.inGroup ? "header" : "text"
        case .reasoning, .tool, .diff: return "header"
        case .images: return "images"
        case .approval: return "approval"
        case .question: return "question"
        case .group: return "group"
        case .working: return "working"
        case .changes: return "changes"
        }
    }

    private func makeCell(for row: TranscriptRow) -> RowCellView {
        let identifier = Self.cellIdentifier(for: row)
        let id = NSUserInterfaceItemIdentifier(identifier)
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? RowCellView { return reused }
        let cell: RowCellView
        switch identifier {
        case "text": cell = TextRowCell(frame: .zero)
        case "header": cell = HeaderRowCell(frame: .zero)
        case "images": cell = ImagesRowCell(frame: .zero)
        case "approval": cell = ApprovalRowCell(frame: .zero)
        case "group": cell = GroupRowCell(frame: .zero)
        case "working": cell = WorkingRowCell(frame: .zero)
        case "changes": cell = ChangesRowCell(frame: .zero)
        default: cell = QuestionRowCell(frame: .zero)
        }
        cell.identifier = id
        return cell
    }

    // MARK: Live updates

    /// Applies a batch from the session. Indices are in display space:
    /// `removed` in the rows before the change, the others after it.
    func apply(removed: IndexSet = [], inserted: IndexSet, updated: IndexSet) {
        guard session != nil else { return }
        let wasPinned = isAtBottom
        let anchor = wasPinned ? nil : captureMemory()
        let visible = tableView.rows(in: tableView.visibleRect)
        let visibleRange = visible.location..<(visible.location + visible.length + 1)

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        // NSTableView applies these in order, each against the rows as they
        // are after the one before: removals at old indices, then inserts
        // at new ones.
        if !removed.isEmpty {
            tableView.removeRows(at: removed, withAnimation: [])
        }
        if !inserted.isEmpty {
            tableView.insertRows(at: inserted, withAnimation: [])
        }
        var changed = IndexSet()
        for index in updated {
            guard let row = row(at: index) else { continue }
            // Off-screen streaming rows are re-measured a few times a second,
            // not on every delta.
            if !visibleRange.contains(index), isStreaming(row), !wasPinned {
                deferred.insert(row.id)
                continue
            }
            deferred.remove(row.id)
            changed.insert(index)
            refreshCell(at: index, row: row)
        }
        if !changed.isEmpty {
            tableView.noteHeightOfRows(withIndexesChanged: changed)
        }
        NSAnimationContext.endGrouping()

        if !deferred.isEmpty { scheduleDeferred() }
        if wasPinned {
            scrollToBottom()
        } else if let anchor, let id = anchor.anchorId, let index = session?.displayIndex(of: id) {
            // Rows above the anchor can change height (a tool result landing);
            // keep what the user is reading where it was.
            scroll(toRow: index, offset: anchor.offset)
        }
    }

    private func isStreaming(_ row: TranscriptRow) -> Bool {
        switch row.content {
        case .assistant(let item), .reasoning(let item): return item.isStreaming
        default: return false
        }
    }

    private func refreshCell(at index: Int, row: TranscriptRow) {
        guard let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? RowCellView else { return }
        if cell.identifier?.rawValue != Self.cellIdentifier(for: row) {
            // The row needs another kind of cell now (a note moving into an
            // open group): let the table make it.
            tableView.reloadData(forRowIndexes: [index], columnIndexes: [0])
            return
        }
        cell.configure(row: row, render: render(row), tableWidth: width, expanded: isExpanded(row))
    }

    private func scheduleDeferred() {
        guard deferredTimer == nil else { return }
        deferredTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.deferredTimer = nil
                self.flushDeferred()
            }
        }
    }

    private func flushDeferred() {
        guard let session, !deferred.isEmpty else { return }
        let indices = IndexSet(deferred.compactMap { session.displayIndex(of: $0) })
        deferred = []
        let wasPinned = isAtBottom
        let anchor = wasPinned ? nil : captureMemory()
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        for index in indices {
            if let row = row(at: index) { refreshCell(at: index, row: row) }
        }
        tableView.noteHeightOfRows(withIndexesChanged: indices)
        NSAnimationContext.endGrouping()
        if wasPinned {
            scrollToBottom()
        } else if let anchor, let id = anchor.anchorId, let index = session.displayIndex(of: id) {
            scroll(toRow: index, offset: anchor.offset)
        }
    }

    /// Older rows were added above. Keeps the row that was at the top of the
    /// screen where it was. `memory` must be captured before the session's
    /// rows or `displayStart` changed.
    func insertAtTop(count: Int, changedIds: [String], memory: ScrollMemory?) {
        guard count > 0 || !changedIds.isEmpty, let session else { return }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        if count > 0 {
            tableView.insertRows(at: IndexSet(integersIn: 0..<count), withAnimation: [])
        }
        let changed = IndexSet(changedIds.compactMap { session.displayIndex(of: $0) })
        for index in changed {
            if let row = row(at: index) { refreshCell(at: index, row: row) }
        }
        if !changed.isEmpty { tableView.noteHeightOfRows(withIndexesChanged: changed) }
        NSAnimationContext.endGrouping()
        restore(memory)
        onPrepend?()
    }

    /// Reloads every row and puts the anchored row back where it was. Used
    /// when paging changed the order of rows the table already had.
    func reload(keeping memory: ScrollMemory?) {
        tableView.reloadData()
        restore(memory)
        onPrepend?()
    }

    private func restore(_ memory: ScrollMemory?) {
        guard let memory, let session else { return }
        if memory.pinned {
            scrollToBottom()
        } else if let id = memory.anchorId, let index = session.displayIndex(of: id) {
            scroll(toRow: index, offset: memory.offset)
        }
    }

    func toggleExpanded(rowId: String) {
        guard let session, let index = session.displayIndex(of: rowId), let row = row(at: index) else { return }
        if case .group(let group) = row.content {
            // Opening a group inserts its items under it and closing removes
            // them; `apply` keeps what's on screen where it is.
            session.setModelExpanded(rowId, !group.isExpanded)
            return
        }
        if session.expanded.contains(rowId) { session.expanded.remove(rowId) } else { session.expanded.insert(rowId) }
        let memory = captureMemory()
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        refreshCell(at: index, row: row)
        tableView.noteHeightOfRows(withIndexesChanged: [index])
        NSAnimationContext.endGrouping()
        if !memory.pinned, let id = memory.anchorId, let anchorIndex = session.displayIndex(of: id), anchorIndex != index {
            scroll(toRow: anchorIndex, offset: memory.offset)
        }
    }

    // MARK: Scrolling

    var isAtBottom: Bool {
        let clip = scrollView.contentView.bounds
        let documentHeight = tableView.frame.height
        return clip.maxY >= documentHeight + scrollView.contentInsets.bottom - 24
    }

    func scrollToBottom() {
        let count = rowCount
        guard count > 0 else { return }
        let bottom = tableView.rect(ofRow: count - 1).maxY + scrollView.contentInsets.bottom
        let y = max(-scrollView.contentInsets.top, bottom - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func scroll(toRow index: Int, offset: CGFloat) {
        let y = tableView.rect(ofRow: index).minY - offset
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func captureMemory() -> ScrollMemory {
        if isAtBottom { return ScrollMemory(pinned: true, anchorId: nil, offset: 0) }
        let clip = scrollView.contentView.bounds
        let index = max(0, tableView.row(at: NSPoint(x: 1, y: max(0, clip.minY + 1))))
        guard let row = row(at: index) else { return ScrollMemory(pinned: true, anchorId: nil, offset: 0) }
        return ScrollMemory(pinned: false, anchorId: row.id, offset: tableView.rect(ofRow: index).minY - clip.minY)
    }

    @objc private func boundsChanged() {
        updateVisibleSlices()
        loadOlderIfNearTop()
    }

    /// Tall rows on screen move their drawn slice along as the view scrolls.
    func updateVisibleSlices() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        for index in visible.location..<(visible.location + visible.length) {
            (tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? RowCellView)?.updateSlices()
        }
    }

    /// Pages older rows in when the view is within a couple of screens of
    /// the top. Also called after a page lands: a view sitting still at the
    /// top sends no bounds change, so it would otherwise wait forever.
    func loadOlderIfNearTop() {
        guard pagingEnabled, let session else { return }
        let clip = scrollView.contentView.bounds
        if clip.minY < clip.height * 2 {
            session.loadOlder()
        }
    }

    @objc private func frameChanged() {
        // A shorter view (the archived banner appearing, the composer
        // growing with an attachment or a long draft) keeps its top where it
        // was, which hid the newest rows of a thread that was pinned to the
        // bottom. Whether it was pinned is judged by the height it had.
        let clip = scrollView.contentView.bounds
        let wasPinned = lastClipHeight > 0 && abs(clip.height - lastClipHeight) >= 1
            && clip.minY + lastClipHeight >= tableView.frame.height + scrollView.contentInsets.bottom - 24
        lastClipHeight = clip.height
        let newWidth = currentTableWidth
        guard abs(newWidth - width) >= 1, let session else {
            if wasPinned { scrollToBottom() }
            return
        }
        let memory = wasPinned ? ScrollMemory(pinned: true, anchorId: nil, offset: 0) : captureMemory()
        let oldColumn = RowMetrics.column(tableWidth: width).width
        width = newWidth
        let visible = tableView.rows(in: tableView.visibleRect)
        let visibleRange = visible.location..<(visible.location + visible.length)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        if RowMetrics.column(tableWidth: newWidth).width == oldColumn {
            // The reading column only moved sideways (it's at its widest):
            // heights and renders are unchanged, just re-place what's on screen.
            for index in visibleRange {
                if let row = row(at: index) { refreshCell(at: index, row: row) }
            }
            NSAnimationContext.endGrouping()
            if memory.pinned { scrollToBottom() }
            return
        }
        let count = session.displayCount
        let measured: Range<Int>
        if count <= Self.syncRemeasureLimit {
            measured = 0..<count
        } else {
            // A long thread during a live resize (window edge or sidebar):
            // re-measuring all of it on every step blocked the main thread for
            // about 200 ms a step. Measure what's on screen and a margin now,
            // the rest off the main thread once the resizing stops.
            let margin = 60
            measured = max(0, visibleRange.lowerBound - margin)..<min(count, visibleRange.upperBound + margin)
        }
        Self.renders.prepare(measured.map { session.displayRow($0) }, expanded: session.expanded, width: width)
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: measured))
        for index in visibleRange {
            if let row = row(at: index) { refreshCell(at: index, row: row) }
        }
        NSAnimationContext.endGrouping()
        restore(memory)
        if measured.count < count { scheduleRemeasure() } else { remeasureTask?.cancel() }
    }

    private func scheduleRemeasure() {
        remeasureTask?.cancel()
        remeasureTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled, let session = self.session else { return }
            let width = self.width
            let rows = (0..<session.displayCount).map { session.displayRow($0) }
            let expanded = session.expanded
            await Task.detached(priority: .userInitiated) {
                TranscriptController.renders.prepare(rows, expanded: expanded, width: width)
            }.value
            guard !Task.isCancelled, self.session === session, self.width == width else { return }
            let memory = self.captureMemory()
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            self.tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<self.rowCount))
            NSAnimationContext.endGrouping()
            self.restore(memory)
        }
    }

    // MARK: Menu and actions

    func menu(forRow index: Int) -> NSMenu? {
        let menu = NSMenu()
        if let row = row(at: index), MarkdownExport.message(for: row) != nil {
            let copy = NSMenuItem(title: "Copy message", action: #selector(copyMessage(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = row.id
            menu.addItem(copy)
            if [.tool, .reasoning, .diff, .group].contains(row.kind) {
                let expanded = isExpanded(row)
                let toggle = NSMenuItem(title: expanded ? "Collapse" : "Expand", action: #selector(toggleFromMenu(_:)), keyEquivalent: "")
                toggle.target = self
                toggle.representedObject = row.id
                menu.addItem(toggle)
            }
        }
        let transcript = NSMenuItem(title: "Copy transcript as Markdown", action: #selector(copyTranscript), keyEquivalent: "")
        transcript.target = self
        menu.addItem(transcript)
        return menu
    }

    @objc private func copyMessage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let session, let index = session.displayIndex(of: id),
              let row = row(at: index), let text = MarkdownExport.message(for: row) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func toggleFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { toggleExpanded(rowId: id) }
    }

    @objc private func copyTranscript() {
        session?.copyTranscript()
    }

    func toggleChangedFile(turnId: String, path: String) {
        guard let session else { return }
        let key = ChangedFiles.expansionKey(turnId: turnId, path: path)
        session.setModelExpanded(key, !session.model.isExpanded(key))
    }

    func respond(approvalId: String, decision: ApprovalDecision, answers: [String: String]?, message: String?) {
        session?.respond(approvalId: approvalId, decision: decision, answers: answers, message: message)
    }

    func questionDraft(_ approvalId: String) -> [Int: Set<String>] { questionDrafts[approvalId] ?? [:] }

    func setQuestionDraft(_ approvalId: String, _ draft: [Int: Set<String>]) { questionDrafts[approvalId] = draft }
}

/// SwiftUI wrapper. The controller lives as long as the window's detail view,
/// and switching threads hands it a different session.
struct TranscriptView: NSViewRepresentable {
    let session: ThreadSession?
    let controller: TranscriptController

    func makeNSView(context: Context) -> NSScrollView {
        controller.scrollView
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        controller.show(session)
    }
}
