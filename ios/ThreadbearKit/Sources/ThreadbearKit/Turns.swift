import Foundation

/// A finished turn's working: the messages and tool lines before its reply.
public struct WorkedTurn: Hashable, Sendable {
    public var items: [ThreadItem]
    /// From the message that started the turn to its reply; nil when the
    /// page starts partway through the turn.
    public var duration: TimeInterval?

    public init(items: [ThreadItem], duration: TimeInterval?) {
        self.items = items
        self.duration = duration
    }

    /// "Worked for 2m 13s", as the Mac says it.
    public var title: String {
        guard let duration, duration >= 1 else { return "Worked" }
        let s = Int(duration)
        if s < 60 { return "Worked for \(s)s" }
        if s < 3600 { return s % 60 == 0 ? "Worked for \(s / 60)m" : "Worked for \(s / 60)m \(s % 60)s" }
        return (s % 3600) / 60 == 0 ? "Worked for \(s / 3600)h" : "Worked for \(s / 3600)h \((s % 3600) / 60)m"
    }
}

/// A thread as the Mac shows it once its turns are over (docs/protocol.md,
/// "Needs you", "The summary"): Mike's message, one line of work, then the
/// reply. The phone has a small screen, so this matters more here.
public enum Turns {
    public static func fold(_ messages: [PhoneMessage], busy: Bool) -> [ThreadItem] {
        // A turn starts at a message from Mike, the phone, a schedule or
        // another agent; one the runner sent (a restart, a resume) joins the
        // turns before it, as on the Mac.
        var turns: [[PhoneMessage]] = [[]]
        for m in messages {
            if m.role == .user, m.origin != "runner", !(turns.last?.isEmpty ?? true) { turns.append([]) }
            turns[turns.count - 1].append(m)
        }
        var out: [ThreadItem] = []
        for (i, turn) in turns.enumerated() where !turn.isEmpty {
            let starter = turn.first.flatMap { $0.role == .user && $0.origin != "runner" ? $0 : nil }
            let body = starter == nil ? turn : Array(turn.dropFirst())
            if let starter { out.append(.message(starter)) }
            // The turn still going shows its work as it comes.
            if busy && i == turns.count - 1 {
                out += ThreadItem.group(body)
                continue
            }
            let reply = replies(body)
            if reply.isEmpty {
                out += ThreadItem.group(body)
                continue
            }
            let folded = body.enumerated().filter { !reply.contains($0.offset) }.map(\.element)
            // Nothing to fold (a quick answer, no tools): just the reply.
            if !folded.isEmpty, folded.contains(where: { $0.role == .tool }) || folded.contains(where: { $0.role == .assistant }) {
                let end = body[reply.max()!].at
                let start = starter?.at
                out.append(.worked(WorkedTurn(items: ThreadItem.group(folded), duration: start.map { end.timeIntervalSince($0) })))
            } else {
                out += ThreadItem.group(folded)
            }
            out += reply.sorted().map { .message(body[$0]) }
        }
        return out
    }

    /// Which of a finished stretch's messages are its replies, as the Mac
    /// picks them (TranscriptReducer, replies(in:)): each turn has its own, so
    /// one the runner or the CLI started doesn't fold away the answer before
    /// it, unless a summary covers them. A summary from a turn the runner's
    /// message started does, as its end_turn is told to. One from a wake-up
    /// doesn't: nobody told it to, and it's usually "nothing's changed".
    static func replies(_ body: [PhoneMessage]) -> [Int] {
        var turns: [Range<Int>] = []
        var start = 0
        for i in body.indices.dropFirst() {
            let newTurn = body[i].turn != nil && body[i].turn != body[i - 1].turn
            if body[i].role == .user || newTurn {
                turns.append(start..<i)
                start = i
            }
        }
        if !body.isEmpty { turns.append(start..<body.count) }
        let covers = turns.lastIndex { turn in
            let wakeUp = turn.lowerBound > 0 && body[turn.lowerBound].role != .user
            return !wakeUp && body[turn].contains { $0.role == .assistant && $0.summary }
        }
        return turns[(covers ?? 0)...].flatMap { turn in
            replyIndexes(Array(body[turn])).map { $0 + turn.lowerBound }
        }
    }

    /// Which of a finished turn's messages are its reply, as the Mac picks
    /// it: the messages after its last step (and before the summary) when
    /// they say more than the summary's bullets; else the bullets; else the
    /// last thing the agent wrote.
    static func replyIndexes(_ body: [PhoneMessage]) -> [Int] {
        let summary = body.lastIndex(where: { $0.role == .assistant && $0.summary })
        let lastStep = body.lastIndex(where: isStep) ?? -1
        if let summary {
            let after = (lastStep + 1)..<summary
            let words = after.filter { body[$0].role == .assistant && !body[$0].summary }
            let length = words.reduce(0) { $0 + body[$1].text.count }
            return length > body[summary].text.count ? words : [summary]
        }
        if let last = body.lastIndex(where: { $0.role == .assistant }) { return [last] }
        return []
    }

    /// A step of work: a tool call outside Threadbear's own tools and
    /// ToolSearch (which say nothing Mike has to read), or a message sent
    /// into the turn.
    static func isStep(_ m: PhoneMessage) -> Bool {
        switch m.role {
        case .user: true
        case .assistant: false
        case .tool: !(m.text.hasPrefix("threadbear: ") || m.text.hasPrefix("Find tools: "))
        }
    }
}

/// One thing a turn needs from Mike, from its end_turn (backend API 14).
public struct PhoneAsk: Codable, Sendable, Hashable {
    public var action: String
    public var why: String?
    /// The words the agent wants back once it's done ("done").
    public var reply: String?
    public var options: [String]?
    /// The agent's own pick, an index into options (a Convex number).
    public var suggested: Double?
    /// Web pages to go to; files on the Mac never come to the phone.
    public var links: [PhoneAskLink]?
    public var ticked: Bool?

    public init(action: String, why: String? = nil, reply: String? = nil, options: [String]? = nil, suggested: Double? = nil, links: [PhoneAskLink]? = nil, ticked: Bool? = nil) {
        self.action = action
        self.why = why
        self.reply = reply
        self.options = options
        self.suggested = suggested
        self.links = links
        self.ticked = ticked
    }

    /// The paragraph the Mac shows (Decisions.paragraph): the action on one
    /// line, a full stop if it doesn't end a sentence, then the why with
    /// its own line breaks, so a list in it stays a list.
    public var paragraph: String {
        let action = self.action.replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let why = (self.why ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !why.isEmpty else { return action }
        let ends = action.last(where: { !"\"'”’)]*_`".contains($0) }).map { ".?!…:".contains($0) } ?? false
        return (ends ? action : action + ".") + " " + why
    }

    /// What to pick from: its options, else the reply it wants ("done").
    /// He can always write his own in the composer.
    public var choices: [String] {
        if let options, !options.isEmpty { return options }
        if let reply = reply?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty { return [reply] }
        return []
    }

    public var suggestedIndex: Int? { suggested.map { Int($0) } }
}

public struct PhoneAskLink: Codable, Sendable, Hashable {
    public var title: String
    public var url: String
    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

/// An ask answered, as threads.send takes it, so the transcript shows it as
/// an answer.
public struct AskAnswer: Codable, Sendable, Hashable {
    public var action: String
    public var answer: String
    public init(action: String, answer: String) {
        self.action = action
        self.answer = answer
    }

    /// The message the Mac sends (Decisions.message): each picked ask's
    /// question then its answer, numbered by its place on the card when
    /// there are several, the answer indented under it, then anything else
    /// he wrote. Picks are ask index to choice index.
    public static func message(asks: [PhoneAsk], picks: [Int: Int], extra: String = "") -> String {
        var parts = answers(asks: asks, picks: picks).map { i, answer in
            asks.count == 1 ? "\(answer.action)\n\(answer.answer)"
                : "\(i + 1). \(answer.action)\n   " + answer.answer.replacingOccurrences(of: "\n", with: "\n   ")
        }
        let more = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !more.isEmpty { parts.append(more) }
        return parts.joined(separator: "\n\n")
    }

    /// The message for follow-ups ticked on the done card, as the Mac
    /// sends it (Decisions.followUpMessage): the one on its own, or
    /// several as a list, then anything else he wrote.
    public static func followUpMessage(_ followUps: [String], extra: String = "") -> String {
        var body = followUps.count == 1 ? followUps[0] : followUps.map { "- \($0)" }.joined(separator: "\n")
        let more = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !more.isEmpty { body += (body.isEmpty ? "" : "\n\n") + more }
        return body
    }

    /// The picked asks as answers, in the card's order.
    public static func answers(asks: [PhoneAsk], picks: [Int: Int]) -> [(index: Int, answer: AskAnswer)] {
        asks.enumerated().compactMap { i, ask in
            guard let n = picks[i], ask.choices.indices.contains(n) else { return nil }
            return (i, AskAnswer(action: ask.action, answer: ask.choices[n]))
        }
    }
}
