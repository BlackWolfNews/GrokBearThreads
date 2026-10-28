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

    /// The pick that means "Something else": what Mike writes in the
    /// composer is his answer to that ask (Mike, 28 Oct). One ask at a time.
    public static let ownAnswer = -1

    /// The picked asks as answers, in the card's order, each with its
    /// index on the card. A pick that isn't one of its ask's choices is
    /// left out, and so is "Something else" with nothing written.
    public static func answers(asks: [Ask], picks: [Int: Int], written: String = "") -> [(index: Int, answer: AskAnswer)] {
        let own = written.trimmingCharacters(in: .whitespacesAndNewlines)
        return asks.enumerated().compactMap { i, ask in
            guard let n = picks[i] else { return nil }
            if n == ownAnswer { return own.isEmpty ? nil : (i, AskAnswer(action: ask.action, answer: own)) }
            let options = choices(for: ask)
            guard options.indices.contains(n) else { return nil }
            return (i, AskAnswer(action: ask.action, answer: options[n]))
        }
    }

    /// One ordinary message: each picked ask's question then its answer,
    /// numbered as on the card (the agent wrote them in that order, and
    /// unpicked ones keep their numbers out of it, so it can tell which
    /// were answered), then whatever Mike wrote in the composer. With
    /// "Something else" picked, what he wrote is that ask's answer instead.
    public static func message(asks: [Ask], picks: [Int: Int], extra: String = "") -> String {
        let ownPicked = picks.values.contains(ownAnswer)
        let parts = answers(asks: asks, picks: picks, written: ownPicked ? extra : "").map { i, answer in
            block(answer, number: asks.count == 1 ? nil : i + 1)
        }
        var body = parts.joined(separator: "\n\n")
        let more = ownPicked ? "" : extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !more.isEmpty { body += (body.isEmpty ? "" : "\n\n") + more }
        return body
    }

    /// One ask's question then its answer. Numbered, the answer is
    /// indented under it, every line of it.
    static func block(_ answer: AskAnswer, number: Int?) -> String {
        guard let number else { return "\(answer.action)\n\(answer.answer)" }
        return "\(number). \(answer.action)\n   " + answer.answer.replacingOccurrences(of: "\n", with: "\n   ")
    }

    /// What Mike wrote himself in a message that answered asks: the text
    /// after the answers `message` put first, or nil when the text doesn't
    /// start with them (so the bubble shows it all as it is).
    public static func extra(in text: String, answers: [AskAnswer]) -> String? {
        guard !answers.isEmpty else { return nil }
        var rest = Substring(text)
        for answer in answers {
            // Numbered or not, as `message` wrote it.
            var number: Int?
            if let dot = rest.firstIndex(of: "."), let n = Int(rest[..<dot]), rest[rest.index(after: dot)...].hasPrefix(" ") { number = n }
            let expected = block(answer, number: number)
            guard rest.hasPrefix(expected) else { return nil }
            rest = rest.dropFirst(expected.count)
            if rest.hasPrefix("\n\n") { rest = rest.dropFirst(2) } else if !rest.isEmpty { return nil }
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the open card can be answered: a completed turn that said
    /// it needs Mike, with asks, and nothing running.
    public static func isOpen(_ thread: ThreadSummary) -> Bool {
        thread.needs == "you" && thread.asksSeq != nil && !thread.asks.isEmpty && !thread.status.isBusy
    }
}
