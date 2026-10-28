import Foundation

/// The open card's asks as decisions (docs/protocol.md, "Needs you",
/// Answering): what Mike can pick on each, and the one message his picks
/// and his own words go out as.
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

    /// The picked asks as answers, in the card's order, each with its
    /// index on the card. A pick that isn't one of its ask's choices is
    /// left out.
    public static func answers(asks: [Ask], picks: [Int: Int]) -> [(index: Int, answer: AskAnswer)] {
        asks.enumerated().compactMap { i, ask in
            let options = choices(for: ask)
            guard let n = picks[i], options.indices.contains(n) else { return nil }
            return (i, AskAnswer(action: ask.action, answer: options[n]))
        }
    }

    /// One ordinary message: each picked ask's question then its answer,
    /// numbered as on the card (the agent wrote them in that order, and
    /// unpicked ones keep their numbers out of it, so it can tell which
    /// were answered), then whatever Mike wrote in the composer.
    public static func message(asks: [Ask], picks: [Int: Int], extra: String = "") -> String {
        let parts = answers(asks: asks, picks: picks).map { i, answer in
            // One ask needs no number: just the question, then the answer.
            asks.count == 1
                ? "\(answer.action)\n\(answer.answer)"
                : "\(i + 1). \(answer.action)\n   \(answer.answer)"
        }
        var body = parts.joined(separator: "\n\n")
        let more = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !more.isEmpty { body += (body.isEmpty ? "" : "\n\n") + more }
        return body
    }

    /// What Mike wrote himself in a message that answered asks: the text
    /// after the answers `message` put first, or nil when the text doesn't
    /// start with them (so the bubble shows it all as it is).
    public static func extra(in text: String, answers: [AskAnswer]) -> String? {
        guard !answers.isEmpty else { return nil }
        var paragraphs = text.components(separatedBy: "\n\n")[...]
        for answer in answers {
            guard let paragraph = paragraphs.first else { return nil }
            let lines = paragraph.split(separator: "\n", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard lines.count == 2, lines[0].hasSuffix(answer.action), lines[1] == answer.answer else { return nil }
            paragraphs = paragraphs.dropFirst()
        }
        return paragraphs.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the open card can be answered: a completed turn that said
    /// it needs Mike, with asks, and nothing running.
    public static func isOpen(_ thread: ThreadSummary) -> Bool {
        thread.needs == "you" && thread.asksSeq != nil && !thread.asks.isEmpty && !thread.status.isBusy
    }
}
