import Foundation

nonisolated enum AnswerStage: String, Sendable {
    case web, deep

    var waitingMessage: String {
        switch self {
        case .web: "Searching the web…"
        case .deep: "Digging deeper…"
        }
    }
}

nonisolated enum ServerAnswerEvent: Equatable, Sendable {
    case text(String)
    case stage(AnswerStage)
    case sources([AnswerSource])
    case ping
    /// Kept as a string so a future finish reason doesn't break an older app.
    case done(deep: String)
}

/// Plain text stays byte-for-byte the old path. For NDJSON we reuse the byte line decoder:
/// newline can't occur inside a UTF-8 character, so split characters wait for the whole line.
nonisolated struct ServerAnswerDecoder {
    let isNDJSON: Bool
    private var lines = SSELineDecoder()
    private var utf8 = UTF8StreamDecoder()
    private(set) var sawDone = false

    init(contentType: String?) {
        isNDJSON = contentType?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() == "application/x-ndjson"
    }

    mutating func push(byte: UInt8) -> ServerAnswerEvent? {
        guard !sawDone else { return nil }
        if !isNDJSON { return utf8.decode(byte: byte).map(ServerAnswerEvent.text) }
        guard let line = lines.push(byte: byte) else { return nil }
        return parse(line)
    }

    mutating func finish() -> ServerAnswerEvent? {
        // A partial final NDJSON line isn't a complete event, even if it looks like JSON.
        // In particular, a done without its newline doesn't certify a clean finish.
        guard !isNDJSON else { return nil }
        let rest = utf8.finish()
        return rest.isEmpty ? nil : .text(rest)
    }

    var wasCutOff: Bool { isNDJSON && !sawDone }

    private mutating func parse(_ line: String) -> ServerAnswerEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "text": return (object["text"] as? String).map(ServerAnswerEvent.text)
        case "stage": return (object["stage"] as? String).flatMap(AnswerStage.init).map(ServerAnswerEvent.stage)
        case "sources":
            guard let entries = object["sources"] as? [Any] else { return nil }
            return .sources(entries.compactMap(AnswerSource.fromEvent))
        case "ping": return .ping
        case "done":
            guard let deep = object["deep"] as? String else { return nil }
            sawDone = true
            return .done(deep: deep)
        default: return nil
        }
    }
}

/// Before stages, keep the existing 30-second network idle limit. A stage gives the entire
/// request 75 seconds, with at most 15 seconds between complete lines, including keepalives.
nonisolated struct ServerStreamDeadline {
    let startedAt: Double
    private(set) var lastActivityAt: Double
    private(set) var hasStage = false

    init(startedAt: Double) {
        self.startedAt = startedAt
        lastActivityAt = startedAt
    }

    mutating func received(at time: Double, stage: Bool = false) {
        lastActivityAt = time
        hasStage = hasStage || stage
    }

    /// The server answers with its headers within about 6 s (it sends a 502 if no model has
    /// started by then), so nothing at all by 7 s means the request never got there: on 29 Oct
    /// the phone's connection to Bruce went dead between the ping and the question, and the
    /// question sat on it for the whole 30 s. Then it's sent again, once, on a new connection.
    static let headersWithin: Double = 7

    func stalledBeforeHeaders(at time: Double, responded: Bool) -> Bool {
        !responded && time - startedAt >= Self.headersWithin
    }

    func expired(at time: Double) -> Bool {
        if hasStage { return time - startedAt >= 75 || time - lastActivityAt >= 15 }
        return time - lastActivityAt >= 30
    }
}

/// Text is never decorated here: the same concatenation is shown, spoken, and sent as history.
/// The deep boundary is a character count, so it survives appending even Unicode text.
nonisolated struct AnswerProgress {
    private(set) var text = ""
    private(set) var waiting: AnswerStage?
    private(set) var deepOffset: Int?
    /// A web or deep stage started at some point in this answer.
    private(set) var sawStage = false

    mutating func begin(_ stage: AnswerStage) {
        waiting = stage
        sawStage = true
    }

    mutating func append(_ text: String) {
        guard !text.isEmpty else { return }
        if waiting == .deep { deepOffset = self.text.count }
        waiting = nil
        self.text += text
    }

    mutating func finish() { waiting = nil }

    mutating func replaceText(_ text: String) { self.text = text }
}
