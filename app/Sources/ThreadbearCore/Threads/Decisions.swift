import Foundation

/// Mike's answer to one ask on the open card while he steps through them
/// (docs/protocol.md, "Needs you", Answering): one of its choices, his own
/// words (instead of a choice, or as a note on one), or Later.
public struct DecisionAnswer: Equatable, Sendable {
    public var choice: Int?
    public var text: String
    public var later: Bool

    public init(choice: Int? = nil, text: String = "", later: Bool = false) {
        self.choice = choice
        self.text = text
        self.later = later
    }

    public var isAnswered: Bool { later || choice != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The open card's asks as decisions, and the one message that answers them.
public enum Decisions {
    /// What Mike can pick from: the agent's options, or for a plain ask the
    /// reply it wants back ("done"). Either way he can write his own.
    public static func choices(for ask: Ask) -> [String] {
        if !ask.options.isEmpty { return ask.options }
        if let reply = ask.reply?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty { return [reply] }
        return impliedReply(ask.action).map { [$0] } ?? []
    }

    /// The word an ask with no options still asks for: 'Reply "export"
    /// when…' or "Say go for Short 2, or name another". Threads started
    /// before end_turn had options, and agents that skip them, mostly
    /// write asks like that (60% offered a reply word in the 27 Oct
    /// survey), so the word becomes a button.
    static func impliedReply(_ action: String) -> String? {
        let ns = action as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let m = quoted.firstMatch(in: action, range: full) { return ns.substring(with: m.range(at: 1)) }
        if let m = bare.firstMatch(in: action, range: full) {
            let word = ns.substring(with: m.range(at: 1))
            return word.prefix(1).uppercased() + word.dropFirst()
        }
        return nil
    }

    private static let quoted = try! NSRegularExpression(pattern: #"\b(?:say|reply|type|send|answer)(?: with)?\s+[\"“']([^\"”']{1,40})[\"”']"#, options: .caseInsensitive)
    private static let bare = try! NSRegularExpression(pattern: #"^(?:say|reply)\s+(go|yes|ok|okay|done|ship it|merge it|merge)\b"#, options: .caseInsensitive)

    /// His answer to ask `i`, or the agent's pick until he gives one: going
    /// straight through takes the suggestions.
    public static func answer(_ i: Int, asks: [Ask], answers: [Int: DecisionAnswer]) -> DecisionAnswer? {
        if let given = answers[i] { return given }
        guard asks.indices.contains(i), let pick = asks[i].suggested else { return nil }
        return DecisionAnswer(choice: pick)
    }

    /// The answer as it reads in the message and the summary, or nil when
    /// there isn't one yet.
    public static func answerText(_ answer: DecisionAnswer?, ask: Ask) -> String? {
        guard let answer, answer.isAnswered else { return nil }
        if answer.later { return "Later, leave this one open" }
        let note = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = choices(for: ask)
        guard let choice = answer.choice, options.indices.contains(choice) else { return note.isEmpty ? nil : note }
        let picked = options[choice]
        guard !note.isEmpty else { return picked }
        // "Merge. Check the preview first": a pick and a note read as two
        // sentences unless the pick already ends one.
        let ends = picked.last.map { ".!?".contains($0) } ?? false
        return picked + (ends ? " " : ". ") + note
    }

    /// One ordinary message: each answered ask's question then its answer,
    /// numbered as on the card (the agent wrote them in that order), the
    /// agent's pick for any he left alone, then
    /// anything else Mike wrote. Asks he skipped are left out, keeping the
    /// others' numbers, so the agent can tell which ones were answered.
    public static func message(asks: [Ask], answers: [Int: DecisionAnswer], extra: String = "", withSuggestions: Bool = true) -> String {
        var parts: [String] = []
        for (i, ask) in asks.enumerated() {
            let given = withSuggestions ? answer(i, asks: asks, answers: answers) : answers[i]
            guard let text = answerText(given, ask: ask) else { continue }
            // One ask needs no number: just the question, then the answer.
            parts.append(asks.count == 1
                ? "\(ask.action)\n\(text)"
                : "\(i + 1). \(ask.action)\n   \(text.replacingOccurrences(of: "\n", with: "\n   "))")
        }
        var body = parts.joined(separator: "\n\n")
        let more = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !more.isEmpty { body += (body.isEmpty ? "" : "\n\n") + more }
        return body
    }

    /// Whether the open card should be stepped through: a completed turn
    /// that said it needs Mike, with asks, and nothing running.
    public static func isOpen(_ thread: ThreadSummary) -> Bool {
        thread.needs == "you" && thread.asksSeq != nil && !thread.asks.isEmpty && !thread.status.isBusy
    }
}
