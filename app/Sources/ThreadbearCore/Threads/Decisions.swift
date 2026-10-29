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
        return impliedChoices(ask.action)
    }

    /// An ask as the markdown the card shows: its action, then its why, as
    /// the agent would have written it under "What I need from you" in its
    /// message. Mike found a bold title over a small grey reason backwards
    /// (28 Oct): you explain, then ask, in the same voice. An action with
    /// no full stop gets one, so it doesn't run into the why. The action is
    /// a sentence, so its line breaks go; the why keeps its own, so a list
    /// of questions in it draws as a list rather than one run-on line
    /// (Mike, 29 Oct).
    public static func paragraph(_ ask: Ask) -> String {
        let action = oneLine(ask.action)
        let why = (ask.why ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !why.isEmpty else { return action }
        return (endsSentence(action) ? action : action + ".") + " " + why
    }

    /// Text that will follow a list marker (`under`, like "2. " or
    /// "- [ ] "), with its later lines indented past the marker so a list
    /// or paragraph in it stays inside that item rather than ending it.
    public static func continued(_ text: String, under marker: String) -> String {
        let pad = String(repeating: " ", count: marker.count)
        return text.components(separatedBy: "\n").enumerated()
            .map { $0.offset == 0 || $0.element.isEmpty ? $0.element : pad + $0.element }
            .joined(separator: "\n")
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the text ends a sentence, looking past closing quotes,
    /// brackets and markdown: 'Tell me "it locked."' does.
    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last(where: { !"\"'”’)]*_`".contains($0) }) else { return false }
        return ".?!…:".contains(last)
    }

    /// The words an ask with no options still asks for: 'Reply "export"
    /// when…' or "Say go for Short 2, or name another". Threads started
    /// before end_turn had options, and agents that skip them, mostly
    /// write asks like that (60% offered a reply word in the 27 Oct
    /// survey), so the word becomes a button. A list of them ('Reply with
    /// "Land it", "Website, then land it", or…') is a button each: taking
    /// just the first left Mike one where he'd been offered two (28 Oct).
    static func impliedChoices(_ action: String) -> [String] {
        let ns = action as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let m = quoted.firstMatch(in: action, range: full) {
            var choices = [ns.substring(with: m.range(at: 1))]
            var at = m.range.upperBound
            while choices.count < maxImplied,
                  let more = Self.more.firstMatch(in: action, options: .anchored, range: NSRange(location: at, length: ns.length - at)) {
                choices.append(ns.substring(with: more.range(at: 1)))
                at = more.range.upperBound
            }
            return choices
        }
        if let m = bare.firstMatch(in: action, range: full) {
            let word = ns.substring(with: m.range(at: 1))
            return [word.prefix(1).uppercased() + word.dropFirst()]
        }
        return []
    }

    /// As many as end_turn's options take (runner/src/needs.ts).
    private static let maxImplied = 6
    private static let quoted = try! NSRegularExpression(pattern: #"\b(?:say|reply|type|send|answer)(?: with)?\s+[\"“']([^\"”']{1,40})[\"”']"#, options: .caseInsensitive)
    /// Each further quoted choice straight after the first.
    private static let more = try! NSRegularExpression(pattern: #"\s*(?:,\s*(?:or\s+)?|or\s+|/\s*)[\"“']([^\"”']{1,40})[\"”']"#, options: .caseInsensitive)
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
