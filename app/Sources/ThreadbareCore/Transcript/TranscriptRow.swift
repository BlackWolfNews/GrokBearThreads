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

    public init(id: String, version: Int = 0, seq: Int, turnId: String? = nil, content: RowContent) {
        self.id = id
        self.version = version
        self.seq = seq
        self.turnId = turnId
        self.content = content
    }

    public var kind: RowKind { content.kind }
}

public enum RowKind: String, Sendable, Hashable, CaseIterable {
    case user, assistant, reasoning, tool, diff, images, approval, question, plan, footer, note, error
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

    public init(text: String, images: [ImageRef] = []) {
        self.text = text
        self.images = images
    }
}

public struct ToolItem: Sendable, Hashable {
    public var itemId: String
    public var call: ToolCall?
    public var result: ToolResult?
    /// Live output from `tool.output.delta`, dropped once the result lands.
    public var liveOutput: String
    public var diff: EditDiff?

    public init(itemId: String, call: ToolCall? = nil, result: ToolResult? = nil, liveOutput: String = "", diff: EditDiff? = nil) {
        self.itemId = itemId
        self.call = call
        self.result = result
        self.liveOutput = liveOutput
        self.diff = diff
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

    public init(request: ApprovalRequest, resolution: ApprovalResolution? = nil) {
        self.request = request
        self.resolution = resolution
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
        }
    }
}
