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

/// What changed in the row list after applying events, in terms of the new
/// row array. The table applies inserts first, then reloads.
public struct TranscriptChange: Sendable, Equatable {
    public var inserted: IndexSet = []
    public var updated: IndexSet = []
    /// Persisted events arrived with a seq gap; refetch after `lastSeq`.
    public var gapDetected = false

    public init(inserted: IndexSet = [], updated: IndexSet = [], gapDetected: Bool = false) {
        self.inserted = inserted
        self.updated = updated
        self.gapDetected = gapDetected
    }

    public var isEmpty: Bool { inserted.isEmpty && updated.isEmpty }
}

/// Turns protocol events into transcript rows. Live events are applied
/// incrementally; loading an older page rebuilds from the stored events,
/// which is cheap (a few ms for thousands of rows) and keeps merging simple.
public struct TranscriptModel: Sendable {
    public private(set) var rows: [TranscriptRow] = []
    /// Persisted events we hold, in seq order.
    public private(set) var events: [Event] = []
    public private(set) var firstSeq: Int = 0
    public private(set) var lastSeq: Int = 0
    /// Text streamed by deltas for items with no persisted event yet.
    private var streaming: [String: (kind: RowKind, text: String)] = [:]
    private var index: [String: Int] = [:]
    private var planRowForTurn: [String: String] = [:]

    public init() {}

    public init(events: [Event]) {
        self.init()
        load(events: events)
    }

    public var hasOlderEvents: Bool { firstSeq > 1 }

    public func row(id: String) -> TranscriptRow? {
        index[id].map { rows[$0] }
    }

    public func indexOf(id: String) -> Int? { index[id] }

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
        guard let previousFirstId = previousIds.first, let newIndex = index[previousFirstId] else {
            return PrependResult(added: 0, changedIds: changed, keepsOrder: previousIds.isEmpty)
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
        var inserted: [String] = []
        var updated = Set<String>()
        var gap = false
        for event in incoming {
            if !event.isTransient {
                if event.seq <= lastSeq && lastSeq != 0 { continue }
                if lastSeq != 0 && event.seq > lastSeq + 1 { gap = true }
                events.append(event)
                if firstSeq == 0 { firstSeq = event.seq }
                lastSeq = event.seq
            }
            reduce(event, inserted: &inserted, updated: &updated)
        }
        var change = TranscriptChange(gapDetected: gap)
        let insertedSet = Set(inserted)
        for id in inserted { if let i = index[id] { change.inserted.insert(i) } }
        for id in updated where !insertedSet.contains(id) {
            if let i = index[id] { change.updated.insert(i) }
        }
        return change
    }

    // MARK: - Reduction

    private mutating func rebuild() {
        // Rows whose content comes out the same keep their version, so their
        // cached renders and heights stay valid.
        let previous = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        defer {
            for i in rows.indices {
                if let old = previous[rows[i].id], old.content == rows[i].content {
                    rows[i].version = old.version
                }
            }
        }
        rows = []
        index = [:]
        planRowForTurn = [:]
        rows.reserveCapacity(events.count)
        var inserted: [String] = []
        var updated = Set<String>()
        // Set aside what's streaming now before replaying history: a
        // `turn.completed` in the history (any earlier turn) would otherwise
        // end it, and the live text would vanish.
        let pending = streaming
        streaming = [:]
        for event in events {
            reduce(event, inserted: &inserted, updated: &updated)
        }
        streaming = [:]
        // Re-add anything still streaming, unless the history now has its
        // persisted text. Reducing a delta puts it back in `streaming`.
        for (itemId, item) in pending.sorted(by: { $0.key < $1.key }) {
            if index[(item.kind == .reasoning ? "r:" : "a:") + itemId] != nil { continue }
            let deltaPayload: EventPayload = item.kind == .reasoning
                ? .reasoningDelta(itemId: itemId, text: item.text)
                : .assistantTextDelta(itemId: itemId, text: item.text)
            reduce(Event(seq: lastSeq, threadId: "", type: "", payload: deltaPayload), inserted: &inserted, updated: &updated)
        }
    }

    private mutating func append(_ row: TranscriptRow, inserted: inout [String]) {
        var row = row
        row.version = RowVersion.next()
        index[row.id] = rows.count
        rows.append(row)
        inserted.append(row.id)
    }

    /// Inserts right after the row with `afterId` (used for a tool's images).
    private mutating func insert(_ row: TranscriptRow, after afterId: String, inserted: inout [String]) {
        guard let anchor = index[afterId], anchor < rows.count - 1 else {
            append(row, inserted: &inserted)
            return
        }
        var row = row
        row.version = RowVersion.next()
        rows.insert(row, at: anchor + 1)
        for i in (anchor + 1)..<rows.count { index[rows[i].id] = i }
        inserted.append(row.id)
    }

    private mutating func update(_ id: String, updated: inout Set<String>, _ body: (inout RowContent) -> Void) {
        guard let i = index[id] else { return }
        body(&rows[i].content)
        rows[i].version = RowVersion.next()
        updated.insert(id)
    }

    private mutating func reduce(_ event: Event, inserted: inout [String], updated: inout Set<String>) {
        let seq = event.seq
        let turnId = event.turnId
        switch event.payload {
        case .userMessage(let text, let images):
            append(TranscriptRow(id: "u:\(seq)", seq: seq, turnId: turnId, content: .user(UserMessage(text: text, images: images))), inserted: &inserted)

        case .assistantText(let itemId, let text):
            streaming[itemId] = nil
            let id = "a:\(itemId)"
            if index[id] != nil {
                update(id, updated: &updated) { $0 = .assistant(TextItem(itemId: itemId, text: text)) }
            } else if !text.isEmpty {
                append(TranscriptRow(id: id, seq: seq, turnId: turnId, content: .assistant(TextItem(itemId: itemId, text: text))), inserted: &inserted)
            }

        case .reasoning(let itemId, let text):
            streaming[itemId] = nil
            let id = "r:\(itemId)"
            if index[id] != nil {
                update(id, updated: &updated) { $0 = .reasoning(TextItem(itemId: itemId, text: text)) }
            } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                append(TranscriptRow(id: id, seq: seq, turnId: turnId, content: .reasoning(TextItem(itemId: itemId, text: text))), inserted: &inserted)
            }

        case .assistantTextDelta(let itemId, let text):
            let id = "a:\(itemId)"
            if index[id] != nil {
                update(id, updated: &updated) { content in
                    if case .assistant(var item) = content {
                        item.text += text
                        item.isStreaming = true
                        content = .assistant(item)
                    }
                }
            } else {
                append(TranscriptRow(id: id, seq: seq, turnId: turnId, content: .assistant(TextItem(itemId: itemId, text: text, isStreaming: true))), inserted: &inserted)
            }
            if case .assistant(let item)? = row(id: id)?.content { streaming[itemId] = (.assistant, item.text) }

        case .reasoningDelta(let itemId, let text):
            let id = "r:\(itemId)"
            if index[id] != nil {
                update(id, updated: &updated) { content in
                    if case .reasoning(var item) = content {
                        item.text += text
                        item.isStreaming = true
                        content = .reasoning(item)
                    }
                }
            } else {
                append(TranscriptRow(id: id, seq: seq, turnId: turnId, content: .reasoning(TextItem(itemId: itemId, text: text, isStreaming: true))), inserted: &inserted)
            }
            if case .reasoning(let item)? = row(id: id)?.content { streaming[itemId] = (.reasoning, item.text) }

        case .streamingText(let itemId, let isReasoning, let text):
            let kind: RowKind = isReasoning ? .reasoning : .assistant
            let id = (isReasoning ? "r:" : "a:") + itemId
            let make: (String) -> RowContent = { text in
                let item = TextItem(itemId: itemId, text: text, isStreaming: true)
                return isReasoning ? .reasoning(item) : .assistant(item)
            }
            if let i = index[id] {
                // A row with persisted text is final; leave it alone.
                switch rows[i].content {
                case .assistant(let item) where item.isStreaming, .reasoning(let item) where item.isStreaming:
                    update(id, updated: &updated) { $0 = make(text) }
                    streaming[itemId] = (kind, text)
                default:
                    break
                }
            } else if !text.isEmpty {
                append(TranscriptRow(id: id, seq: seq, turnId: turnId, content: make(text)), inserted: &inserted)
                streaming[itemId] = (kind, text)
            }

        case .toolCall(let call):
            let id = "t:\(call.itemId)"
            if index[id] != nil {
                // The result arrived first (it was on a newer page); fill in the call.
                update(id, updated: &updated) { content in
                    if case .tool(var tool) = content {
                        tool.call = call
                        content = .tool(tool)
                    }
                }
            } else {
                append(TranscriptRow(id: id, seq: seq, turnId: turnId, content: .tool(ToolItem(itemId: call.itemId, call: call))), inserted: &inserted)
            }

        case .toolResult(let result):
            let id = "t:\(result.itemId)"
            if index[id] != nil {
                update(id, updated: &updated) { content in
                    if case .tool(var tool) = content {
                        tool.result = result
                        tool.liveOutput = ""
                        content = .tool(tool)
                    }
                }
            } else {
                append(TranscriptRow(id: id, seq: seq, turnId: turnId, content: .tool(ToolItem(itemId: result.itemId, result: result))), inserted: &inserted)
            }
            if !result.images.isEmpty {
                let imagesId = "i:\(result.itemId)"
                if index[imagesId] != nil {
                    update(imagesId, updated: &updated) { $0 = .images(itemId: result.itemId, images: result.images) }
                } else {
                    insert(TranscriptRow(id: imagesId, seq: seq, turnId: turnId, content: .images(itemId: result.itemId, images: result.images)), after: id, inserted: &inserted)
                }
            }

        case .toolOutputDelta(let itemId, let text):
            update("t:\(itemId)", updated: &updated) { content in
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
            if index[id] != nil {
                update(id, updated: &updated) { content in
                    if case .tool(var tool) = content {
                        tool.diff = diff
                        content = .tool(tool)
                    }
                }
            } else {
                append(TranscriptRow(id: id, seq: seq, turnId: turnId, content: .tool(ToolItem(itemId: diff.itemId, diff: diff))), inserted: &inserted)
            }

        case .approvalRequested(let request):
            append(TranscriptRow(id: "ap:\(request.approvalId)", seq: seq, turnId: turnId, content: .approval(ApprovalItem(request: request))), inserted: &inserted)

        case .questionRequested(let request):
            append(TranscriptRow(id: "q:\(request.approvalId)", seq: seq, turnId: turnId, content: .question(QuestionItem(request: request))), inserted: &inserted)

        case .approvalResolved(let resolution):
            for id in ["ap:\(resolution.approvalId)", "q:\(resolution.approvalId)"] where index[id] != nil {
                update(id, updated: &updated) { content in
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
            if let id = planRowForTurn[key], index[id] != nil {
                update(id, updated: &updated) { $0 = .plan(entries) }
            } else {
                let id = "p:\(seq)"
                planRowForTurn[key] = id
                append(TranscriptRow(id: id, seq: seq, turnId: turnId, content: .plan(entries)), inserted: &inserted)
            }

        case .turnStarted:
            break

        case .turnCompleted(let completion):
            // A turn that ends leaves nothing streaming.
            finishStreaming(updated: &updated)
            let key = completion.turnId.isEmpty ? (turnId ?? "seq\(seq)") : completion.turnId
            let id = "f:\(key)"
            if index[id] != nil {
                update(id, updated: &updated) { $0 = .footer(completion) }
            } else {
                append(TranscriptRow(id: id, seq: seq, turnId: turnId ?? completion.turnId, content: .footer(completion)), inserted: &inserted)
            }

        case .systemNote(let text):
            append(TranscriptRow(id: "n:\(seq)", seq: seq, turnId: turnId, content: .note(text)), inserted: &inserted)

        case .error(let message):
            append(TranscriptRow(id: "e:\(seq)", seq: seq, turnId: turnId, content: .error(message)), inserted: &inserted)

        case .unknown:
            break
        }
    }

    private mutating func finishStreaming(updated: inout Set<String>) {
        guard !streaming.isEmpty else { return }
        for (itemId, item) in streaming {
            let id = (item.kind == .reasoning ? "r:" : "a:") + itemId
            update(id, updated: &updated) { content in
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
}
