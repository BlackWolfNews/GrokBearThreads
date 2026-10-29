import Foundation

/// A sub-agent's row under its thread in the sidebar.
public struct SubagentRow: Sendable, Equatable, Identifiable {
    public var subagent: Subagent
    /// 0 under the thread, 1 under another sub-agent shown above it.
    public var depth: Int
    public var id: String { subagent.id }

    public init(subagent: Subagent, depth: Int) {
        self.subagent = subagent
        self.depth = depth
    }
}

/// Which of a thread's sub-agents the sidebar shows under it, and what
/// their rows say. The rules are here so they're tested, not in the view.
public enum SubagentRows {
    /// A finished sub-agent stays under its thread this long, so one that
    /// has just reported back can still be clicked.
    public static let recent: TimeInterval = 10 * 60
    /// Most finished ones shown under the selected thread (the newest).
    /// The runner keeps 20; twenty rows under one thread swamped the list.
    public static let maxFinishedWhenSelected = 10

    /// Running ones, ones that finished in the last 10 minutes, and for the
    /// selected thread its finished ones too. A selected sub-agent is always
    /// shown. A nested one sits under its parent when the parent is shown,
    /// otherwise at the top level; the order is the runner's (oldest first).
    /// `finishedShown` false (Inbox) leaves finished ones out unless
    /// selected: an Inbox thread's work is done, and its finished sub-agents
    /// under it were clutter (Mike asked 28 Oct).
    public static func visible(_ thread: ThreadSummary, threadSelected: Bool, selectedSubagent: String?, now: Date, finishedShown: Bool = true) -> [SubagentRow] {
        let all = thread.subagents
        guard !all.isEmpty else { return [] }
        var shown = Set<String>()
        for subagent in all where subagent.isRunning || subagent.id == selectedSubagent || (finishedShown && endedRecently(subagent, now: now)) {
            shown.insert(subagent.id)
        }
        if threadSelected && finishedShown {
            let finished = all.filter { !$0.isRunning && !shown.contains($0.id) }
            for subagent in finished.suffix(max(0, maxFinishedWhenSelected - finishedCount(all, shown))) {
                shown.insert(subagent.id)
            }
        }
        let kept = all.filter { shown.contains($0.id) }
        let ids = Set(kept.map(\.id))
        // Children grouped under their shown parent, in list order.
        var children: [String: [Subagent]] = [:]
        var roots: [Subagent] = []
        for subagent in kept {
            if let parent = subagent.parentId, parent != subagent.id, ids.contains(parent) {
                children[parent, default: []].append(subagent)
            } else {
                roots.append(subagent)
            }
        }
        var rows: [SubagentRow] = []
        var placed = Set<String>()
        func place(_ subagent: Subagent, depth: Int) {
            guard placed.insert(subagent.id).inserted else { return }
            rows.append(SubagentRow(subagent: subagent, depth: depth))
            for child in children[subagent.id] ?? [] { place(child, depth: min(depth + 1, 2)) }
        }
        for root in roots { place(root, depth: 0) }
        // A parent loop (a starts b starts a) leaves both out of roots.
        for subagent in kept where !placed.contains(subagent.id) { place(subagent, depth: 0) }
        return rows
    }

    /// All of a thread's sub-agents for its Highlights: running ones first,
    /// then the rest newest first, like the other groups there.
    public static func highlights(_ thread: ThreadSummary) -> [Subagent] {
        let newest = Array(thread.subagents.reversed())
        return newest.filter(\.isRunning) + newest.filter { !$0.isRunning }
    }

    private static func finishedCount(_ all: [Subagent], _ shown: Set<String>) -> Int {
        all.reduce(0) { $0 + (!$1.isRunning && shown.contains($1.id) ? 1 : 0) }
    }

    static func endedRecently(_ subagent: Subagent, now: Date) -> Bool {
        guard !subagent.isRunning, let ended = subagent.endedAt else { return false }
        return now.timeIntervalSince(ended) < recent
    }

    /// The quieter second line: what it's doing while it runs, what it
    /// reported once it's done.
    public static func detail(_ subagent: Subagent) -> String {
        switch subagent.status {
        case .running:
            let activity = subagent.activity.map(PreviewText.plain) ?? ""
            return activity.isEmpty ? "Starting" : activity
        case .completed:
            let summary = subagent.summary.map(PreviewText.plain) ?? ""
            return summary.isEmpty ? "Done" : summary
        case .failed:
            let summary = subagent.summary.map(PreviewText.plain) ?? ""
            return summary.isEmpty ? "Failed" : "Failed: " + summary
        case .stopped:
            return "Stopped"
        }
    }

    /// How long it ran, or has run so far: "53s", "4m".
    public static func duration(_ subagent: Subagent, now: Date) -> String {
        ThreadRowLook.workingLabel(since: subagent.startedAt, now: subagent.endedAt ?? now)
    }

    /// The row's title: its brief's title, or its type for one with none.
    public static func title(_ subagent: Subagent) -> String {
        let text = subagent.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        return subagent.agentType.map { "\($0) sub-agent" } ?? "Sub-agent"
    }

    /// The status in words, for the detail header and tooltips.
    public static func statusText(_ subagent: Subagent) -> String {
        switch subagent.status {
        case .running: return subagent.background ? "Running in the background" : "Running"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }
}

/// Which sub-agent is showing: its thread and its id.
public struct SubagentRef: Sendable, Hashable {
    public var threadId: String
    public var subagentId: String

    public init(threadId: String, subagentId: String) {
        self.threadId = threadId
        self.subagentId = subagentId
    }

    public var key: String { threadId + "/" + subagentId }
}
