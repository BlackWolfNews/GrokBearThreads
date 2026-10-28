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
        return []
    }

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
    public static func message(asks: [Ask], answers: [Int: DecisionAnswer], extra: String = "") -> String {
        var parts: [String] = []
        for (i, ask) in asks.enumerated() {
            guard let text = answerText(answer(i, asks: asks, answers: answers), ask: ask) else { continue }
            parts.append("\(i + 1). \(ask.action)\n   \(text.replacingOccurrences(of: "\n", with: "\n   "))")
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
