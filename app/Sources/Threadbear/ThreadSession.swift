import AppKit
import Observation
import ThreadbearCore
import os

let perfLog = OSSignposter(subsystem: "com.mikerosoft.threadbear", category: "perf")

/// One open thread: its loaded events and rows, the subscription that keeps
/// them live, and the slice of rows the table shows (the newest ~200 at
/// first, growing as you scroll up).
@MainActor
@Observable
final class ThreadSession {
    enum LoadState: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    nonisolated static let initialRows = 200
    nonisolated static let pageRows = 200
    nonisolated static let eventsPage = 500

    let threadId: String
    /// Set for a sub-agent's transcript: read-only, read whole from
    /// `threads.subagent` (again for more while it runs), never subscribed.
    let subagentId: String?
    private(set) var state: LoadState = .idle
    /// The runner has no record of the sub-agent (-32006), so there's
    /// nothing to show rather than something that failed.
    private(set) var missing = false
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private(set) var feed = ThreadFeed()
    /// First model row the table shows.
    @ObservationIgnored private(set) var displayStart = 0
    @ObservationIgnored var expanded = Set<String>()
    @ObservationIgnored var scrollMemory: ScrollMemory?
    @ObservationIgnored weak var view: TranscriptController?
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored var lastUsed = Date()
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private var lastFlush: CFTimeInterval = 0
    @ObservationIgnored private var loadingOlder = false
    @ObservationIgnored private var rebuilding = false
    @ObservationIgnored private(set) var subscribed = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Perf counters.
    @ObservationIgnored var flushCount = 0
    @ObservationIgnored var flushTime: CFTimeInterval = 0
    @ObservationIgnored var olderFetchMs: [Double] = []
    @ObservationIgnored var olderMergeMs: [Double] = []
    @ObservationIgnored var onLoaded: (() -> Void)?
    @ObservationIgnored var onOlderLoaded: ((Int) -> Void)?

    init(threadId: String, subagentId: String? = nil, app: AppModel) {
        self.threadId = threadId
        self.subagentId = subagentId
        self.app = app
    }

    var model: TranscriptModel { feed.model }
    var displayCount: Int { max(0, feed.model.rows.count - displayStart) }
    func displayRow(_ index: Int) -> TranscriptRow { feed.model.rows[displayStart + index] }

    func displayIndex(of rowId: String) -> Int? {
        guard let index = feed.model.indexOf(id: rowId), index >= displayStart else { return nil }
        return index - displayStart
    }

    var hasMoreAbove: Bool { displayStart > 0 || feed.model.hasOlderEvents }

    // MARK: Loading

    /// Loads the newest page, renders the rows it will show off the main
    /// thread, then hands them to the view and subscribes.
    func open(width: CGFloat) {
        guard state == .idle || state.isFailed, loadTask == nil else { return }
        guard let client = app?.client else { return }
        if let subagentId {
            openSubagent(subagentId, client: client, width: width)
            return
        }
        state = .loading
        let threadId = threadId
        let expanded = expanded
        // File rows name folders from the thread's folder.
        let root = app?.threads[threadId]?.cwd
        let signpost = perfLog.beginInterval("open", id: perfLog.makeSignpostID(), "\(threadId)")
        loadTask = Task {
            defer { loadTask = nil }
            do {
                let debug = CommandLine.arguments.contains("--perf-debug")
                if debug { print(String(format: "    open %@: before fetch %.0f MB", threadId, memoryMB())) }
                let page = try await client.events(threadId: threadId, limit: Self.eventsPage)
                if debug { print(String(format: "    after fetch %.0f MB", memoryMB())) }
                // What the thread's summary says is running in the
                // background, for the line at the end.
                let background = app?.threads[threadId]?.background ?? []
                // Answers picked on the open card before it was last shown.
                let picks = app?.askPicks[threadId]
                let prepared = await Task.detached(priority: .userInitiated) { () -> (TranscriptModel, Int) in
                    var model = TranscriptModel(root: root)
                    if let picks { _ = model.setAskPicks(picks.asksSeq, picks.picks) }
                    model.load(events: page.events, inProgress: page.inProgress)
                    _ = model.setBackground(background)
                    if debug { print(String(format: "    after model %.0f MB", memoryMB())) }
                    let start = max(0, model.rows.count - Self.initialRows)
                    TranscriptController.renders.prepare(Array(model.rows[start...]), expanded: expanded, width: width)
                    if debug { print(String(format: "    after prepare %.0f MB", memoryMB())) }
                    return (model, start)
                }.value
                feed = ThreadFeed(model: prepared.0)
                displayStart = prepared.1
                state = .loaded
                perfLog.endInterval("open", signpost)
                view?.reloadAll()
                onLoaded?()
                await subscribe()
            } catch {
                perfLog.endInterval("open", signpost)
                AppLog.write("rpc", "couldn't load \(threadId): \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// A sub-agent's transcript: every event it has so far, in one read.
    private func openSubagent(_ subagentId: String, client: RPCClient, width: CGFloat) {
        state = .loading
        missing = false
        let threadId = threadId
        let expanded = expanded
        let root = app?.threads[threadId]?.cwd
        loadTask = Task {
            defer { loadTask = nil }
            do {
                let reply = try await client.subagent(threadId: threadId, subagentId: subagentId)
                let live = (app?.threads[threadId]?.subagents.first { $0.id == subagentId } ?? reply.subagent).flatMap { $0.isRunning ? $0.startedAt : nil }
                let prepared = await Task.detached(priority: .userInitiated) { () -> (TranscriptModel, Int) in
                    var model = TranscriptModel(root: root)
                    model.load(events: reply.events, inProgress: [])
                    if let live { _ = model.setLiveTurn("", startedAt: live) }
                    let start = max(0, model.rows.count - Self.initialRows)
                    TranscriptController.renders.prepare(Array(model.rows[start...]), expanded: expanded, width: width)
                    return (model, start)
                }.value
                feed = ThreadFeed(model: prepared.0)
                displayStart = prepared.1
                state = .loaded
                view?.reloadAll()
                onLoaded?()
            } catch RPCError.server(let code, _) where code == RPCError.subagentNotFound {
                missing = true
                state = .failed("There's no record of what this sub-agent did.")
            } catch {
                AppLog.write("rpc", "couldn't load sub-agent \(subagentId) of \(threadId): \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Reads a running sub-agent's transcript again and adds what's new, as
    /// a live update would. The runner numbers its events from 1 on every
    /// read, and the CLI only ever adds to its record, so new ones are the
    /// ones past the last seq shown.
    func refreshSubagent() {
        guard let subagentId, state == .loaded, !refreshing, let client = app?.client else { return }
        refreshing = true
        let threadId = threadId
        Task {
            defer { refreshing = false }
            guard let reply = try? await client.subagent(threadId: threadId, subagentId: subagentId) else { return }
            let fresh = reply.events.filter { $0.seq > feed.acceptedSeq }
            if !fresh.isEmpty {
                handle(feed.catchUp(fresh))
                flush()
            }
            // Its working line goes once it has finished.
            let subagent = app?.threads[threadId]?.subagents.first { $0.id == subagentId } ?? reply.subagent
            let running = subagent?.isRunning ?? false
            guard !rebuilding, (feed.model.openTurn != nil) != running else { return }
            let oldStart = displayStart
            let change = feed.setLiveTurn(running ? "" : nil, startedAt: subagent?.startedAt)
            if !change.isEmpty { show(change, oldStart: oldStart) }
        }
    }

    func subscribe() async {
        guard subagentId == nil, let client = app?.client, state == .loaded else { return }
        feed.beginSubscribe()
        do {
            let reply = try await client.subscribe(threadId: threadId, afterSeq: feed.acceptedSeq)
            subscribed = true
            handle(feed.finishSubscribe(reply.events, inProgress: reply.inProgress))
        } catch {
            // The next connection subscribes again from the same seq.
            feed.catchUpFailed()
        }
    }

    /// The connection dropped; the next connection re-subscribes from the
    /// last seq we have and the runner replays the gap.
    func connectionLost() {
        subscribed = false
    }

    func unsubscribe() {
        guard subscribed, let client = app?.client else { return }
        subscribed = false
        let threadId = threadId
        Task { try? await client.unsubscribe(threadId: threadId) }
    }

    // MARK: Live events

    func receive(_ event: Event) {
        guard state == .loaded else { return }
        handle(feed.receive(event))
    }

    private func handle(_ action: ThreadFeed.Action) {
        switch action {
        case .none:
            break
        case .scheduleFlush:
            scheduleFlush()
        case .needsCatchUp(let afterSeq):
            // A sub-agent's events come whole from threads.subagent; the
            // next read fills any gap.
            if subagentId != nil {
                feed.catchUpFailed()
                return
            }
            guard let client = app?.client else {
                feed.catchUpFailed()
                return
            }
            let threadId = threadId
            // A catch-up that didn't fill the gap waits a little before the
            // next try (and the feed gives up on the hole after a few), so
            // one bad page can't spin the app.
            let stalls = feed.stalledCatchUps
            Task {
                if stalls > 0 { try? await Task.sleep(for: .milliseconds(250 << min(stalls, 3))) }
                do {
                    let page = try await client.events(threadId: threadId, afterSeq: afterSeq, limit: 2000)
                    handle(feed.catchUp(page.events))
                } catch {
                    feed.catchUpFailed()
                }
            }
        }
    }

    /// Coalesces updates to at most 30 a second.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        let wait = max(0, 1.0 / 30 - (CACurrentMediaTime() - lastFlush))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    func flush() {
        flushScheduled = false
        // An older page is being merged off the main thread; wait for it.
        if rebuilding {
            scheduleFlush()
            return
        }
        let started = CACurrentMediaTime()
        lastFlush = started
        let oldStart = displayStart
        let change = feed.flush()
        guard !change.isEmpty else { return }
        show(change, oldStart: oldStart)
        flushCount += 1
        flushTime += CACurrentMediaTime() - started
    }

    /// The thread's summary changed what's running in the background. The
    /// line at the end comes, goes or changes in place, like a live update.
    func setBackground(_ tasks: [BackgroundTask]) {
        guard state == .loaded, !rebuilding else { return }
        let oldStart = displayStart
        let change = feed.setBackground(tasks)
        guard !change.isEmpty else { return }
        show(change, oldStart: oldStart)
    }

    /// Shows the answers picked on the card from `seq` as picked. Before
    /// the transcript has loaded, the model is built with them instead
    /// (AppModel.askPicks is read when it is).
    func setAskPicks(seq: Int, picks: [Int: Int]) {
        guard state == .loaded, !rebuilding else { return }
        let oldStart = displayStart
        let change = feed.setAskPicks(seq, picks)
        guard !change.isEmpty else { return }
        show(change, oldStart: oldStart)
    }

    /// Opens or closes a work group or a changed file. Its rows are
    /// inserted or removed in place, like a live update.
    func setModelExpanded(_ key: String, _ open: Bool) {
        guard state == .loaded, !rebuilding else { return }
        let oldStart = displayStart
        let change = feed.setExpanded(key, open)
        guard !change.isEmpty else { return }
        show(change, oldStart: oldStart)
    }

    /// Moves `displayStart` past rows that came or went above it and hands
    /// the table the rest in its own indices. Removed rows are indices in
    /// the old row list; inserted and updated ones in the new list.
    private func show(_ change: TranscriptChange, oldStart: Int) {
        var start = oldStart - change.removed.count(in: 0..<oldStart)
        for index in change.inserted {
            guard index < start else { break }
            start += 1
        }
        displayStart = min(start, feed.model.rows.count)
        let removed = IndexSet(change.removed.compactMap { $0 >= oldStart ? $0 - oldStart : nil })
        let inserted = IndexSet(change.inserted.compactMap { $0 >= start ? $0 - start : nil })
        let updated = IndexSet(change.updated.compactMap { $0 >= start ? $0 - start : nil })
        view?.apply(removed: removed, inserted: inserted, updated: updated)
    }

    // MARK: Older rows

    /// Shows up to 200 more rows above, fetching an older page first if the
    /// loaded events are used up.
    func loadOlder() {
        guard state == .loaded, !loadingOlder, hasMoreAbove else { return }
        loadingOlder = true
        let width = view?.width ?? 800
        let expanded = expanded
        if displayStart > 0 {
            let newStart = max(0, displayStart - Self.pageRows)
            let rows = Array(feed.model.rows[newStart..<displayStart])
            Task {
                await Task.detached(priority: .userInitiated) {
                    TranscriptController.renders.prepare(rows, expanded: expanded, width: width)
                }.value
                // Where the reader is, read while the table and `displayStart`
                // still agree (a flush may have landed during the await).
                let memory = view?.captureMemory()
                reveal(to: newStart, changedIds: [], memory: memory)
            }
            return
        }
        guard subagentId == nil, let client = app?.client else {
            loadingOlder = false
            return
        }
        let threadId = threadId
        let before = feed.model.firstSeq
        Task {
            do {
                let fetchStart = CACurrentMediaTime()
                let page = try await client.events(threadId: threadId, beforeSeq: before, limit: Self.eventsPage)
                olderFetchMs.append((CACurrentMediaTime() - fetchStart) * 1000)
                let mergeStart = CACurrentMediaTime()
                // Merge off the main thread; hold flushes until it's swapped in.
                rebuilding = true
                var copy = feed.model
                let result = await Task.detached(priority: .userInitiated) { () -> (TranscriptModel, PrependResult) in
                    let result = copy.prepend(olderEvents: page.events)
                    let newStart = max(0, result.added - Self.pageRows)
                    TranscriptController.renders.prepare(Array(copy.rows[newStart..<result.added]), expanded: expanded, width: width)
                    return (copy, result)
                }.value
                // Read the scroll anchor before the model changes under the
                // table: afterwards a table row index no longer names the
                // row that's on screen, and the "restored" anchor would be
                // an older row (the review saw jumps of 6,000 to 33,000 pt).
                let memory = view?.captureMemory()
                feed.replaceModel(result.0)
                rebuilding = false
                olderMergeMs.append((CACurrentMediaTime() - mergeStart) * 1000)
                let newStart = max(0, result.1.added - Self.pageRows)
                if result.1.keepsOrder {
                    // The rows we showed are now `added` rows further down.
                    displayStart = result.1.added
                    reveal(to: newStart, changedIds: result.1.changedIds, memory: memory)
                } else {
                    // A row moved across the old first row (a result whose
                    // call was on the older page), so the table can't just
                    // gain rows at the top. Reload it around the anchor.
                    displayStart = newStart
                    view?.reload(keeping: memory)
                    finishOlder(count: result.1.added - newStart)
                }
            } catch {
                rebuilding = false
                loadingOlder = false
            }
        }
    }

    private func reveal(to newStart: Int, changedIds: [String], memory: ScrollMemory?) {
        let count = displayStart - newStart
        displayStart = newStart
        view?.insertAtTop(count: count, changedIds: changedIds, memory: memory)
        finishOlder(count: count)
    }

    private func finishOlder(count: Int) {
        loadingOlder = false
        onOlderLoaded?(count)
        view?.loadOlderIfNearTop()
    }

    /// Lets go of older pages when the thread is left scrolled to the
    /// bottom, so a long thread that was paged all the way up costs no more
    /// than a fresh open. Only while it isn't on screen.
    func trimToNewest() {
        guard state == .loaded, !loadingOlder, !rebuilding, view == nil,
              feed.model.events.count > Self.eventsPage + Self.eventsPage / 2 else { return }
        var model = feed.model
        model.trim(keepingLast: Self.eventsPage)
        feed.replaceModel(model)
        displayStart = max(0, model.rows.count - Self.initialRows)
    }

    // MARK: Actions

    /// Ticks an ask on the open card. The runner's thread.updated and
    /// asks.ticked event bring the change back.
    func tickAsk(asksSeq: Int, index: Int, ticked: Bool) {
        guard let client = app?.client else { return }
        let threadId = threadId
        Task {
            do {
                _ = try await client.tickAsk(threadId: threadId, asksSeq: asksSeq, index: index, ticked: ticked)
            } catch {
                app?.show(error)
            }
        }
    }

    func respond(approvalId: String, decision: ApprovalDecision, answers: [String: String]?, message: String?) {
        guard let client = app?.client else { return }
        let threadId = threadId
        Task {
            do {
                try await client.respond(threadId: threadId, approvalId: approvalId, decision: decision, message: message, answers: answers)
            } catch {
                app?.show(error)
            }
        }
    }

    /// Copies the whole thread, fetching any older pages first.
    func copyTranscript() {
        guard let client = app?.client else { return }
        let threadId = threadId
        let title = app?.threads[threadId]?.title ?? ""
        var events = feed.model.events
        Task {
            var first = events.first?.seq ?? 0
            while first > 1 {
                guard let page = try? await client.events(threadId: threadId, beforeSeq: first, limit: 2000), !page.events.isEmpty else { break }
                events = page.events + events
                first = page.events.first?.seq ?? 1
            }
            let all = events
            // Items, not rows: nothing folded in a group is left out.
            let text = await Task.detached { MarkdownExport.transcript(title: title, rows: TranscriptModel(events: all).items) }.value
            app?.copyToPasteboard(text)
        }
    }
}

extension ThreadSession.LoadState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
