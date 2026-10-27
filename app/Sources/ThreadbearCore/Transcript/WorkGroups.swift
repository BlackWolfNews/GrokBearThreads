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

/// The "Working for 12s" line at the end of a running turn, the one place a
/// running turn shows a spinner. The view counts the seconds itself, so the
/// row doesn't change (or re-render) as they pass, nor as work above it
/// comes and goes.
public struct WorkingStatus: Sendable, Hashable {
    public var turnId: String
    /// When the turn started, if the loaded events say.
    public var startedAt: Date?

    public init(turnId: String, startedAt: Date?) {
        self.turnId = turnId
        self.startedAt = startedAt
    }
}

/// The line at the end of a thread whose turn is over but whose CLI still
/// has sub-agents or jobs running in the background (from the thread's
/// summary, not its events).
public struct BackgroundStatus: Sendable, Hashable {
    public var tasks: [BackgroundTask]

    public init(tasks: [BackgroundTask]) {
        self.tasks = tasks
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
    /// Its open diff shows every line, not just the first few
    /// (`DiffPreview.allKey`).
    public var showsAll: Bool
    /// The thread's working folder.
    public var root: String?

    public init(path: String, added: Int, removed: Int, diffs: [EditDiff], isExpanded: Bool = false, showsAll: Bool = false, root: String? = nil) {
        self.path = path
        self.added = added
        self.removed = removed
        self.diffs = diffs
        self.isExpanded = isExpanded
        self.showsAll = showsAll
        self.root = root
    }

    public var name: String { (path as NSString).lastPathComponent }

    /// The file's folder inside the thread's folder ("Sources/Upload",
    /// empty at its top), or short for a file outside it.
    public var folder: String { PathDisplay.folder(of: path, relativeTo: root) }
}

/// How much of an opened diff shows. A diff opens at its first `lines`
/// lines with "Show 30 more lines" under it, which opens the rest: a 400
/// line Write opened from the changes card used to pour all of it into the
/// turn.
public enum DiffPreview {
    public static let lines = 12
    /// Hiding fewer lines than this isn't worth a click: a 15 line diff
    /// showed 12 and "Show 3 more lines".
    public static let slack = 6

    /// How many of a diff's `total` display lines show while it's opened short.
    public static func shown(of total: Int) -> Int {
        total <= lines + slack ? total : lines
    }

    /// The expansion key that shows all of an opened diff: a tool row's id,
    /// or a changes card file's `ChangedFiles.expansionKey`, plus "|all".
    public static func allKey(_ key: String) -> String { key + "|all" }

    /// Opens or closes `key` in a set of open keys. Closing also forgets
    /// "show all", so a diff opens short again next time.
    public static func set(_ key: String, open: Bool, in expanded: inout Set<String>) {
        if open {
            expanded.insert(key)
        } else {
            expanded.remove(key)
            expanded.remove(allKey(key))
        }
    }
}

/// Words for a work group's one-line summary.
public enum WorkSummary {
    enum Category: Hashable {
        case read, search, edit, command, web, agent, plan, imageMade, imageViewed, tool
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
        var allowed = 0

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
            case .approval:
                // The tool it let run is counted when it comes; the approval
                // only names the run while that hasn't arrived yet.
                allowed += 1
            case .tool(let tool):
                if tool.failed { failed += 1 }
                let category = category(of: tool)
                switch category {
                case .read:
                    // The same file read twice is still one file.
                    let path = tool.call?.input["file_path"]?.stringValue ?? tool.call?.input["path"]?.stringValue ?? tool.itemId
                    count(.read, by: readPaths.insert(path).inserted ? 1 : 0)
                case .edit:
                    // Not `effectiveDiffs`: that builds the whole diff, and a
                    // live group's summary is rebuilt on every streamed delta.
                    // A Codex patch counts each file it touches.
                    let paths = tool.editedPaths.isEmpty ? [tool.itemId] : tool.editedPaths
                    count(.edit, by: paths.reduce(0) { $0 + (editPaths.insert($1).inserted ? 1 : 0) })
                case .imageMade:
                    // One that failed made nothing; the red icon says so.
                    count(.imageMade, by: tool.failed ? 0 : max(1, tool.result?.images.count ?? 1))
                case .imageViewed:
                    count(.imageViewed)
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
            if thought {
                text = "thought"
            } else if let firstNote {
                text = firstLine(firstNote)
            } else if allowed > 0 {
                text = allowed == 1 ? "allowed a request" : "allowed \(allowed) requests"
            } else {
                text = "worked"
            }
        }
        return (capitalizedFirst(text), failed)
    }

    static func category(of tool: ToolItem) -> Category {
        switch tool.toolKind {
        // Codex's view_image is a read of a picture, not of a file's text.
        case .read: return tool.name == "view_image" ? .imageViewed : .read
        case .search: return .search
        case .edit, .write: return .edit
        case .command: return .command
        case .web: return tool.name.localizedCaseInsensitiveContains("search") ? .search : .web
        case .task: return .agent
        case .todo: return .plan
        case .image: return .imageMade
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
        case .imageMade: return n == 1 ? "made an image" : "made \(n) images"
        case .imageViewed: return n == 1 ? "viewed an image" : "viewed \(n) images"
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

    /// A thinking block's one-line summary: its first sentence, full stop
    /// and all, when that's a reasonable length. Cut wherever the column
    /// ended, a long first line could stop just after a full stop and read
    /// "confirmed.…", and it pushed the line's chevron to the far edge.
    public static func thought(_ text: String) -> String {
        var line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if line.count > 200 { line = String(line.prefix(200)) }
        guard let stop = line.range(of: ". ") else { return line }
        let sentence = String(line[..<stop.lowerBound]) + "."
        return (20...140).contains(sentence.count) ? sentence : line
    }

    static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
