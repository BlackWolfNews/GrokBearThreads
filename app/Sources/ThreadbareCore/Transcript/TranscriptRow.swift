import Foundation

/// One row in the transcript table.
public struct TranscriptRow: Sendable, Hashable, Identifiable {
    public let id: String
    /// Bumped every time the content changes, so caches keyed by (id, version)
    /// know when to re-render or re-measure.
    public var version: Int
    /// Seq of the event that created the row.
    public var seq: Int
    public var turnId: String?
    public var content: RowContent
    /// Shown inside an open work group (indented under its summary line).
    /// Set on display rows only; the same item renders differently there.
    public var inGroup: Bool

    public init(id: String, version: Int = 0, seq: Int, turnId: String? = nil, content: RowContent, inGroup: Bool = false) {
        self.id = id
        self.version = version
        self.seq = seq
        self.turnId = turnId
        self.content = content
        self.inGroup = inGroup
    }

    public var kind: RowKind { content.kind }
}

public enum RowKind: String, Sendable, Hashable, CaseIterable {
    case user, assistant, reasoning, tool, diff, images, approval, question, plan, footer, note, error
    /// Rows the model derives rather than reads from events: a folded run
    /// of work, the "Working for 12s" line, the "3 sub-agents working in
    /// the background" line, and the "Edited 3 files" card.
    case group, working, background, changes
}

public struct TextItem: Sendable, Hashable {
    public var itemId: String
    public var text: String
    /// Still receiving deltas.
    public var isStreaming: Bool

    public init(itemId: String, text: String, isStreaming: Bool = false) {
        self.itemId = itemId
        self.text = text
        self.isStreaming = isStreaming
    }
}

public struct UserMessage: Sendable, Hashable {
    public var text: String
    public var images: [ImageRef]
    /// "runner" when the runner sent it by itself (the resume after a
    /// restart), nil when a person or a client did.
    public var origin: String?

    public init(text: String, images: [ImageRef] = [], origin: String? = nil) {
        self.text = text
        self.images = images
        self.origin = origin
    }

    /// Sent by the runner, not by Mike: shown as a quiet centred line, not
    /// a bubble of his own.
    public var isFromRunner: Bool { origin == "runner" }
}

public struct ToolItem: Sendable, Hashable {
    public var itemId: String
    public var call: ToolCall?
    public var result: ToolResult?
    /// Live output from `tool.output.delta`, dropped once the result lands.
    public var liveOutput: String
    public var diff: EditDiff?
    /// The thread's working folder, so a file row names its folder from
    /// there ("scripts", not "photo-sync/scripts").
    public var root: String?

    public init(itemId: String, call: ToolCall? = nil, result: ToolResult? = nil, liveOutput: String = "", diff: EditDiff? = nil, root: String? = nil) {
        self.itemId = itemId
        self.call = call
        self.result = result
        self.liveOutput = liveOutput
        self.diff = diff
        self.root = root
    }

    public var name: String { call?.name ?? "Tool" }
    public var title: String { call?.title ?? name }
    public var toolKind: ToolKind { call?.kind ?? .other }
    public var isFinished: Bool { result != nil }
    public var failed: Bool { result.map { !$0.ok } ?? false }

    /// The diff to show: the runner's `edit.diff` if it sent one, otherwise
    /// one built from the Edit/MultiEdit/Write input.
    public var effectiveDiff: EditDiff? {
        if let diff { return diff }
        guard let call else { return nil }
        return DiffBuilder.diff(forTool: call)
    }
}

public struct ApprovalItem: Sendable, Hashable {
    public var request: ApprovalRequest
    public var resolution: ApprovalResolution?
    /// The thread's working folder, for the file's folder in the card.
    public var root: String?
    /// The tool call it asked about has a row of its own, which opens to
    /// the same command or file. Settled, this line then doesn't open:
    /// opened, "Allowed  Write release.sh" showed the file and the Write
    /// row right under it showed it again.
    public var toolShown: Bool

    public init(request: ApprovalRequest, resolution: ApprovalResolution? = nil, root: String? = nil, toolShown: Bool = false) {
        self.request = request
        self.resolution = resolution
        self.root = root
        self.toolShown = toolShown
    }

    /// It shows what it asked: always while it waits (a card then), and
    /// once settled only if its tool call has no row to show it.
    public var opens: Bool { resolution == nil || !toolShown }

    /// Mike let it happen: the request is now just a step of the work it
    /// allowed, so it folds into the run of work around it.
    public var isAllowed: Bool {
        resolution?.decision == .allow || resolution?.decision == .allowAlways
    }
}

public struct QuestionItem: Sendable, Hashable {
    public var request: QuestionRequest
    public var resolution: ApprovalResolution?

    public init(request: QuestionRequest, resolution: ApprovalResolution? = nil) {
        self.request = request
        self.resolution = resolution
    }
}

public enum RowContent: Sendable, Hashable {
    case user(UserMessage)
    case assistant(TextItem)
    case reasoning(TextItem)
    case tool(ToolItem)
    case images(itemId: String, images: [ImageRef])
    case approval(ApprovalItem)
    case question(QuestionItem)
    case plan([PlanEntry])
    case footer(TurnCompletion)
    case note(String)
    case error(String)
    case group(WorkGroup)
    case working(WorkingStatus)
    case background(BackgroundStatus)
    case changes(ChangedFiles)

    public var kind: RowKind {
        switch self {
        case .user: return .user
        case .assistant: return .assistant
        case .reasoning: return .reasoning
        case .tool(let tool):
            if tool.call.map(DiffBuilder.isEditTool) == true || tool.diff != nil { return .diff }
            return .tool
        case .images: return .images
        case .approval: return .approval
        case .question: return .question
        case .plan: return .plan
        case .footer: return .footer
        case .note: return .note
        case .error: return .error
        case .group: return .group
        case .working: return .working
        case .background: return .background
        case .changes: return .changes
        }
    }
}
