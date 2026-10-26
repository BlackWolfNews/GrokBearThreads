import Foundation

/// A run of work inside one turn (thinking, tool calls with their results
/// and diffs, system notes) folded into one line, so a finished turn reads
/// as a few summaries and the answer rather than a wall of tool rows.
public struct WorkGroup: Sendable, Hashable {
    /// Row ids of the folded items, oldest first.
    public var memberIds: [String]
    /// "Read 3 files, searched twice, ran 4 commands".
    public var summary: String
    /// Tool calls in the group that failed.
    public var failedCount: Int
    public var isExpanded: Bool
    /// The last group of a turn that's still running.
    public var isLive: Bool
    /// While live, what's happening now ("Running npm test"), if anything is.
    public var currentAction: String?

    public init(memberIds: [String], summary: String, failedCount: Int = 0, isExpanded: Bool = false, isLive: Bool = false, currentAction: String? = nil) {
        self.memberIds = memberIds
        self.summary = summary
        self.failedCount = failedCount
        self.isExpanded = isExpanded
        self.isLive = isLive
        self.currentAction = currentAction
    }

    init(members: ArraySlice<TranscriptRow>, isExpanded: Bool, isLive: Bool) {
        let described = WorkSummary.describe(members)
        self.init(memberIds: members.map(\.id), summary: described.text, failedCount: described.failed,
                  isExpanded: isExpanded, isLive: isLive, currentAction: isLive ? WorkSummary.currentAction(members) : nil)
    }
}

/// The "Working for 12s" line at the end of a running turn. The view counts
/// the seconds itself, so the row doesn't change (or re-render) as they pass.
public struct WorkingStatus: Sendable, Hashable {
    public var turnId: String
    /// When the turn started, if the loaded events say.
    public var startedAt: Date?

    public init(turnId: String, startedAt: Date?) {
        self.turnId = turnId
        self.startedAt = startedAt
    }
}

/// The "Edited 3 files" card at the end of a turn that changed files.
public struct ChangedFiles: Sendable, Hashable {
    public var turnId: String
    public var files: [ChangedFile]

    public init(turnId: String, files: [ChangedFile]) {
        self.turnId = turnId
        self.files = files
    }

    public var title: String {
        files.count == 1 ? "Edited 1 file" : "Edited \(files.count) files"
    }

    public var added: Int { files.reduce(0) { $0 + $1.added } }
    public var removed: Int { files.reduce(0) { $0 + $1.removed } }

    /// The key `TranscriptModel.setExpanded` takes to open one file's diff.
    public static func expansionKey(turnId: String, path: String) -> String {
        "cf:\(turnId)|\(path)"
    }
}

public struct ChangedFile: Sendable, Hashable {
    public var path: String
    public var added: Int
    public var removed: Int
    /// Every successful edit to the file in the turn, in order.
    public var diffs: [EditDiff]
    /// Its diff is open under it in the card.
    public var isExpanded: Bool

    public init(path: String, added: Int, removed: Int, diffs: [EditDiff], isExpanded: Bool = false) {
        self.path = path
        self.added = added
        self.removed = removed
        self.diffs = diffs
        self.isExpanded = isExpanded
    }

    public var name: String { (path as NSString).lastPathComponent }

    /// The file's folder, short: its last two components ("Sources/Upload"),
    /// or "~" style for something right under the home folder.
    public var folder: String {
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != "/" else { return "" }
        let home = NSHomeDirectory()
        if parent == home { return "~" }
        let parts = parent.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }
}

/// Words for a work group's one-line summary.
public enum WorkSummary {
    enum Category: Hashable {
        case read, search, edit, command, web, agent, plan, tool
    }

    /// The summary and how many tools failed. Parts come in the order the
    /// work happened, so the line reads like what the agent did.
    public static func describe(_ items: some Collection<TranscriptRow>) -> (text: String, failed: Int) {
        var order: [Category] = []
        var counts: [Category: Int] = [:]
        var readPaths = Set<String>()
        var editPaths = Set<String>()
        var failed = 0
        var thought = false
        var firstNote: String?

        func count(_ category: Category, by amount: Int = 1) {
            if counts[category] == nil { order.append(category) }
            counts[category, default: 0] += amount
        }

        for item in items {
            switch item.content {
            case .reasoning:
                thought = true
            case .note(let text):
                if firstNote == nil { firstNote = text }
            case .tool(let tool):
                if tool.failed { failed += 1 }
                let category = category(of: tool)
                switch category {
                case .read:
                    // The same file read twice is still one file.
                    let path = tool.call?.input["file_path"]?.stringValue ?? tool.call?.input["path"]?.stringValue ?? tool.itemId
                    count(.read, by: readPaths.insert(path).inserted ? 1 : 0)
                case .edit:
                    // Not `effectiveDiff`: that builds the whole diff, and a
                    // live group's summary is rebuilt on every streamed delta.
                    let path = tool.diff?.path ?? tool.call?.input["file_path"]?.stringValue
                        ?? tool.call?.input["path"]?.stringValue ?? tool.itemId
                    count(.edit, by: editPaths.insert(path).inserted ? 1 : 0)
                default:
                    count(category)
                }
            default:
                break
            }
        }

        let parts = order.compactMap { phrase($0, counts[$0] ?? 0) }
        var text = parts.joined(separator: ", ")
        if text.isEmpty {
            text = thought ? "thought" : (firstNote.map { firstLine($0) } ?? "worked")
        }
        return (capitalizedFirst(text), failed)
    }

    static func category(of tool: ToolItem) -> Category {
        switch tool.toolKind {
        case .read: return .read
        case .search: return .search
        case .edit, .write: return .edit
        case .command: return .command
        case .web: return tool.name.localizedCaseInsensitiveContains("search") ? .search : .web
        case .task: return .agent
        case .todo: return .plan
        case .mcp, .other:
            if let call = tool.call, DiffBuilder.isEditTool(call) { return .edit }
            return .tool
        }
    }

    static func phrase(_ category: Category, _ n: Int) -> String? {
        guard n > 0 else { return nil }
        switch category {
        case .read: return n == 1 ? "read a file" : "read \(n) files"
        case .search: return n == 1 ? "searched once" : n == 2 ? "searched twice" : "searched \(n) times"
        case .edit: return n == 1 ? "edited a file" : "edited \(n) files"
        case .command: return n == 1 ? "ran a command" : "ran \(n) commands"
        case .web: return n == 1 ? "fetched a page" : "fetched \(n) pages"
        case .agent: return n == 1 ? "ran an agent" : "ran \(n) agents"
        case .plan: return "updated the plan"
        case .tool: return n == 1 ? "used a tool" : "used \(n) tools"
        }
    }

    /// What a live group is doing right now: the newest tool still waiting
    /// for its result, or thinking that's still streaming. Nil between steps.
    public static func currentAction(_ items: some BidirectionalCollection<TranscriptRow>) -> String? {
        for item in items.reversed() {
            switch item.content {
            case .tool(let tool) where !tool.isFinished:
                return ToolPresentation.activeTitle(tool)
            case .reasoning(let text) where text.isStreaming:
                return "Thinking"
            default:
                continue
            }
        }
        return nil
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }

    static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
