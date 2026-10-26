import Foundation
import Synchronization

/// Row versions are unique across all models and rebuilds, so a cache keyed
/// by (row id, version) can never return a stale render.
enum RowVersion {
    private static let counter = Atomic<Int>(0)

    static func next() -> Int {
        counter.wrappingAdd(1, ordering: .relaxed).newValue
    }
}

public struct PrependResult: Sendable, Equatable {
    /// Rows that appeared above the previous first row.
    public var added: Int
    /// Rows that were already there but changed (a tool call that met its
    /// result across the page boundary, say).
    public var changedIds: [String]
    /// True when the rows from `added` on are exactly the previous rows, in
    /// order, so a view can insert `added` rows at the top. False when a row
    /// moved above the old first row (a result on the newer page whose call
    /// is on the older one) or an older event's row landed below it; the
    /// view then has to reload instead.
    public var keepsOrder: Bool

    public init(added: Int, changedIds: [String], keepsOrder: Bool = true) {
        self.added = added
        self.changedIds = changedIds
        self.keepsOrder = keepsOrder
    }
}

/// What changed in the row list after applying events or opening a group.
/// `removed` are indices in the list before the change; `inserted` and
/// `updated` in the list after it. A table removes, then inserts, then
/// reloads.
public struct TranscriptChange: Sendable, Equatable {
    public var removed: IndexSet = []
    public var inserted: IndexSet = []
    public var updated: IndexSet = []
    /// Persisted events arrived with a seq gap; refetch after `lastSeq`.
    public var gapDetected = false

    public init(removed: IndexSet = [], inserted: IndexSet = [], updated: IndexSet = [], gapDetected: Bool = false) {
        self.removed = removed
        self.inserted = inserted
        self.updated = updated
        self.gapDetected = gapDetected
    }

    public var isEmpty: Bool { removed.isEmpty && inserted.isEmpty && updated.isEmpty }
}

/// Turns protocol events into transcript rows. Live events are applied
/// incrementally; loading an older page rebuilds from the stored events,
/// which is cheap (a few ms for thousands of rows) and keeps merging simple.
///
/// There are two lists. `items` has one row per thing the agent did (a
/// message, a tool call with its result, a thinking block). `rows` is what
/// the table shows: each run of work inside a turn folded into a group row
/// (with its items under it when it's open), plus the derived rows: the
/// "Edited 3 files" card before a turn's footer and the "Working for 12s"
/// line while a turn runs. Live changes only rebuild `rows` from the first
/// run they touch to the end, which is nearly always the current turn.
public struct TranscriptModel: Sendable {
    public private(set) var rows: [TranscriptRow] = []
    public private(set) var items: [TranscriptRow] = []
    /// Persisted events we hold, in seq order.
    public private(set) var events: [Event] = []
    public private(set) var firstSeq: Int = 0
    public private(set) var lastSeq: Int = 0
    /// Open groups (`g:` ids) and open files in changed-files cards
    /// (`ChangedFiles.expansionKey`). Kept across rebuilds.
    public private(set) var expanded: Set<String> = []
    /// The turn that has started and not finished, if any.
    public private(set) var openTurn: String?
    /// Text streamed by deltas for items with no persisted event yet.
    private var streaming: [String: (kind: RowKind, text: String)] = [:]
    private var itemIndex: [String: Int] = [:]
    private var index: [String: Int] = [:]
    /// For each row, the index of the first item it stands for. Never
    /// decreases, so the rows for items from `n` on are a binary search away.
    private var rowStarts: [Int] = []
    private var planRowForTurn: [String: String] = [:]
    private var turnStarts: [String: Date] = [:]
    private var completedTurns: Set<String> = []
    /// Edit and Write tool items per turn, in order, for the changes card.
    private var editsByTurn: [String: [String]] = [:]
    /// Approval and question rows still waiting, and their turn. A turn
    /// waiting on Mike isn't "working".
    private var pendingCards: [String: String] = [:]
    /// The first item changed in place, and the first item added, since
    /// `rows` was last brought up to date.
    private var dirtyUpdate: Int?
    private var dirtyInsert: Int?

    public init() {}

    public init(events: [Event]) {
        self.init()
        load(events: events)
    }

    public var hasOlderEvents: Bool { firstSeq > 1 }

    /// A row in `rows` (shown in the table).
    public func row(id: String) -> TranscriptRow? {
        index[id].map { rows[$0] }
    }

    public func indexOf(id: String) -> Int? { index[id] }

    /// An item, shown or folded away in a closed group.
    public func item(id: String) -> TranscriptRow? {
        itemIndex[id].map { items[$0] }
    }

    public func isExpanded(_ key: String) -> Bool { expanded.contains(key) }

    /// Replaces everything with this page of events (oldest first).
    public mutating func load(events newEvents: [Event], inProgress: [EventsPage.InProgress] = []) {
        events = newEvents.filter { !$0.isTransient }.sorted { $0.seq < $1.seq }
        firstSeq = events.first?.seq ?? 0
        lastSeq = events.last?.seq ?? 0
        streaming = [:]
        for item in inProgress {
            streaming[item.itemId] = (item.type == "reasoning" ? .reasoning : .assistant, item.text)
        }
        rebuild()
    }

    /// Adds an older page in front. Returns how many rows appeared above the
    /// previous first row, so the view can keep its scroll anchor.
    @discardableResult
    public mutating func prepend(olderEvents: [Event]) -> PrependResult {
        let older = olderEvents.filter { !$0.isTransient && (firstSeq == 0 || $0.seq < firstSeq) }
        guard !older.isEmpty else { return PrependResult(added: 0, changedIds: []) }
        let previousIds = rows.map(\.id)
        let previous = Dictionary(rows.map { ($0.id, $0.version) }, uniquingKeysWith: { first, _ in first })
        events = older.sorted { $0.seq < $1.seq } + events
        firstSeq = events.first?.seq ?? 0
        rebuild()
        let changed = rows.compactMap { row -> String? in
            guard let version = previous[row.id] else { return nil }
            return version == row.version ? nil : row.id
        }
        guard let previousFirstId = previousIds.first else {
            return PrependResult(added: 0, changedIds: changed, keepsOrder: true)
        }
        guard let newIndex = index[previousFirstId] else {
            // The old first row is gone: a group grew backwards over the page
            // boundary and took a new id, or swallowed a lone item. Anchor on
            // the first old row that's still there; the view reloads.
            let survivor = previousIds.first(where: { index[$0] != nil }).flatMap { index[$0] } ?? 0
            return PrependResult(added: survivor, changedIds: changed, keepsOrder: false)
        }
        let keepsOrder = rows.count - newIndex == previousIds.count
            && zip(rows[newIndex...], previousIds).allSatisfy { $0.id == $1 }
        return PrependResult(added: newIndex, changedIds: changed, keepsOrder: keepsOrder)
    }

    /// Drops all but the newest `count` persisted events (and their rows),
    /// keeping anything still streaming. Used when a long thread that was
    /// paged all the way up is left at the bottom; older pages come back
    /// through `prepend` if they're scrolled to again.
    public mutating func trim(keepingLast count: Int) {
        guard events.count > count else { return }
        events = Array(events.suffix(count))
        firstSeq = events.first?.seq ?? 0
        rebuild()
    }

    /// Applies live events (persisted or transient) and reports what changed.
    public mutating func apply(_ incoming: [Event]) -> TranscriptChange {
        var gap = false
        for event in incoming {
            if !event.isTransient {
                if event.seq <= lastSeq && lastSeq != 0 { continue }
                if lastSeq != 0 && event.seq > lastSeq + 1 { gap = true }
                events.append(event)
                if firstSeq == 0 { firstSeq = event.seq }
                lastSeq = event.seq
            }
            reduce(event)
        }
        var change = refreshRows()
        change.gapDetected = gap
        return change
    }

    /// Opens or closes a group (`g:` id) or a file in a changes card
    /// (`ChangedFiles.expansionKey`). Opening a group inserts its items under
    /// it; the group keeps its id, so its cached height survives.
    public mutating func setExpanded(_ key: String, _ open: Bool) -> TranscriptChange {
        guard expanded.contains(key) != open else { return TranscriptChange() }
        if open { expanded.insert(key) } else { expanded.remove(key) }
        let rowId = key.hasPrefix("cf:") ? String(key[..<(key.firstIndex(of: "|") ?? key.endIndex)]) : key
        guard let position = index[rowId] else { return TranscriptChange() }
        markUpdated(rowStarts[position])
        return refreshRows()
    }

    // MARK: - Items

    private mutating func rebuild() {
        // Items and rows whose content comes out the same keep their
        // version, so their cached renders and heights stay valid. The old
        // rows stay in place until the new ones are built: derived rows
        // (groups, cards) look their old versions up there.
        let previous = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        items = []
        itemIndex = [:]
        planRowForTurn = [:]
        turnStarts = [:]
        completedTurns = []
        editsByTurn = [:]
        pendingCards = [:]
        openTurn = nil
        items.reserveCapacity(events.count)
        // Set aside what's streaming now before replaying history: a
        // `turn.completed` in the history (any earlier turn) would otherwise
        // end it, and the live text would vanish.
        let pending = streaming
        streaming = [:]
        for event in events {
            reduce(event)
        }
        streaming = [:]
        // Re-add anything still streaming, unless the history now has its
        // persisted text. Reducing a delta puts it back in `streaming`.
        for (itemId, item) in pending.sorted(by: { $0.key < $1.key }) {
            if itemIndex[(item.kind == .reasoning ? "r:" : "a:") + itemId] != nil { continue }
            let deltaPayload: EventPayload = item.kind == .reasoning
                ? .reasoningDelta(itemId: itemId, text: item.text)
                : .assistantTextDelta(itemId: itemId, text: item.text)
            reduce(Event(seq: lastSeq, threadId: "", type: "", payload: deltaPayload))
        }
        for i in items.indices {
            if let old = previous[items[i].id], old.content == items[i].content {
                items[i].version = old.version
            }
        }
        // A turn whose start is on an older page (a long run of more than
        // a page of events) still counts as running if nothing in this page
        // finished it. A page that has the turn's message would have its
        // start too.
        if openTurn == nil, hasOlderEvents, let first = events.first?.turnId,
           events.last(where: { $0.turnId != nil })?.turnId == first, !completedTurns.contains(first),
           !events.contains(where: { event in
               if case .userMessage = event.payload { return event.turnId == first }
               return false
           }) {
            openTurn = first
        }
        let built = buildRows(from: 0)
        rows = built.rows
        rowStarts = built.starts
        index = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        dirtyUpdate = nil
        dirtyInsert = nil
    }

    private mutating func markUpdated(_ itemIndex: Int) {
        dirtyUpdate = min(dirtyUpdate ?? itemIndex, itemIndex)
    }

    private mutating func markInserted(_ itemIndex: Int) {
        dirtyInsert = min(dirtyInsert ?? itemIndex, itemIndex)
    }

    private mutating func append(_ row: TranscriptRow) {
        var row = row
        row.version = RowVersion.next()
        markInserted(items.count)
        itemIndex[row.id] = items.count
        items.append(row)
    }

    /// Inserts right after the item with `afterId` (used for a tool's images).
    private mutating func insert(_ row: TranscriptRow, after afterId: String) {
        guard let anchor = itemIndex[afterId], anchor < items.count - 1 else {
            append(row)
            return
        }
        var row = row
        row.version = RowVersion.next()
        items.insert(row, at: anchor + 1)
        for i in (anchor + 1)..<items.count { itemIndex[items[i].id] = i }
        markInserted(anchor + 1)
    }

    private mutating func update(_ id: String, _ body: (inout RowContent) -> Void) {
        guard let i = itemIndex[id] else { return }
        body(&items[i].content)
        items[i].version = RowVersion.next()
        markUpdated(i)
    }

    private mutating func noteEdit(_ itemId: String, turnId: String?) {
        let key = turnId ?? ""
        if editsByTurn[key]?.contains(itemId) != true { editsByTurn[key, default: []].append(itemId) }
    }

    static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    static let iso = Date.ISO8601FormatStyle()

    static func date(_ ts: String) -> Date? {
        guard !ts.isEmpty else { return nil }
        return (try? Date(ts, strategy: isoFractional)) ?? (try? Date(ts, strategy: iso))
    }

    private mutating func reduce(_ event: Event) {
        let seq = event.seq
        let turnId = event.turnId
        switch event.payload {
        case .userMessage(let text, let images):
            append(TranscriptRow(id: "u:\(seq)", seq: seq, turnId: turnId, content: .user(UserMessage(text: text, images: images))))

        case .assistantText(let itemId, let text):
            streaming[itemId] = nil
            let id = "a:\(itemId)"
            if itemIndex[id] != nil {
                update(id) { $0 = .assistant(TextItem(itemId: itemId, text: text)) }
            } else if !text.isEmpty {
                append(TranscriptRow(id: id, seq: seq, turnId: turnId, content: .assistant(TextItem(itemId: itemId, text: text))))
            }

        case .reasoning(let itemId, let text):
            streaming[itemId] = nil
            let id = "r:\(itemId)"
            if itemIndex[id] != nil {
                update(id) { $0 = .reasoning(TextItem(itemId: itemId, text: text)) }
            } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                append(TranscriptRow(id: id, seq: seq, turnId: turnId, content: .reasoning(TextItem(itemId: itemId, text: text))))
            }

        case .assistantTextDelta(let itemId, let text):
            let id = "a:\(itemId)"
            if itemIndex[id] != nil {
                update(id) { content in
                    if case .assistant(var item) = content {
                        item.text += text
                        item.isStreaming = true
                        content = .assistant(item)
                    }
                }
            } else {
                append(TranscriptRow(id: id, seq: seq, turnId: turnId, content: .assistant(TextItem(itemId: itemId, text: text, isStreaming: true))))
            }
            if case .assistant(let item)? = self.item(id: id)?.content { streaming[itemId] = (.assistant, item.text) }

        case .reasoningDelta(let itemId, let text):
            let id = "r:\(itemId)"
            if itemIndex[id] != nil {
                update(id) { content in
                    if case .reasoning(var item) = content {
                        item.text += text
                        item.isStreaming = true
                        content = .reasoning(item)
                    }
                }
            } else {
                append(TranscriptRow(id: id, seq: seq, turnId: turnId, content: .reasoning(TextItem(itemId: itemId, text: text, isStreaming: true))))
            }
            if case .reasoning(let item)? = self.item(id: id)?.content { streaming[itemId] = (.reasoning, item.text) }

        case .streamingText(let itemId, let isReasoning, let text):
            let kind: RowKind = isReasoning ? .reasoning : .assistant
            let id = (isReasoning ? "r:" : "a:") + itemId
            let make: (String) -> RowContent = { text in
                let item = TextItem(itemId: itemId, text: text, isStreaming: true)
                return isReasoning ? .reasoning(item) : .assistant(item)
            }
            if let i = itemIndex[id] {
                // A row with persisted text is final; leave it alone.
                switch items[i].content {
                case .assistant(let item) where item.isStreaming, .reasoning(let item) where item.isStreaming:
                    update(id) { $0 = make(text) }
                    streaming[itemId] = (kind, text)
                default:
                    break
                }
            } else if !text.isEmpty {
                append(TranscriptRow(id: id, seq: seq, turnId: turnId, content: make(text)))
                streaming[itemId] = (kind, text)
            }

        case .toolCall(let call):
            let id = "t:\(call.itemId)"
            if itemIndex[id] != nil {
                // The result arrived first (it was on a newer page); fill in the call.
                update(id) { content in
                    if case .tool(var tool) = content {
                        tool.call = call
                        content = .tool(tool)
                    }
                }
            } else {
                append(TranscriptRow(id: id, seq: seq, turnId: turnId, content: .tool(ToolItem(itemId: call.itemId, call: call))))
            }
            if DiffBuilder.isEditTool(call) { noteEdit(id, turnId: turnId) }

        case .toolResult(let result):
            let id = "t:\(result.itemId)"
            if itemIndex[id] != nil {
                update(id) { content in
                    if case .tool(var tool) = content {
                        tool.result = result
                        tool.liveOutput = ""
                        content = .tool(tool)
                    }
                }
            } else {
                append(TranscriptRow(id: id, seq: seq, turnId: turnId, content: .tool(ToolItem(itemId: result.itemId, result: result))))
            }
            if !result.images.isEmpty {
                let imagesId = "i:\(result.itemId)"
                if itemIndex[imagesId] != nil {
                    update(imagesId) { $0 = .images(itemId: result.itemId, images: result.images) }
                } else {
                    insert(TranscriptRow(id: imagesId, seq: seq, turnId: turnId, content: .images(itemId: result.itemId, images: result.images)), after: id)
                }
            }

        case .toolOutputDelta(let itemId, let text):
            update("t:\(itemId)") { content in
                if case .tool(var tool) = content, tool.result == nil {
                    tool.liveOutput += text
                    // Keep only the tail; it's a live peek, not the record.
                    if tool.liveOutput.utf8.count > 32_768 {
                        tool.liveOutput = String(tool.liveOutput.suffix(16_384))
                    }
                    content = .tool(tool)
                }
            }

        case .editDiff(let diff):
            // Nothing to attach a diff with no item to, and nothing to show
            // for one with no hunks.
            guard !diff.itemId.isEmpty, !diff.hunks.isEmpty else { break }
            let id = "t:\(diff.itemId)"
            if itemIndex[id] != nil {
                update(id) { content in
                    if case .tool(var tool) = content {
                        tool.diff = diff
                        content = .tool(tool)
                    }
                }
            } else {
                append(TranscriptRow(id: id, seq: seq, turnId: turnId, content: .tool(ToolItem(itemId: diff.itemId, diff: diff))))
            }
            noteEdit(id, turnId: turnId)

        case .approvalRequested(let request):
            let id = "ap:\(request.approvalId)"
            append(TranscriptRow(id: id, seq: seq, turnId: turnId, content: .approval(ApprovalItem(request: request))))
            pendingCards[id] = turnId ?? ""

        case .questionRequested(let request):
            let id = "q:\(request.approvalId)"
            append(TranscriptRow(id: id, seq: seq, turnId: turnId, content: .question(QuestionItem(request: request))))
            pendingCards[id] = turnId ?? ""

        case .approvalResolved(let resolution):
            for id in ["ap:\(resolution.approvalId)", "q:\(resolution.approvalId)"] where itemIndex[id] != nil {
                pendingCards[id] = nil
                update(id) { content in
                    switch content {
                    case .approval(var item):
                        item.resolution = resolution
                        content = .approval(item)
                    case .question(var item):
                        item.resolution = resolution
                        content = .question(item)
                    default:
                        break
                    }
                }
            }

        case .planUpdated(let entries):
            let key = turnId ?? "seq\(seq)"
            if let id = planRowForTurn[key], itemIndex[id] != nil {
                update(id) { $0 = .plan(entries) }
            } else {
                let id = "p:\(seq)"
                planRowForTurn[key] = id
                append(TranscriptRow(id: id, seq: seq, turnId: turnId, content: .plan(entries)))
            }

        case .turnStarted:
            let key = turnId ?? ""
            openTurn = key
            if let date = Self.date(event.ts) { turnStarts[key] = date }
            // Nothing new to show but the working line (and a live group).
            markInserted(items.count)

        case .turnCompleted(let completion):
            // A turn that ends leaves nothing streaming.
            finishStreaming()
            let key = completion.turnId.isEmpty ? (turnId ?? "seq\(seq)") : completion.turnId
            completedTurns.insert(key)
            if let turnId { completedTurns.insert(turnId) }
            if let open = openTurn, open == key || open == turnId || completion.turnId.isEmpty {
                openTurn = nil
            }
            let id = "f:\(key)"
            if itemIndex[id] != nil {
                update(id) { $0 = .footer(completion) }
            } else {
                append(TranscriptRow(id: id, seq: seq, turnId: turnId ?? completion.turnId, content: .footer(completion)))
            }

        case .systemNote(let text):
            append(TranscriptRow(id: "n:\(seq)", seq: seq, turnId: turnId, content: .note(text)))

        case .error(let message):
            append(TranscriptRow(id: "e:\(seq)", seq: seq, turnId: turnId, content: .error(message)))

        case .unknown:
            break
        }
    }

    private mutating func finishStreaming() {
        guard !streaming.isEmpty else { return }
        for (itemId, item) in streaming {
            let id = (item.kind == .reasoning ? "r:" : "a:") + itemId
            update(id) { content in
                switch content {
                case .assistant(var text):
                    text.isStreaming = false
                    content = .assistant(text)
                case .reasoning(var text):
                    text.isStreaming = false
                    content = .reasoning(text)
                default:
                    break
                }
            }
        }
        streaming = [:]
    }

    // MARK: - Rows

    /// Work that folds into groups: thinking, tool calls and system notes.
    /// Everything else (messages, cards, plans, images, errors, footers)
    /// ends a run and is never hidden in one.
    static func isWork(_ row: TranscriptRow) -> Bool {
        switch row.content {
        case .reasoning, .tool, .note: return true
        default: return false
        }
    }

    /// The first item of the run of work that item `i` is in (or `i`).
    private func runStart(_ i: Int) -> Int {
        guard i >= 0, i < items.count, Self.isWork(items[i]) else { return max(0, i) }
        let turn = items[i].turnId
        var j = i
        while j > 0, Self.isWork(items[j - 1]), items[j - 1].turnId == turn { j -= 1 }
        return j
    }

    /// Brings `rows` up to date with the items changed since the last call,
    /// rebuilding from the first run they touch, and says what changed.
    private mutating func refreshRows() -> TranscriptChange {
        guard dirtyUpdate != nil || dirtyInsert != nil else { return TranscriptChange() }
        var start = items.count
        // A changed item can change its group's summary.
        if let changed = dirtyUpdate { start = min(start, runStart(changed)) }
        // A new item can join the run before it, or end it (so it's no longer
        // the live group).
        if let added = dirtyInsert { start = min(start, runStart(added), runStart(added - 1)) }
        dirtyUpdate = nil
        dirtyInsert = nil

        var low = 0, high = rowStarts.count
        while low < high {
            let mid = (low + high) / 2
            if rowStarts[mid] < start { low = mid + 1 } else { high = mid }
        }
        let first = low
        let built = buildRows(from: start)

        var change = TranscriptChange()
        var kept = Set<String>(minimumCapacity: built.rows.count)
        for (offset, row) in built.rows.enumerated() {
            kept.insert(row.id)
            if let old = index[row.id], old >= first {
                let previous = rows[old]
                if previous.version != row.version || previous.inGroup != row.inGroup {
                    change.updated.insert(first + offset)
                }
            } else {
                change.inserted.insert(first + offset)
            }
        }
        for old in first..<rows.count where !kept.contains(rows[old].id) {
            change.removed.insert(old)
            index[rows[old].id] = nil
        }
        rows.replaceSubrange(first..., with: built.rows)
        rowStarts.replaceSubrange(first..., with: built.starts)
        for (offset, row) in built.rows.enumerated() { index[row.id] = first + offset }
        return change
    }

    /// The rows for items from `start` on (a run boundary), with the
    /// working line at the end while a turn runs.
    private func buildRows(from start: Int) -> (rows: [TranscriptRow], starts: [Int]) {
        var out: [TranscriptRow] = []
        var starts: [Int] = []
        out.reserveCapacity(max(0, items.count - start) + 2)
        starts.reserveCapacity(out.capacity)

        // Derived rows keep their old version while their content is the same.
        func derived(_ id: String, seq: Int, turnId: String?, _ content: RowContent) -> TranscriptRow {
            if let old = index[id], rows[old].content == content {
                return rows[old]
            }
            return TranscriptRow(id: id, version: RowVersion.next(), seq: seq, turnId: turnId, content: content)
        }

        var i = start
        while i < items.count {
            let item = items[i]
            if Self.isWork(item) {
                var end = i + 1
                while end < items.count, Self.isWork(items[end]), items[end].turnId == item.turnId { end += 1 }
                if end - i == 1 {
                    // A run of one is shown as itself.
                    out.append(item)
                    starts.append(i)
                } else {
                    let id = "g:" + item.id
                    let open = expanded.contains(id)
                    let live = end == items.count && openTurn != nil && (item.turnId ?? "") == openTurn
                    let group = WorkGroup(members: items[i..<end], isExpanded: open, isLive: live)
                    out.append(derived(id, seq: item.seq, turnId: item.turnId, .group(group)))
                    starts.append(i)
                    if open {
                        for k in i..<end {
                            var member = items[k]
                            member.inGroup = true
                            out.append(member)
                            starts.append(k)
                        }
                    }
                }
                i = end
            } else {
                if case .footer = item.content, let card = changedFiles(turn: item.turnId ?? "") {
                    out.append(derived("cf:" + card.turnId, seq: item.seq, turnId: item.turnId, .changes(card)))
                    starts.append(i)
                }
                out.append(item)
                starts.append(i)
                i += 1
            }
        }
        if let turn = openTurn, !pendingCards.values.contains(turn) {
            let status = WorkingStatus(turnId: turn, startedAt: turnStarts[turn])
            out.append(derived("w:" + turn, seq: lastSeq, turnId: turn, .working(status)))
            starts.append(items.count)
        }
        return (out, starts)
    }

    /// The files a turn changed, from its Edit and Write calls that didn't
    /// fail, each with its edits' line counts added up.
    private func changedFiles(turn: String) -> ChangedFiles? {
        guard let ids = editsByTurn[turn], !ids.isEmpty else { return nil }
        var order: [String] = []
        var files: [String: ChangedFile] = [:]
        for id in ids {
            guard let i = itemIndex[id], case .tool(let tool) = items[i].content, !tool.failed,
                  let diff = tool.effectiveDiff, !diff.hunks.isEmpty else { continue }
            let path = diff.path.isEmpty ? tool.title : diff.path
            let stats = DiffBuilder.stats(diff)
            if var file = files[path] {
                file.added += stats.added
                file.removed += stats.removed
                file.diffs.append(diff)
                files[path] = file
            } else {
                order.append(path)
                files[path] = ChangedFile(path: path, added: stats.added, removed: stats.removed, diffs: [diff],
                                          isExpanded: expanded.contains(ChangedFiles.expansionKey(turnId: turn, path: path)))
            }
        }
        guard !order.isEmpty else { return nil }
        return ChangedFiles(turnId: turn, files: order.compactMap { files[$0] })
    }
}
