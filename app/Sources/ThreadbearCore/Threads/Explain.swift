import Foundation

/// One answer in an Explain side conversation (docs/protocol.md,
/// "Explain"): the first explanation has no question, a follow-up has one.
public struct ExplainTurn: Sendable, Hashable {
    public var question: String?
    public var answer: String?
    public var error: String?

    public init(question: String? = nil, answer: String? = nil, error: String? = nil) {
        self.question = question
        self.answer = answer
        self.error = error
    }

    public var isPending: Bool { answer == nil && error == nil }
}

/// Words Mike selected in a thread and what the small model said about
/// them. A mini fork of the thread: it lives in the app alone, one per
/// thread, and nothing from it goes into the thread.
public struct ExplainSession: Sendable, Hashable {
    /// Bumped for each new selection, so an answer that comes back after
    /// Mike has explained something else is dropped.
    public var id: Int
    public var selection: String
    /// The whole message the selection came from.
    public var message: String?
    public var turns: [ExplainTurn]

    public init(id: Int, selection: String, message: String?) {
        self.id = id
        self.selection = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        self.message = message
        turns = [ExplainTurn()]
    }

    public var isBusy: Bool { turns.last?.isPending ?? false }

    /// The pane's title: the selection, short and on one line.
    public var title: String {
        let line = selection.split(whereSeparator: \.isNewline).first.map(String.init) ?? selection
        let short = line.count > 40 ? String(line.prefix(39)).trimmingCharacters(in: .whitespaces) + "…" : line
        return "\u{201C}\(short)\u{201D}"
    }

    /// Adds a follow-up waiting for its answer; nil while one is under way
    /// or the question is blank.
    public mutating func ask(_ question: String) -> Int? {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isBusy else { return nil }
        turns.append(ExplainTurn(question: q))
        return turns.count - 1
    }

    /// Tries a failed turn again.
    public mutating func retry(_ index: Int) -> Bool {
        guard turns.indices.contains(index), turns[index].error != nil else { return false }
        turns[index].error = nil
        return true
    }

    /// The `threads.explain` params for turn `index`: the answers before it
    /// as `earlier`, its question if it has one.
    public func params(threadId: String, for index: Int) -> JSONValue {
        var params: [String: JSONValue] = ["threadId": .string(threadId), "selection": .string(selection)]
        if let message { params["message"] = .string(message) }
        let earlier = turns.prefix(index).compactMap { turn -> JSONValue? in
            guard let answer = turn.answer else { return nil }
            var t: [String: JSONValue] = ["answer": .string(answer)]
            if let q = turn.question { t["question"] = .string(q) }
            return .object(t)
        }
        if !earlier.isEmpty { params["earlier"] = .array(earlier) }
        if turns.indices.contains(index), let q = turns[index].question { params["question"] = .string(q) }
        return .object(params)
    }
}

public struct ExplainResult: Decodable, Sendable {
    public let answer: String
    public let model: String?
}
