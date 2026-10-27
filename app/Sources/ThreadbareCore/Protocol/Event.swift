import Foundation
import os

let protocolLog = Logger(subsystem: "com.mikerosoft.threadbare", category: "protocol")

public enum ToolKind: String, Sendable, Hashable, Codable {
    /// `image` is image generation (Codex). A kind this app doesn't know
    /// reads as `other`.
    case command, read, edit, write, search, web, mcp, task, todo, image, other

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ToolKind(rawValue: raw) ?? .other
    }
}

public struct ToolCall: Sendable, Hashable, Decodable {
    public var itemId: String
    public var name: String
    public var kind: ToolKind
    public var title: String
    public var input: JSONValue

    public init(itemId: String, name: String, kind: ToolKind, title: String, input: JSONValue = .object([:])) {
        self.itemId = itemId
        self.name = name
        self.kind = kind
        self.title = title
        self.input = input
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemId = (try? c.decodeIfPresent(String.self, forKey: .itemId)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Tool"
        kind = (try? c.decodeIfPresent(ToolKind.self, forKey: .kind)) ?? .other
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? name
        input = (try? c.decodeIfPresent(JSONValue.self, forKey: .input)) ?? .object([:])
    }

    enum CodingKeys: String, CodingKey { case itemId, name, kind, title, input }
}

public struct ToolResult: Sendable, Hashable, Decodable {
    public var itemId: String
    public var ok: Bool
    public var text: String
    public var truncated: Bool
    public var blobPath: String?
    public var images: [ImageRef]

    public init(itemId: String, ok: Bool, text: String, truncated: Bool = false, blobPath: String? = nil, images: [ImageRef] = []) {
        self.itemId = itemId
        self.ok = ok
        self.text = text
        self.truncated = truncated
        self.blobPath = blobPath
        self.images = images
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemId = (try? c.decodeIfPresent(String.self, forKey: .itemId)) ?? ""
        ok = (try? c.decodeIfPresent(Bool.self, forKey: .ok)) ?? true
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        truncated = (try? c.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
        blobPath = try? c.decodeIfPresent(String.self, forKey: .blobPath)
        images = c.lossyArray(ImageRef.self, forKey: .images)
    }

    enum CodingKeys: String, CodingKey { case itemId, ok, text, truncated, blobPath, images }
}

public struct DiffHunk: Sendable, Hashable, Codable {
    public var oldStart: Int
    public var oldLines: Int
    public var newStart: Int
    public var newLines: Int
    public var lines: [String]

    public init(oldStart: Int, oldLines: Int, newStart: Int, newLines: Int, lines: [String]) {
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newStart = newStart
        self.newLines = newLines
        self.lines = lines
    }

    /// Missing counts default to what the lines say, so a hunk the runner
    /// sends in a slightly different shape still draws.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lines = c.lossyArray(String.self, forKey: .lines)
        oldStart = c.lenientInt(forKey: .oldStart) ?? 1
        newStart = c.lenientInt(forKey: .newStart) ?? oldStart
        oldLines = c.lenientInt(forKey: .oldLines) ?? lines.filter { !$0.hasPrefix("+") }.count
        newLines = c.lenientInt(forKey: .newLines) ?? lines.filter { !$0.hasPrefix("-") }.count
    }

    enum CodingKeys: String, CodingKey { case oldStart, oldLines, newStart, newLines, lines }
}

public struct EditDiff: Sendable, Hashable, Decodable {
    public var itemId: String
    public var path: String
    public var hunks: [DiffHunk]

    public init(itemId: String, path: String, hunks: [DiffHunk]) {
        self.itemId = itemId
        self.path = path
        self.hunks = hunks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemId = (try? c.decodeIfPresent(String.self, forKey: .itemId)) ?? ""
        path = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? ""
        hunks = c.lossyArray(DiffHunk.self, forKey: .hunks)
    }

    enum CodingKeys: String, CodingKey { case itemId, path, hunks }
}

public enum ApprovalOption: String, Sendable, Hashable, Codable {
    case allow, allowAlways, deny
}

public struct ApprovalRequest: Sendable, Hashable, Decodable {
    public var approvalId: String
    public var itemId: String?
    public var name: String
    public var title: String
    public var input: JSONValue
    public var options: [ApprovalOption]

    public init(approvalId: String, itemId: String? = nil, name: String, title: String, input: JSONValue = .object([:]), options: [ApprovalOption] = [.allow, .allowAlways, .deny]) {
        self.approvalId = approvalId
        self.itemId = itemId
        self.name = name
        self.title = title
        self.input = input
        self.options = options
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        approvalId = (try? c.decodeIfPresent(String.self, forKey: .approvalId)) ?? ""
        itemId = try? c.decodeIfPresent(String.self, forKey: .itemId)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Tool"
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? name
        input = (try? c.decodeIfPresent(JSONValue.self, forKey: .input)) ?? .object([:])
        // Unknown option strings are dropped rather than failing the event.
        let raw = (try? c.decodeIfPresent(LossyArray<String>.self, forKey: .options))??.elements ?? ["allow", "deny"]
        options = raw.compactMap(ApprovalOption.init(rawValue:))
    }

    enum CodingKeys: String, CodingKey { case approvalId, itemId, name, title, input, options }
}

public struct QuestionOption: Sendable, Hashable, Codable {
    public var label: String
    public var description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }

    public init(from decoder: Decoder) throws {
        // A bare string is taken as the label.
        if let bare = try? decoder.singleValueContainer().decode(String.self) {
            label = bare
            description = nil
        } else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? (try? c.decodeIfPresent(String.self, forKey: .value)) ?? ""
            description = try? c.decodeIfPresent(String.self, forKey: .description)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encodeIfPresent(description, forKey: .description)
    }

    enum CodingKeys: String, CodingKey { case label, value, description }
}

public struct Question: Sendable, Hashable, Decodable {
    public var question: String
    public var header: String?
    public var multiSelect: Bool
    public var options: [QuestionOption]

    public init(question: String, header: String? = nil, multiSelect: Bool = false, options: [QuestionOption]) {
        self.question = question
        self.header = header
        self.multiSelect = multiSelect
        self.options = options
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = (try? c.decodeIfPresent(String.self, forKey: .question)) ?? ""
        header = try? c.decodeIfPresent(String.self, forKey: .header)
        multiSelect = (try? c.decodeIfPresent(Bool.self, forKey: .multiSelect)) ?? false
        options = c.lossyArray(QuestionOption.self, forKey: .options).filter { !$0.label.isEmpty }
    }

    enum CodingKeys: String, CodingKey { case question, header, multiSelect, options }
}

public struct QuestionRequest: Sendable, Hashable, Decodable {
    public var approvalId: String
    public var questions: [Question]

    public init(approvalId: String, questions: [Question]) {
        self.approvalId = approvalId
        self.questions = questions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        approvalId = (try? c.decodeIfPresent(String.self, forKey: .approvalId)) ?? ""
        questions = c.lossyArray(Question.self, forKey: .questions)
    }

    enum CodingKeys: String, CodingKey { case approvalId, questions }
}

public enum ApprovalDecision: String, Sendable, Hashable, Codable {
    case allow, allowAlways, deny, answered, expired

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ApprovalDecision(rawValue: raw) ?? .expired
    }
}

public struct ApprovalResolution: Sendable, Hashable, Decodable {
    public var approvalId: String
    public var decision: ApprovalDecision
    public var message: String?

    public init(approvalId: String, decision: ApprovalDecision, message: String? = nil) {
        self.approvalId = approvalId
        self.decision = decision
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        approvalId = (try? c.decodeIfPresent(String.self, forKey: .approvalId)) ?? ""
        decision = (try? c.decodeIfPresent(ApprovalDecision.self, forKey: .decision)) ?? .expired
        message = try? c.decodeIfPresent(String.self, forKey: .message)
    }

    enum CodingKeys: String, CodingKey { case approvalId, decision, message }
}

public enum PlanStatus: String, Sendable, Hashable, Codable {
    case pending, in_progress, completed

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PlanStatus(rawValue: raw) ?? .pending
    }
}

public struct PlanEntry: Sendable, Hashable, Codable {
    public var text: String
    public var status: PlanStatus

    public init(text: String, status: PlanStatus) {
        self.text = text
        self.status = status
    }

    /// Claude's TodoWrite calls the text `content`; either is accepted.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? (try? c.decodeIfPresent(String.self, forKey: .content)) ?? ""
        status = (try? c.decodeIfPresent(PlanStatus.self, forKey: .status)) ?? .pending
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(status, forKey: .status)
    }

    enum CodingKeys: String, CodingKey { case text, content, status }
}

public enum TurnOutcome: String, Sendable, Hashable, Codable {
    case completed, interrupted, failed

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TurnOutcome(rawValue: raw) ?? .completed
    }
}

/// Why a failed turn failed, when the runner knows, so the app can offer
/// the fix without reading the message.
public enum TurnErrorKind: String, Sendable, Hashable, Codable {
    case usageLimit, contextWindow, auth
}

public struct TurnCompletion: Sendable, Hashable, Decodable {
    public var turnId: String
    public var outcome: TurnOutcome
    public var durationMs: Double
    /// Nil for Codex turns, which report no cost.
    public var costUsd: Double?
    /// Token counts by name. Claude: inputTokens, outputTokens,
    /// cacheReadTokens, cacheWriteTokens. Codex: inputTokens,
    /// cachedInputTokens, cacheWriteTokens, outputTokens, reasoningTokens.
    public var usage: JSONValue?
    public var error: String?
    /// Nil when unknown, including a kind this app doesn't know yet.
    public var errorKind: TurnErrorKind?
    /// What the turn said it needs from Mike: "you" (with `asks`),
    /// "nothing", or nil when it said neither.
    public var needs: String?
    public var asks: [Ask]

    public init(
        turnId: String, outcome: TurnOutcome, durationMs: Double, costUsd: Double? = nil, usage: JSONValue? = nil, error: String? = nil,
        errorKind: TurnErrorKind? = nil, needs: String? = nil, asks: [Ask] = []
    ) {
        self.needs = needs
        self.asks = asks
        self.turnId = turnId
        self.outcome = outcome
        self.durationMs = durationMs
        self.costUsd = costUsd
        self.usage = usage
        self.error = error
        self.errorKind = errorKind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        turnId = (try? c.decodeIfPresent(String.self, forKey: .turnId)) ?? ""
        outcome = (try? c.decodeIfPresent(TurnOutcome.self, forKey: .outcome)) ?? .completed
        durationMs = (try? c.decodeIfPresent(Double.self, forKey: .durationMs)) ?? 0
        costUsd = try? c.decodeIfPresent(Double.self, forKey: .costUsd)
        usage = try? c.decodeIfPresent(JSONValue.self, forKey: .usage)
        errorKind = ((try? c.decodeIfPresent(String.self, forKey: .errorKind)) ?? nil).flatMap(TurnErrorKind.init(rawValue:))
        needs = (try? c.decodeIfPresent(String.self, forKey: .needs)) ?? nil
        asks = c.lossyArray(Ask.self, forKey: .asks)
        // `error` may be a string or an object depending on the runner version.
        if let text = try? c.decodeIfPresent(String.self, forKey: .error) {
            error = text
        } else if let value = try? c.decodeIfPresent(JSONValue.self, forKey: .error) {
            error = value["message"]?.stringValue ?? value.compactText
        } else {
            error = nil
        }
    }

    enum CodingKeys: String, CodingKey { case turnId, outcome, durationMs, costUsd, usage, error, errorKind, needs, asks }
}

/// A command action that ran (`action.run`): what it printed, outside any
/// turn. Shown as a tool row.
public struct ActionRun: Sendable, Hashable, Decodable {
    public var actionId: String
    public var patch: String
    public var title: String
    public var command: String
    public var ok: Bool
    public var exitCode: Int?
    public var text: String
    public var truncated: Bool
    public var durationMs: Double
    /// "turn.end" when a hook ran it; nil for a chip or tb.
    public var trigger: String?

    public init(actionId: String, patch: String = "", title: String, command: String = "", ok: Bool = true, exitCode: Int? = nil, text: String = "", truncated: Bool = false, durationMs: Double = 0, trigger: String? = nil) {
        self.actionId = actionId
        self.patch = patch
        self.title = title
        self.command = command
        self.ok = ok
        self.exitCode = exitCode
        self.text = text
        self.truncated = truncated
        self.durationMs = durationMs
        self.trigger = trigger
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        actionId = (try? c.decodeIfPresent(String.self, forKey: .actionId)) ?? ""
        patch = (try? c.decodeIfPresent(String.self, forKey: .patch)) ?? ""
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? actionId
        command = (try? c.decodeIfPresent(String.self, forKey: .command)) ?? ""
        ok = (try? c.decodeIfPresent(Bool.self, forKey: .ok)) ?? true
        exitCode = c.lenientInt(forKey: .exitCode)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        truncated = (try? c.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
        durationMs = (try? c.decodeIfPresent(Double.self, forKey: .durationMs)) ?? 0
        trigger = try? c.decodeIfPresent(String.self, forKey: .trigger)
    }

    enum CodingKeys: String, CodingKey { case actionId, patch, title, command, ok, exitCode, text, truncated, durationMs, trigger }

    /// The row's item id: one per run.
    public func itemId(seq: Int) -> String { "action:\(seq)" }

    /// The run as the tool call and result the transcript draws.
    public var asToolCall: (ToolCall, ToolResult) {
        var title = ok ? self.title : "\(self.title) failed" + (exitCode.map { " (exit \($0))" } ?? "")
        // A hook's run says when it ran, as the design's patch line does.
        if trigger == "turn.end" { title += " · after the turn" }
        let call = ToolCall(itemId: "", name: "action", kind: .command, title: title,
                            input: .object(["command": .string(command), "patch": .string(patch), "actionId": .string(actionId)]))
        return (call, ToolResult(itemId: "", ok: ok, text: text, truncated: truncated))
    }
}

public enum EventPayload: Sendable, Hashable {
    /// `origin` is "runner" for a message the runner sent by itself (the
    /// resume after a restart); nil for anything a person or client sent.
    case userMessage(text: String, images: [ImageRef], origin: String? = nil)
    case assistantText(itemId: String, text: String)
    case reasoning(itemId: String, text: String)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
    case editDiff(EditDiff)
    case approvalRequested(ApprovalRequest)
    case questionRequested(QuestionRequest)
    case reviewUpdated(DesignReview)
    case approvalResolved(ApprovalResolution)
    case planUpdated([PlanEntry])
    case turnStarted
    case turnCompleted(TurnCompletion)
    case systemNote(String)
    case error(String)
    case actionRun(ActionRun)
    /// The ticks on the card of asks that came with the turn.completed at
    /// `asksSeq`: the whole set each time.
    case asksTicked(asksSeq: Int, ticked: [Int])
    case assistantTextDelta(itemId: String, text: String)
    case reasoningDelta(itemId: String, text: String)
    case toolOutputDelta(itemId: String, text: String)
    /// Everything streamed so far for an item, from a subscribe reply's
    /// `inProgress`. Replaces the row's streaming text (deltas append). Made
    /// by the app, never sent by the runner as an event.
    case streamingText(itemId: String, isReasoning: Bool, text: String)
    /// An event type this app doesn't know yet. Ignored by the reducer.
    case unknown
}

public struct Event: Sendable, Hashable, Decodable {
    public var seq: Int
    public var ts: String
    public var threadId: String
    public var turnId: String?
    public var type: String
    public var payload: EventPayload

    public init(seq: Int, ts: String = "", threadId: String, turnId: String? = nil, type: String, payload: EventPayload) {
        self.seq = seq
        self.ts = ts
        self.threadId = threadId
        self.turnId = turnId
        self.type = type
        self.payload = payload
    }

    static let transientTypes: Set<String> = ["assistant.text.delta", "reasoning.delta", "tool.output.delta"]

    /// Transient events stream between persisted ones and never consume a seq.
    /// Judged by type too, so a delta that couldn't be read stays transient.
    public var isTransient: Bool {
        switch payload {
        case .assistantTextDelta, .reasoningDelta, .toolOutputDelta, .streamingText: return true
        default: return Event.transientTypes.contains(type)
        }
    }

    private struct TextFields: Decodable {
        var itemId: String?
        var text: String?
        var images: [ImageRef]
        var message: String?
        var origin: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            itemId = try? c.decodeIfPresent(String.self, forKey: .itemId)
            text = try? c.decodeIfPresent(String.self, forKey: .text)
            images = c.lossyArray(ImageRef.self, forKey: .images)
            message = try? c.decodeIfPresent(String.self, forKey: .message)
            origin = try? c.decodeIfPresent(String.self, forKey: .origin)
        }

        enum CodingKeys: String, CodingKey { case itemId, text, images, message, origin }
    }

    private struct PlanFields: Decodable {
        var entries: [PlanEntry]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            entries = c.lossyArray(PlanEntry.self, forKey: .entries)
        }

        enum CodingKeys: String, CodingKey { case entries }
    }

    enum CodingKeys: String, CodingKey { case seq, ts, threadId, turnId, type }

    /// Never fails for an object. A payload this app can't read becomes
    /// `.unknown` but keeps its seq: dropping the event would leave a hole
    /// in the seq order, and the feed would ask for it again forever.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = c.lenientInt(forKey: .seq) ?? 0
        ts = (try? c.decodeIfPresent(String.self, forKey: .ts)) ?? ""
        threadId = (try? c.decodeIfPresent(String.self, forKey: .threadId)) ?? ""
        turnId = try? c.decodeIfPresent(String.self, forKey: .turnId)
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? ""
        do {
            payload = try Event.decodePayload(type: type, decoder: decoder)
        } catch {
            payload = .unknown
            let (type, seq, reason) = (type, seq, String(describing: error))
            protocolLog.error("Couldn't read a \(type, privacy: .public) event (seq \(seq)): \(reason, privacy: .public)")
        }
    }

    private static func decodePayload(type: String, decoder: Decoder) throws -> EventPayload {
        func text() throws -> TextFields { try TextFields(from: decoder) }
        switch type {
        case "user.message":
            let fields = try text()
            return .userMessage(text: fields.text ?? "", images: fields.images, origin: fields.origin)
        case "assistant.text":
            let fields = try text()
            return .assistantText(itemId: fields.itemId ?? "", text: fields.text ?? "")
        case "reasoning":
            let fields = try text()
            return .reasoning(itemId: fields.itemId ?? "", text: fields.text ?? "")
        case "tool.call":
            return .toolCall(try ToolCall(from: decoder))
        case "tool.result":
            return .toolResult(try ToolResult(from: decoder))
        case "edit.diff":
            return .editDiff(try EditDiff(from: decoder))
        case "approval.requested":
            return .approvalRequested(try ApprovalRequest(from: decoder))
        case "question.requested":
            return .questionRequested(try QuestionRequest(from: decoder))
        case "review.updated":
            let c = try decoder.container(keyedBy: ReviewFields.self)
            return .reviewUpdated(try c.decode(DesignReview.self, forKey: .review))
        case "approval.resolved":
            return .approvalResolved(try ApprovalResolution(from: decoder))
        case "plan.updated":
            return .planUpdated(try PlanFields(from: decoder).entries)
        case "turn.started":
            return .turnStarted
        case "turn.completed":
            return .turnCompleted(try TurnCompletion(from: decoder))
        case "system.note":
            return .systemNote(try text().text ?? "")
        case "error":
            let fields = try text()
            return .error(fields.message ?? fields.text ?? "Something went wrong")
        case "action.run":
            return .actionRun(try ActionRun(from: decoder))
        case "asks.ticked":
            let fields = try AsksTickedFields(from: decoder)
            return .asksTicked(asksSeq: fields.asksSeq, ticked: fields.ticked ?? [])
        case "assistant.text.delta":
            let fields = try text()
            return .assistantTextDelta(itemId: fields.itemId ?? "", text: fields.text ?? "")
        case "reasoning.delta":
            let fields = try text()
            return .reasoningDelta(itemId: fields.itemId ?? "", text: fields.text ?? "")
        case "tool.output.delta":
            let fields = try text()
            return .toolOutputDelta(itemId: fields.itemId ?? "", text: fields.text ?? "")
        default:
            return .unknown
        }
    }

    private enum ReviewFields: String, CodingKey { case review }
}

/// Result of `threads.events`.
public struct EventsPage: Sendable, Decodable {
    public struct InProgress: Sendable, Hashable, Decodable {
        public var itemId: String
        public var type: String
        public var text: String

        public init(itemId: String, type: String, text: String) {
            self.itemId = itemId
            self.type = type
            self.text = text
        }
    }

    public var events: [Event]
    public var firstSeq: Int
    public var lastSeq: Int
    public var inProgress: [InProgress]

    public init(events: [Event], firstSeq: Int, lastSeq: Int, inProgress: [InProgress] = []) {
        self.events = events
        self.firstSeq = firstSeq
        self.lastSeq = lastSeq
        self.inProgress = inProgress
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = c.lossyArray(Event.self, forKey: .events)
        firstSeq = c.lenientInt(forKey: .firstSeq) ?? (events.first?.seq ?? 0)
        lastSeq = c.lenientInt(forKey: .lastSeq) ?? (events.last?.seq ?? 0)
        inProgress = c.lossyArray(InProgress.self, forKey: .inProgress)
    }

    enum CodingKeys: String, CodingKey { case events, firstSeq, lastSeq, inProgress }
}

/// Decodes an array, skipping elements that fail to decode instead of failing
/// the whole array. One malformed event shouldn't hide a whole transcript.
public struct LossyArray<Element: Decodable>: Decodable, Sendable where Element: Sendable {
    public var elements: [Element]

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        if let count = container.count { elements.reserveCapacity(count) }
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else if (try? container.decode(JSONValue.self)) == nil {
                break
            }
        }
        self.elements = elements
    }
}

extension KeyedDecodingContainer {
    /// An array where elements that don't decode are skipped, and a missing,
    /// null or non-array value is an empty array.
    func lossyArray<Element: Decodable & Sendable>(_ type: Element.Type, forKey key: Key) -> [Element] {
        ((try? decodeIfPresent(LossyArray<Element>.self, forKey: key)) ?? nil)?.elements ?? []
    }

    /// An integer sent as a whole number or a numeric string.
    func lenientInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite { return Int(value) }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Int(text) }
        return nil
    }
}

private struct AsksTickedFields: Decodable {
    var asksSeq: Int
    var ticked: [Int]?
}
